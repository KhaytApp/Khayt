import Foundation
import CryptoKit
import Darwin
import KhaytCore

/// Telling somebody else's software that an order changed.
///
/// ── THE GUARD IS TWO LAYERS AND NEITHER IS ENOUGH ─────────────────────────
///
/// The URL is typed by the shop, so this is a request the app makes to an
/// address a person chose. That is the shape of every SSRF hole ever written.
///
///   1. The NAME. `lib/host-ranges.js` — loopback, RFC1918, link-local, cloud
///      metadata, and the spellings that hide them: `[::1]`,
///      `::ffff:127.0.0.1` in both its dotted and hex forms, numeric IPv4 like
///      `2130706433`. Shared with the other app, because almost every line of
///      it is a hole somebody found and a Swift rewrite would start again from
///      the version that looked right.
///
///   2. The ADDRESS. A perfectly public name — `evil.example.com` — can have an
///      A record pointing at `10.0.0.1`. So the host is resolved and EVERY
///      answer is put through the same rule. A name that passes layer one and
///      resolves to one blocked address is refused.
///
/// This is best-effort against a determined rebinder: `URLSession` resolves
/// again when it connects, and there is no supported way to pin the socket to
/// the address checked here. `main.js` carries the same caveat in the same
/// words. It stops the accident and the casual attempt, which is what it is for.
///
/// ── AND REDIRECTS ARE NOT FOLLOWED ────────────────────────────────────────
///
/// A consumer answering `302 Location: http://169.254.169.254/` would walk the
/// app straight past both layers. A redirect is refused rather than followed.
@MainActor
enum WebhookClient {

    /// Ten seconds. A webhook consumer that has not answered in ten is not
    /// going to; the shop is waiting on a job move behind this.
    static let timeout: TimeInterval = 10

    enum Failure: Error, LocalizedError {
        case blocked(String)
        case redirected
        case refused(String)
        var errorDescription: String? {
            switch self {
            case .blocked(let host): return "Blocked address: \(host)"
            case .redirected: return "Webhook redirects are not allowed"
            case .refused(let why): return why
            }
        }
    }

    /// One delivery. Returns the HTTP status, or throws for a fault.
    ///
    /// `body` is the finished wire body — `KhaytWebhookBus.buildWireBody`, the
    /// envelope `main.js` has posted since webhooks shipped. It is not touched
    /// here: the signature is over exactly these bytes, and a field added in
    /// passing is a delivery the consumer verifies and rejects.
    @discardableResult
    static func deliver(_ body: JSONValue, to url: URL, secret: String,
                        event: String, engine: KhaytEngine) async throws -> Int {
        guard let host = url.host, !host.isEmpty else { throw Failure.blocked("") }
        // https ONLY, which is what the other app allows. Plain http would
        // carry a shop's order data and its HMAC across the network in the
        // clear, and there is no consumer that needs it.
        guard url.scheme?.lowercased() == "https" else {
            throw Failure.blocked(url.scheme ?? "")
        }

        // Layer one: the name.
        if (try? await engine.isBlockedHost(host)) ?? true { throw Failure.blocked(host) }

        // Layer two: every address it resolves to.
        for address in resolve(host) {
            if (try? await engine.isBlockedHost(address)) ?? true {
                throw Failure.blocked("\(host) → \(address)")
            }
        }

        let payload = try JSONEncoder().encode(body)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event, forHTTPHeaderField: "X-Khayt-Event")
        if !secret.isEmpty {
            // ── BARE HEX, NOT `sha256=<hex>` ───────────────────────────────
            //
            // Because that is what a consumer of this app is already verifying.
            // `main.js` has two webhook transports and they disagree with each
            // other about this: `hub:webhook-post` writes the prefix,
            // `hub:fire-webhook` writes the hex alone — and `hub:fire-webhook`
            // is the one every delivery actually goes through, because the
            // renderer routes even the single-URL webhook down the durable path
            // to get its retries. So the prefixed spelling is the one nobody
            // receives, and matching it would have meant every delivery from
            // this Mac failing verification at a consumer that accepts Khayt's.
            let mac = HMAC<SHA256>.authenticationCode(
                for: payload, using: SymmetricKey(data: Data(secret.utf8)))
            request.setValue(mac.map { String(format: "%02x", $0) }.joined(),
                             forHTTPHeaderField: "X-Khayt-Signature")
        }

        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) { throw Failure.redirected }
        return status
    }

    /// A session that does NOT follow redirects.
    ///
    /// `URLSession.shared` follows them, and a consumer answering
    /// `302 Location: http://169.254.169.254/` would take the app straight past
    /// both layers of the guard to a cloud metadata endpoint.
    private static let session: URLSession = {
        let delegate = NoRedirects()
        return URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // nil = do not follow; the 3xx is handed back as the response.
            completionHandler(nil)
        }
    }

    /// Every address a host resolves to, as text the shared rule can read.
    ///
    /// `getaddrinfo` rather than a Network.framework resolver because this is a
    /// blocking question asked once before a single request, and the answer has
    /// to be a LIST — a name with four A records and one of them internal is
    /// the case this exists for.
    nonisolated static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(head) }

        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
                           &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                // `String(cString:)` is deprecated; the buffer is NUL-padded
                // to NI_MAXHOST, so the terminator has to be found rather than
                // decoding the whole array and getting a string full of zeros.
                let bytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let said = String(decoding: bytes, as: UTF8.self)
                // A link-local IPv6 answer carries a zone — `fe80::1%en0` — and
                // the rule matches on the prefix, so the zone is trimmed rather
                // than left to make the string not match anything.
                out.append(said.components(separatedBy: "%").first ?? said)
            }
            node = current.pointee.ai_next
        }
        return out
    }
}
