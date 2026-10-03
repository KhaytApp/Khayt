import Foundation
import KhaytCore
import Network

/// The one socket a smart plug is spoken to over.
///
/// `lib/smart-plug.js` builds the request and reads the answer; this only
/// sends it. Short timeout: a plug is on the shop's own network, and a switch
/// that hangs for a minute is a button pressed three times.
///
/// ── THE SAME GUARD A PRINTER GETS ────────────────────────────────────────
///
/// A plug request can carry a credential — Home Assistant's long-lived token
/// as `Authorization: Bearer`, Tasmota's user and password in the query — and
/// the poller opens that credential every minute without anyone pressing
/// anything. So before anything goes out:
///
/// - the host is run through `lib/printer-host.js`, exactly as a printer's
///   and a camera's are: a public IP literal, loopback, or a host string
///   carrying `@` or `/` tricks is refused — and a NAME is resolved and every
///   address it gives judged the same way (`target`), and
/// - no redirect is followed: a 30x would carry the request, and the token
///   with it, to an address the check above never saw.
///
/// Oct 2026 security review (finding 1).
@MainActor
enum SmartPlug {
    enum Failure: Error, LocalizedError {
        case refused(Int)
        case notALanAddress(String)
        var errorDescription: String? {
            switch self {
            case .refused(let code): "HTTP \(code)"
            case .notALanAddress(let host): "\(host) is not an address on this network."
            }
        }
    }

    /// The session every plug request goes through: ephemeral, no redirects.
    nonisolated static let session = URLSession(configuration: .ephemeral,
                                                delegate: RefuseRedirects.shared, delegateQueue: nil)

    /// May a request go to this URL at all? The host, exactly as it will be
    /// connected to, must be the host `lib/printer-host.js` reads it as (no
    /// characters it would strip) and an address it allows — and a NAME must
    /// resolve only to such addresses. See `target`.
    static func allowed(_ url: URL, engine: KhaytEngine,
                        resolve: @escaping @Sendable (String) async -> [String] = { await SmartPlug.addresses(of: $0) }) async -> Bool {
        await target(url, engine: engine, resolve: resolve) != nil
    }

    /// Where a request for `url` actually goes, or nil when it may not go.
    ///
    /// ── A NAME IS WHERE IT RESOLVES ───────────────────────────────────────
    ///
    /// The shared rule is SYNTACTIC: any name passes it, because a printer's
    /// `octopi.local` cannot be judged by its spelling. For a printer that is
    /// a stated trust boundary. For a plug it was a hole: the request carries
    /// a Home Assistant token and is sent every minute unattended, and a name
    /// is sent wherever DNS says — `plug.example.com` pointed at a public
    /// address took the token with it. So a name is resolved here and EVERY
    /// address it gives must pass the same rule as a typed address would. And
    /// for plain HTTP the request is then sent to the address that was
    /// checked (unless it is only link-local IPv6, which cannot be reached
    /// without the zone the resolver trims), with the name in `Host`, so a
    /// second lookup that answers
    /// differently (DNS rebinding) has nothing to change. HTTPS keeps the name
    /// — its certificate is checked against it — so there the check is the
    /// defence. A public name (a Nabu Casa remote URL) is refused like a
    /// public address. Oct 2026 review.
    ///
    /// An IPv6 literal (`http://[fe80::1%en0]/`) is judged as the address it
    /// is. The shared sanitiser strips `:`, which made every one of them read
    /// as "not the host it says" and refused every IPv6 plug.
    static func target(_ url: URL, engine: KhaytEngine,
                       resolve lookUp: @escaping @Sendable (String) async -> [String] = { await SmartPlug.addresses(of: $0) })
    async -> (url: URL, host: String?)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              var host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        // `URL.host` keeps the brackets off an IPv6 literal but the zone
        // (`%en0`) on; neither is something the shared guard reads.
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") {
            guard IPv6Address(host) != nil, await addressAllowed(host, engine: engine) else { return nil }
            return (url, nil)
        }
        guard let clean = try? await engine.printerHost(host), clean == host,
              await addressAllowed(host, engine: engine) else { return nil }
        if IPv4Address(host) != nil { return (url, nil) }

        // A name: every address it resolves to must be one a plug may be at.
        let addresses = await lookUp(host)
        guard !addresses.isEmpty else { return nil }
        for address in addresses {
            let bare = String(address.split(separator: "%", maxSplits: 1).first ?? "")
            guard await addressAllowed(bare, engine: engine) else { return nil }
        }
        guard scheme == "http" else { return (url, nil) }
        // Pinned to an address that needs no zone to reach: IPv4 first, else
        // a unique-local IPv6. A name that resolves to link-local IPv6 alone
        // is sent by name — the resolver has trimmed the zone a link-local
        // address cannot be reached without — having been checked above.
        guard let chosen = addresses.first(where: { !$0.contains(":") })
                ?? addresses.first(where: { $0.contains(":") && !$0.lowercased().hasPrefix("fe") })
        else { return (url, nil) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.percentEncodedHost = chosen.contains(":") ? "[" + chosen + "]" : chosen
        guard let pinned = parts.url else { return nil }
        let authority = url.port.map { "\(host):\($0)" } ?? host
        return (pinned, authority)
    }

    /// One address, through the shared rule — except IPv6, which that rule
    /// cannot read: the engine sanitises before it judges, and with the colons
    /// stripped `2001:4860:4860::8888` reads as a bare hostname and passes.
    /// So an IPv6 address is judged here, by its bytes, with the rule's own
    /// ranges: link-local (`fe80::/10`) and unique-local (`fc00::/7`) only —
    /// never loopback, unspecified, IPv4-mapped or global.
    static func addressAllowed(_ address: String, engine: KhaytEngine) async -> Bool {
        if address.contains(":") {
            let bare = String(address.split(separator: "%", maxSplits: 1).first ?? "")
            guard let v6 = IPv6Address(bare) else { return false }
            let b = [UInt8](v6.rawValue)
            return (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || (b[0] & 0xfe) == 0xfc
        }
        return (try? await engine.printerHostAllowed(address)) == true
    }

    /// Every address a name resolves to — through `WebhookClient.addresses`,
    /// the one wrapper that takes the blocking `getaddrinfo` off the caller
    /// (`SmtpHostGuardTests` holds every lookup in the app to it). Zones are
    /// trimmed there, which is why a link-local answer is checked but never
    /// pinned (`target`).
    static func addresses(of host: String) async -> [String] {
        await WebhookClient.addresses(of: host)
    }

    static func send(_ request: KhaytEngine.PlugRequest, engine: KhaytEngine,
                     resolve: @escaping @Sendable (String) async -> [String] = { await SmartPlug.addresses(of: $0) },
                     fetch: (URLRequest) async throws -> (Data, URLResponse) = { r in
                         try await SmartPlug.session.data(for: r) }) async throws -> JSONValue {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        guard let target = await target(url, engine: engine, resolve: resolve) else {
            throw Failure.notALanAddress(url.host(percentEncoded: false) ?? request.url)
        }
        var r = URLRequest(url: target.url, timeoutInterval: 6)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        if let name = target.host { r.setValue(name, forHTTPHeaderField: "Host") }
        if let body = request.body { r.httpBody = Data(body.utf8) }
        let (data, response) = try await fetch(r)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.refused(http.statusCode)
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}
