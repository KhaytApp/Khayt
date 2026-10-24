import Foundation

/// The shop's team and signed-in devices on Khayt Cloud — khayt-cloud
/// `docs/api-contract.md` "members/invite", "members", "devices".
///
/// What it is for, beyond tidiness: after a leak, the owner has to see which
/// tokens are still being used (`lastUsedOn`), sign one out, and issue a
/// replacement account — from the app the shop actually works in.
///
/// Every call goes through `CloudReader.request`, for the Bearer token and the
/// `x-delta-capable` header (a call without it would shut the delta gate).
public enum CloudTeam {

    public struct Member: Decodable, Sendable, Equatable, Identifiable {
        public let email: String
        public let role: String
        public let verified: Bool?
        public var id: String { email }
    }

    public struct Device: Decodable, Sendable, Equatable, Identifiable {
        /// The first 12 hex digits of the token's locator, or `shop` for the
        /// shop's own registration token (which cannot be signed out here).
        public let id: String
        /// The email it was issued to; nil for the shop's own token.
        public let account: String?
        public let role: String?
        public let createdAt: String?
        /// `YYYY-MM-DD` (UTC), or nil when it has never been used.
        public let lastUsedOn: String?
        /// This is the token this app is using.
        public let current: Bool?
        public var isShopKey: Bool { id == "shop" }
    }

    /// The roles an invite can give. `owner` is not one: the cloud stores
    /// anything else as `operator`.
    public static let invitableRoles = ["manager", "operator", "viewer"]

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let status: Int
        /// The cloud's own sentence (these routes answer `{error}`, not `reason`).
        public let error: String
        public var description: String { "Khayt Cloud refused (\(status))" + (error.isEmpty ? "" : ": \(error)") }
    }

    public static func members(_ connection: CloudReader.Connection, token: String,
                               fetch: S3.Fetch) async throws -> [Member] {
        struct List: Decodable { let members: [Member] }
        return try decode(List.self, try await send(connection, token, "GET", "/members", fetch: fetch)).members
    }

    /// Invite `email` as `role`. Answers whether the cloud could email the code
    /// (it lasts 7 days); when it could not, the owner has to pass it on.
    public static func invite(_ email: String, role: String, _ connection: CloudReader.Connection,
                              token: String, fetch: S3.Fetch) async throws -> Bool {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = invitableRoles.contains(role) ? role : "operator"
        let data = try await send(connection, token, "POST", "/members/invite",
                                  body: ["email": address, "role": role], fetch: fetch)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (o?["emailConfigured"] as? Bool) ?? true
    }

    /// Remove a member. Their device tokens are revoked at once.
    public static func remove(_ email: String, _ connection: CloudReader.Connection, token: String,
                              fetch: S3.Fetch) async throws {
        _ = try await send(connection, token, "DELETE", "/members/" + email.uriComponent, fetch: fetch)
    }

    public static func devices(_ connection: CloudReader.Connection, token: String,
                               fetch: S3.Fetch) async throws -> [Device] {
        struct List: Decodable { let devices: [Device] }
        return try decode(List.self, try await send(connection, token, "GET", "/devices", fetch: fetch)).devices
    }

    /// Sign one device out: its next request is refused.
    public static func signOut(device id: String, _ connection: CloudReader.Connection, token: String,
                               fetch: S3.Fetch) async throws {
        _ = try await send(connection, token, "DELETE", "/devices/" + id.uriComponent, fetch: fetch)
    }

    // MARK: - Plumbing

    static func send(_ connection: CloudReader.Connection, _ token: String, _ method: String, _ tail: String,
                     body: [String: String]? = nil, fetch: S3.Fetch) async throws -> Data {
        var request = try CloudReader.request(connection, token: token, method: method, tail: tail)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await fetch(request)
        let code = S3.status(response)
        guard (200..<300).contains(code) else {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Refusal(status: code, error: (o?["error"] as? String) ?? "")
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw VaultClient.Failure.badReply("team") }
    }
}
