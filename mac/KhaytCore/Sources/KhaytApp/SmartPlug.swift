import Foundation
import KhaytCore

/// The one socket a smart plug is spoken to over.
///
/// `lib/smart-plug.js` builds the request and reads the answer; this only
/// sends it. Short timeout: a plug is on the shop's own network, and a switch
/// that hangs for a minute is a button pressed three times.
@MainActor
enum SmartPlug {
    enum Failure: Error, LocalizedError {
        case refused(Int)
        var errorDescription: String? {
            switch self { case .refused(let code): "HTTP \(code)" }
        }
    }

    static func send(_ request: KhaytEngine.PlugRequest,
                     fetch: (URLRequest) async throws -> (Data, URLResponse) = { r in
                         try await URLSession(configuration: .ephemeral).data(for: r) }) async throws -> JSONValue {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
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
