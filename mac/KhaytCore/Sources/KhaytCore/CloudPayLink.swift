import Foundation

/// The shop's own payment link on Khayt Cloud
/// (`GET | PUT | DELETE /v1/shops/{id}/payment-link`, khayt-cloud 2026-11-03).
///
/// Khayt takes no money for a shop's customers: the shop pastes its provider's
/// link (Tap, Moyasar, StreamPay, a bank page) once, and the customer's page
/// shows Pay deposit / Pay balance / Pay beside it. `{amount}` (or `{total}`)
/// in the link is replaced by the amount the button asks for.
///
/// Anyone signed in may read it; only the owner or a manager may write (others
/// get 403 `role`). A link the cloud will not take is 400 `bad-pay-link` with
/// an `error` string worth showing as it is. https only, at most 500
/// characters; the label at most 40.
public enum CloudPayLink {

    public static let maxUrl = 500
    public static let maxLabel = 40

    public struct Link: Sendable, Equatable {
        public let url: String
        public let label: String?
        public let updatedAt: String?
    }

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let status: Int
        /// `role` for a sign-in that may not write, `bad-pay-link` for a link
        /// the cloud will not take; empty otherwise.
        public let reason: String
        public let error: String
        public var description: String { "Khayt Cloud refused (\(status))" + (error.isEmpty ? "" : ": \(error)") }
    }

    /// The shop's link, or nil when it has none (the cloud answers `null`, or
    /// an object whose `url` is null).
    public static func get(_ connection: CloudReader.Connection, token: String,
                           fetch: S3.Fetch) async throws -> Link? {
        link(from: try await send(connection, token, "GET", body: nil, fetch: fetch))
    }

    /// Save the link. An empty label is left out rather than sent as "".
    @discardableResult
    public static func put(url: String, label: String, _ connection: CloudReader.Connection,
                           token: String, fetch: S3.Fetch) async throws -> Link? {
        var body: [String: String] = ["url": url.trimmingCharacters(in: .whitespacesAndNewlines)]
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !l.isEmpty { body["label"] = l }
        return link(from: try await send(connection, token, "PUT", body: body, fetch: fetch))
    }

    public static func remove(_ connection: CloudReader.Connection, token: String,
                              fetch: S3.Fetch) async throws {
        _ = try await send(connection, token, "DELETE", body: nil, fetch: fetch)
    }

    // MARK: - Plumbing

    static func link(from data: Data) -> Link? {
        let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = o as? [String: Any], let url = dict["url"] as? String, !url.isEmpty else { return nil }
        return Link(url: url, label: dict["label"] as? String, updatedAt: dict["updatedAt"] as? String)
    }

    static func send(_ connection: CloudReader.Connection, _ token: String, _ method: String,
                     body: [String: String]?, fetch: S3.Fetch) async throws -> Data {
        var request = try CloudReader.request(connection, token: token, method: method, tail: "/payment-link")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await fetch(request)
        let code = S3.status(response)
        guard (200..<300).contains(code) else {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Refusal(status: code, reason: (o?["reason"] as? String) ?? "",
                          error: (o?["error"] as? String) ?? "")
        }
        return data
    }
}
