import Foundation

/// How the shop's orders appear in the customer portal
/// (`GET | PUT /v1/shops/{id}/portal-settings`, khayt-cloud #196, Nov 2026).
///
/// `crossShop`: whether a customer who opens the portal from ANOTHER Khayt
/// shop's pages also sees this shop's orders beside that shop's. On by
/// default; off, a customer sees this shop's orders only when they come from
/// this shop's own pages (Turki, via the website review).
///
/// Anyone signed in may read it; only the owner or a manager may write (403
/// `role`). A body the cloud will not take is 400 `bad-portal-settings`.
public enum CloudPortalSettings {

    public struct Settings: Sendable, Equatable {
        public let crossShop: Bool
        public let updatedAt: String?
    }

    public typealias Refusal = CloudPayLink.Refusal

    /// The shop's choice. A missing or unreadable value is ON — the default.
    public static func get(_ connection: CloudReader.Connection, token: String,
                           fetch: S3.Fetch) async throws -> Settings {
        settings(from: try await send(connection, token, "GET", body: nil, fetch: fetch))
    }

    @discardableResult
    public static func put(crossShop: Bool, _ connection: CloudReader.Connection,
                           token: String, fetch: S3.Fetch) async throws -> Settings {
        settings(from: try await send(connection, token, "PUT", body: ["crossShop": crossShop], fetch: fetch))
    }

    static func settings(from data: Data) -> Settings {
        let o = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
        let on = (o?["crossShop"] as? Bool) ?? true
        return Settings(crossShop: on, updatedAt: o?["updatedAt"] as? String)
    }

    static func send(_ connection: CloudReader.Connection, _ token: String, _ method: String,
                     body: [String: Bool]?, fetch: S3.Fetch) async throws -> Data {
        var request = try CloudReader.request(connection, token: token, method: method, tail: "/portal-settings")
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
