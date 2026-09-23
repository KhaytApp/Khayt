import Foundation
import KhaytCore

/// Signing this Mac in to a shop's cloud.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// `settings.cloud.token` is a SESSION token the server issues at login, sealed
/// against the Keychain of the machine that obtained it. Move a shop's book to
/// another Mac and it arrives unreadable — correctly, that is what sealing is
/// for — and until this file there was no way to obtain a new one here. The
/// whole cloud half of the app went quiet, and the only cure was to open the
/// other app, which is the thing this app exists not to need.
///
/// Everything AFTER the token already worked: `CloudReader` pulls,
/// `SyncCrypto.unwrapDek` unlocks, `CloudWriter` pushes. This is the one
/// missing call.
///
/// ── WHAT IT DOES NOT DO ───────────────────────────────────────────────────
///
/// Creating an ACCOUNT, and creating a shop's first KEYSET. A keyset made here
/// would be the only copy of the key to a shop's cloud data until it reached
/// the server, and showing a recovery key before the server has it tells an
/// owner their shop is recoverable when it is not. That is a flow with its own
/// failure modes, not a branch of this one. An account that has a keyset — every
/// shop that has ever synced — signs in here.
public enum CloudSignIn {

    /// Ten seconds, as every other call this app makes.
    public static let timeout: TimeInterval = 10

    public struct Session: Sendable {
        public let shopId: String
        /// Plaintext, straight off the wire. The caller seals it before it
        /// touches the book and never keeps this copy.
        public let token: String
        public let keyset: JSONValue?
        public let role: String
        public let verified: Bool

        public init(shopId: String, token: String, keyset: JSONValue?, role: String, verified: Bool) {
            self.shopId = shopId; self.token = token; self.keyset = keyset; self.role = role; self.verified = verified
        }
    }

    public enum Failure: Error, LocalizedError {
        case badAddress(String)
        case wrongCredentials
        case noKeyset
        case redirected
        case unreachable(String)
        case refused(Int, String)

        public var errorDescription: String? {
            switch self {
            case .badAddress(let why): return why
            case .wrongCredentials: return "That email and password were refused"
            case .noKeyset:
                return "This account has no sync key yet, so there is nothing to unlock. "
                     + "The first one is made when a shop first connects."
            case .redirected: return "The server redirected the request — refusing to follow"
            case .unreachable(let why): return why
            case .refused(let code, let why):
                return why.isEmpty ? "The server refused the sign-in (HTTP \(code))" : why
            }
        }
    }

    /// `POST /v1/login`, the same call `lib/cloud-client.js:login` makes.
    ///
    /// The address is put through the shared rule first: it is typed by a
    /// person, self-hosting is supported, and an EMAIL AND PASSWORD are the
    /// very first thing sent to it — which is the reason that rule exists.
    public static func logIn(url: String, email: String, password: String,
                      engine: KhaytEngine,
                      session: URLSession? = nil) async throws -> Session {
        let body: [String: JSONValue]
        do {
            body = try await post(path: "/v1/login",
                                  fields: ["email": .string(email), "password": .string(password)],
                                  url: url, engine: engine, session: session)
        } catch Failure.refused(401, _) {
            // The ordinary wrong-password answer, and it deserves its own
            // sentence rather than a bare HTTP number.
            throw Failure.wrongCredentials
        }

        guard case .string(let shopId)? = body["shopId"], !shopId.isEmpty,
              case .string(let token)? = body["token"], !token.isEmpty else {
            throw Failure.refused(200, "The server's answer had no shop in it")
        }
        var role = "owner"
        if case .string(let r)? = body["role"], !r.isEmpty { role = r }
        // Absent means UNKNOWN, and unknown must not read as verified — the
        // same reasoning `lib/cloud-client.js` spells out for an older server.
        var verified = false
        if case .bool(true)? = body["verified"] { verified = true }

        let keyset: JSONValue?
        if case .object(let k)? = body["keyset"], !k.isEmpty { keyset = .object(k) } else { keyset = nil }

        return Session(shopId: shopId, token: token, keyset: keyset,
                       role: role, verified: verified)
    }

    /// Ask the server to email a reset code.
    ///
    /// `POST /v1/request-reset`, and it **always succeeds** by design: an
    /// endpoint that answered differently for an address it has never heard of
    /// would be a way to ask which emails have accounts. So the answer carries
    /// two flags instead, and they are the useful part — a server with no mail
    /// configured accepts the request and delivers nothing, which looks exactly
    /// like an email that has not arrived yet.
    ///
    /// Returns `(configured, failed)`: told to the shop rather than swallowed,
    /// so "no code came" and "this server cannot send mail" are different
    /// sentences.
    @discardableResult
    public static func requestReset(url: String, email: String, engine: KhaytEngine,
                             session: URLSession? = nil)
    async throws -> (configured: Bool, failed: Bool) {
        let body = try await post(path: "/v1/request-reset",
                                  fields: ["email": .string(email)],
                                  url: url, engine: engine, session: session)
        var configured = false, failed = false
        if case .bool(true)? = body["emailConfigured"] { configured = true }
        if case .bool(true)? = body["emailFailed"] { failed = true }
        return (configured, failed)
    }

    /// Set a new account password with the emailed code.
    ///
    /// `POST /v1/reset-password`. THIS CHANGES THE ACCOUNT PASSWORD AND NOTHING
    /// ELSE. The shop's data stays encrypted under the key the sync passphrase
    /// wraps — a reset does not touch it, cannot read it, and does not open a
    /// shop whose passphrase is the thing that was lost. Saying so is the
    /// difference between a shop that reaches for its recovery key and one that
    /// resets a password and wonders why nothing opened.
    public static func resetPassword(url: String, email: String, code: String,
                              newPassword: String, engine: KhaytEngine,
                              session: URLSession? = nil) async throws {
        _ = try await post(path: "/v1/reset-password",
                           fields: ["email": .string(email),
                                    "code": .string(code),
                                    "newPassword": .string(newPassword)],
                           url: url, engine: engine, session: session)
    }

    /// One POST, with the address checked and redirects refused.
    ///
    /// Shared by all three calls because all three carry something that must
    /// not be handed to a redirect: a password, a reset code, or an address
    /// being probed for an account.
    private static func post(path: String, fields: [String: JSONValue],
                             url: String, engine: KhaytEngine,
                             session: URLSession?) async throws -> [String: JSONValue] {
        let base: String
        do { base = try await engine.cloudBaseUrl(url) }
        catch {
            throw Failure.badAddress((error as? LocalizedError)?.errorDescription
                                     ?? String(describing: error))
        }
        guard let endpoint = URL(string: base + path) else {
            throw Failure.badAddress("That address cannot be read")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (session ?? Self.session).data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) { throw Failure.redirected }
        let body = (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
        guard status == 200 else {
            // The server's own sentence where it has one: "that code has
            // expired" is a thing a shop can act on and an HTTP number is not.
            var why = ""
            if case .string(let e)? = body["error"] { why = e }
            throw Failure.refused(status, why)
        }
        return body
    }

    /// A session that does NOT follow redirects.
    ///
    /// An email and a password are in this request body. A 302 would hand them
    /// to whoever the redirect names, and `URLSession.shared` follows redirects
    /// and cannot be given a delegate — so the refusal is armed here, before
    /// anything is sent, rather than checked after the fact.
    private static let session: URLSession = {
        URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
