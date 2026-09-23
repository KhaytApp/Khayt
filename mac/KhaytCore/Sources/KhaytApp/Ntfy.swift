import Foundation
import KhaytCore

/// A push to the shop's phone through ntfy (ntfy.sh, or its own server).
///
/// The request — where, the title, the priority, the tag — is
/// `lib/alert-routes.js`'s. Only the sending is here. An access token, for a
/// self-hosted server or a protected topic, is sealed in the book and opened at
/// the moment it is sent.
@MainActor
enum Ntfy {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case badAddress
        case refused(Int)
        var description: String {
            switch self {
            case .badAddress: "The ntfy server or topic is not one ntfy can use."
            case .refused(let code): "ntfy answered \(code)."
            }
        }
    }

    static func send(_ request: KhaytEngine.NtfyRequest, token: String,
                     fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws {
        guard let url = URL(string: request.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw Failure.badAddress
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 10
        for (name, value) in request.headers where !value.isEmpty { r.setValue(value, forHTTPHeaderField: name) }
        if !token.isEmpty { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        r.httpBody = Data(request.body.utf8)
        let (_, response) = try await (fetch ?? { try await URLSession.shared.data(for: $0) })(r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.refused(code) }
    }
}
