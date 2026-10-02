import Foundation
import KhaytCore

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
///   carrying `@`, `/` or `:` tricks is refused, and
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
    /// characters it would strip) and an address it allows.
    static func allowed(_ url: URL, engine: KhaytEngine) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              var host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        // `URL.host` keeps the brackets off an IPv6 literal but the zone
        // (`%en0`) on; neither is something the shared guard reads.
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        guard let clean = try? await engine.printerHost(host), clean == host,
              (try? await engine.printerHostAllowed(host)) == true else { return false }
        return true
    }

    static func send(_ request: KhaytEngine.PlugRequest, engine: KhaytEngine,
                     fetch: (URLRequest) async throws -> (Data, URLResponse) = { r in
                         try await SmartPlug.session.data(for: r) }) async throws -> JSONValue {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        guard await allowed(url, engine: engine) else {
            throw Failure.notALanAddress(url.host(percentEncoded: false) ?? request.url)
        }
        var r = URLRequest(url: url, timeoutInterval: 6)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body = request.body { r.httpBody = Data(body.utf8) }
        let (data, response) = try await fetch(r)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.refused(http.statusCode)
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}
