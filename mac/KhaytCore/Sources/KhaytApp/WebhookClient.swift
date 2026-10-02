import Foundation
import CryptoKit
import Darwin
import Network
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
/// ── AND THE SOCKET GOES TO THE ADDRESS THAT WAS CHECKED ───────────────────
///
/// It used to be best-effort against a rebinder: `URLSession` resolved the name
/// AGAIN when it connected, so a name answering a public address to the check
/// and `10.0.0.1` a moment later went where the check never looked. Now the
/// delivery is one HTTP/1.1 POST over a Network.framework connection made to
/// the checked ADDRESS, with TLS told the NAME (`sec_protocol_options_set_tls_
/// server_name`) so SNI and certificate validation are still against the host
/// the shop typed — measured, Oct 2026: github.com's address with the name
/// `github.com` connects, with `example.com` it fails the handshake. Nothing
/// resolves the name a second time. (`main.js` still carries the old caveat.)
///
/// ── AND REDIRECTS ARE NOT FOLLOWED ────────────────────────────────────────
///
/// A consumer answering `302 Location: http://169.254.169.254/` would walk the
/// app straight past both layers. This client follows nothing: a 3xx is the
/// answer, and it is refused as one.
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
        let resolved = await addresses(of: host)
        for address in resolved {
            if (try? await engine.isBlockedHost(address)) ?? true {
                throw Failure.blocked("\(host) → \(address)")
            }
        }
        // Nothing to connect to is a fault, not a pass: the old path would
        // have let URLSession resolve it on its own, unchecked.
        guard !resolved.isEmpty else { throw Failure.refused("\(host) did not resolve") }

        let payload = try JSONEncoder().encode(body)
        let headers = signedHeaders(payload: payload, secret: secret, event: event, now: Date())
        let head = requestHead(url, host: host, headers: headers, length: payload.count)

        // The checked addresses, in the resolver's order; the first that
        // connects takes the delivery. Every one of them passed layer two.
        var last: Error = Failure.refused("\(host) could not be reached")
        for address in resolved {
            do {
                let status = try await pinnedPost(url, host: host, address: address,
                                                  message: head + payload, timeout: timeout)
                if (300..<400).contains(status) { throw Failure.redirected }
                return status
            } catch let failure as Failure {
                throw failure
            } catch let sent as Unanswered {
                // The request went out; trying the next address would deliver
                // it twice.
                throw Failure.refused(sent.description)
            } catch {
                last = error
            }
        }
        throw last
    }

    /// The headers of one delivery, signature included.
    ///
    /// ── TWO SIGNATURES, AND THE FIRST ONE IS UNCHANGED ───────────────────
    ///
    /// `X-Khayt-Signature` is what every consumer verifies today, and it stays
    /// exactly as it was (see below). It signs the body alone, so a captured
    /// delivery can be replayed for ever — the body's own `timestamp` is
    /// covered, but only a consumer that thinks to read it is protected.
    ///
    /// So each delivery also carries `X-Khayt-Timestamp` (Unix seconds) and
    /// `X-Khayt-Signature-V2`, the bare hex HMAC-SHA256 of
    /// `"<timestamp>.<body>"` with the same secret — the scheme Stripe and
    /// Slack use. A consumer that checks V2 and refuses an old timestamp
    /// refuses a replay; one that does not is unaffected.
    nonisolated static func signedHeaders(payload: Data, secret: String, event: String,
                                          now: Date) -> [(String, String)] {
        var headers: [(String, String)] = [("Content-Type", "application/json"),
                                           ("X-Khayt-Event", event)]
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
            let key = SymmetricKey(data: Data(secret.utf8))
            let hex = { (data: Data) in
                HMAC<SHA256>.authenticationCode(for: data, using: key)
                    .map { String(format: "%02x", $0) }.joined()
            }
            headers.append(("X-Khayt-Signature", hex(payload)))
            let stamp = String(Int(now.timeIntervalSince1970))
            headers.append(("X-Khayt-Timestamp", stamp))
            headers.append(("X-Khayt-Signature-V2", hex(Data((stamp + ".").utf8) + payload)))
        }
        return headers
    }

    /// The request line and headers of one POST, as bytes.
    ///
    /// `Host` is the NAME, with the port when it is not 443, because the
    /// socket is opened to an address and the consumer routes on this. CR and
    /// LF are taken out of every value: an event name or a path is not the
    /// place to start a second header.
    nonisolated static func requestHead(_ url: URL, host: String, headers: [(String, String)],
                                        length: Int) -> Data {
        // By SCALAR: "\r\n" is one Character in Swift, equal to neither.
        let clean = { (s: String) in
            String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
        }
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let q = url.query(percentEncoded: true), !q.isEmpty { target += "?" + q }
        let name = host.contains(":") ? "[\(host)]" : host
        let authority = url.port.map { $0 == 443 ? name : "\(name):\($0)" } ?? name
        var lines = ["POST \(clean(target)) HTTP/1.1", "Host: \(clean(authority))"]
        for (k, v) in headers { lines.append("\(clean(k)): \(clean(v))") }
        lines += ["Content-Length: \(length)", "Connection: close", "User-Agent: Khayt", "", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// The status code from the first line of an HTTP/1.x answer.
    nonisolated static func statusCode(_ head: Data) -> Int? {
        guard let end = head.firstRange(of: Data("\r\n".utf8)),
              let line = String(data: head[..<end.lowerBound], encoding: .utf8) else { return nil }
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]),
              (100..<600).contains(code) else { return nil }
        return code
    }

    /// The request went out and no status came back.
    struct Unanswered: Error, CustomStringConvertible {
        let why: String
        var description: String { "The webhook was sent but the answer could not be read: \(why)" }
    }

    /// One HTTPS POST to `address`, with TLS validating `host`.
    ///
    /// Network.framework rather than `URLSession` because only it can be told
    /// WHERE to connect separately from WHO to expect there. It follows no
    /// redirect and resolves nothing.
    nonisolated static func pinnedPost(_ url: URL, host: String, address: String,
                                       message: Data, timeout: TimeInterval) async throws -> Int {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? 443)) else {
            throw Failure.blocked("port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port,
                                      using: NWParameters(tls: tls))
        let queue = DispatchQueue(label: "khayt.webhook.post")
        let once = Once()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                let finish: @Sendable (Result<Int, Error>) -> Void = { result in
                    guard once.claim() else { return }
                    connection.cancel()
                    continuation.resume(with: result)
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(URLError(.timedOut)))
                }
                @Sendable func read(_ buffer: Data) {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
                        data, _, complete, error in
                        let buffer = buffer + (data ?? Data())
                        if let code = statusCode(buffer) { finish(.success(code)); return }
                        if let error { finish(.failure(Unanswered(why: "\(error)"))); return }
                        if complete || buffer.count > 16_384 {
                            finish(.failure(Unanswered(why: "no HTTP status line")))
                            return
                        }
                        read(buffer)
                    }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: message, completion: .contentProcessed { error in
                            if let error { finish(.failure(Unanswered(why: "\(error)"))); return }
                            read(Data())
                        })
                    // `.waiting` is how an unreachable address and a failed
                    // certificate both arrive; a webhook does not wait.
                    case .failed(let error), .waiting(let error):
                        finish(.failure(error))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Resumes a continuation exactly once, whichever of the answer, the
    /// failure or the timeout gets there first.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    /// Every address a name resolves to, off the thread that asked.
    ///
    /// ── `resolve` BLOCKS, AND THIS TYPE IS `@MainActor` ───────────────────
    ///
    /// `getaddrinfo` waits for a resolver, and for a name that does not resolve
    /// it waits until DNS gives up — seconds, on a bad network. Called straight
    /// from an `async` method of a main-actor type it blocks the main thread,
    /// so a shop finishing a job with a webhook pointed at a slow name would
    /// watch the window stop.
    ///
    /// It is worse than it looks, because a blocked thread of Swift's
    /// cooperative pool is a thread no OTHER async work can use either — so the
    /// damage is not confined to the send that is waiting.
    ///
    /// HOW IT WAS FOUND IS NOT WHY IT IS FIXED. It turned up while chasing a CI
    /// failure that had a different cause entirely (two swapped constants in
    /// `LanStallTests`), and the first version of this comment claimed the
    /// blocking call was responsible. It was not. It is fixed because a
    /// main-actor type must not wait on DNS, which is true on its own.
    ///
    /// `Task.detached` runs it on a thread that is allowed to block.
    static func addresses(of host: String) async -> [String] {
        await Task.detached(priority: .userInitiated) { resolve(host) }.value
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
