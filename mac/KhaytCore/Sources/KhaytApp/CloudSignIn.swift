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
enum CloudSignIn {

    /// Ten seconds, as every other call this app makes.
    static let timeout: TimeInterval = 10

    struct Session {
        let shopId: String
        /// Plaintext, straight off the wire. The caller seals it before it
        /// touches the book and never keeps this copy.
        let token: String
        let keyset: JSONValue?
        let role: String
        let verified: Bool
    }

    enum Failure: Error, LocalizedError {
        case badAddress(String)
        case wrongCredentials
        case noKeyset
        case redirected
        case unreachable(String)
        case refused(Int, String)

        var errorDescription: String? {
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
    static func logIn(url: String, email: String, password: String,
                      engine: KhaytEngine,
                      session: URLSession? = nil) async throws -> Session {
        let base: String
        do { base = try await engine.cloudBaseUrl(url) }
        catch {
            throw Failure.badAddress((error as? LocalizedError)?.errorDescription
                                     ?? String(describing: error))
        }
        guard let endpoint = URL(string: base + "/v1/login") else {
            throw Failure.badAddress("That address cannot be read")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "email": .string(email), "password": .string(password),
        ]))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (session ?? Self.session).data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) { throw Failure.redirected }
        // 401 is the ordinary wrong-password answer and deserves its own
        // sentence rather than a bare HTTP number.
        if status == 401 { throw Failure.wrongCredentials }

        let body = (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
        guard status == 200 else {
            var why = ""
            if case .string(let e)? = body["error"] { why = e }
            throw Failure.refused(status, why)
        }
        guard case .string(let shopId)? = body["shopId"], !shopId.isEmpty,
              case .string(let token)? = body["token"], !token.isEmpty else {
            throw Failure.refused(status, "The server's answer had no shop in it")
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
