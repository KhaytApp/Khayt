import Foundation
import KhaytCore

/// Reading a shop's spools out of Spoolman.
///
/// Spoolman usually runs on the printer's own board or a Pi beside it, on the
/// shop's network, with no key. This asks it for every spool, a page at a time,
/// and hands them to `lib/spoolman-import.js` to say what each becomes. It only
/// ever reads: there is no request here that could change Spoolman.
///
/// The address is held to the same rule as a printer's — `lib/printer-host.js`
/// — because a URL field that will fetch anything is a request forgery waiting
/// for a pretext, and redirects are refused for the same reason.
@MainActor
enum SpoolmanImport {

    enum Problem: LocalizedError, Equatable {
        case noAddress
        case notALanAddress(String)
        case refused(Int)
        case notSpoolman

        var errorDescription: String? {
            switch self {
            case .noAddress: "Type the address Spoolman runs at, like 192.168.1.20:7912."
            case .notALanAddress(let host): "\(host) is not on this network. Spoolman is imported from the shop's own network only."
            case .refused(let status): "Spoolman answered \(status)."
            case .notSpoolman: "Something answered at that address, but it was not Spoolman's spool list."
            }
        }
    }

    /// `192.168.1.20`, `192.168.1.20:7912` or `http://192.168.1.20:7912/` —
    /// whatever the shop pastes — as the base URL, on this network or refused.
    static func base(_ typed: String, engine: KhaytEngine) async throws -> URL {
        var raw = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw Problem.noAddress }
        if !raw.contains("://") { raw = "http://" + raw }
        guard let parts = URLComponents(string: raw), let typedHost = parts.host, !typedHost.isEmpty
        else { throw Problem.noAddress }
        let host = try await engine.printerHost(typedHost)
        guard !host.isEmpty else { throw Problem.noAddress }
        guard try await engine.printerHostAllowed(host) else { throw Problem.notALanAddress(host) }
        let port = parts.port ?? 7912
        guard (1...65535).contains(port), let url = URL(string: "http://\(host):\(port)") else { throw Problem.noAddress }
        return url
    }

    /// Every spool Spoolman holds that is not archived, all pages.
    static func fetchAll(_ base: URL, engine: KhaytEngine,
                         fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> [JSONValue] {
        let page = 500
        var out: [JSONValue] = []
        // Twenty pages is ten thousand rolls — past any shop, and short of a
        // server that keeps answering forever.
        for n in 0..<20 {
            let path = try await engine.spoolmanListPath(offset: n * page, limit: page)
            guard let url = URL(string: base.absoluteString + path) else { throw Problem.noAddress }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await (fetch ?? { try await session.data(for: $0) })(request)
            var total: Int?
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else { throw Problem.refused(http.statusCode) }
                total = (http.value(forHTTPHeaderField: "x-total-count")).flatMap { Int($0) }
            }
            guard case .array(let rows)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw Problem.notSpoolman
            }
            out.append(contentsOf: rows)
            if rows.count < page { break }
            if let total, out.count >= total { break }
        }
        return out
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
