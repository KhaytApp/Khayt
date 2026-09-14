import Foundation
import KhaytCore

/// Keeping the customer's tracking link current.
///
/// A published job's link shows what the job is doing. When the job moves, the
/// page has to be republished or it goes on saying "Printing" after the thing
/// has been collected — and the customer is watching that page rather than
/// asking, which is the entire point of having published it.
///
/// The REQUEST is `lib/portal-refresh.js` — what to say, whether to say it, and
/// the path to say it at. This is the PUT.
///
/// ── THE ADDRESS IS THE SHOP'S, SO IT IS CHECKED ───────────────────────────
///
/// `settings.cloud.url` supports self-hosting, so it is a value a person typed,
/// and it can arrive on this machine by sync from another one. A bearer token
/// rides in the header of every request sent to it. So the base URL goes
/// through `KhaytBaseUrl.validateBaseUrl` — the same rule `lib/cloud-client.js`
/// applies before it sends anything — rather than being concatenated into a
/// URL because it was already in the book.
///
/// Redirects are refused rather than followed, for the reason `WebhookClient`
/// refuses them: a 302 walks the request, and its token, somewhere else.
@MainActor
enum PortalClient {

    /// Ten seconds, as the webhooks and the mail providers. A shop moving a
    /// card should not wait on a cloud that is not answering.
    static let timeout: TimeInterval = 10

    enum Failure: Error, LocalizedError {
        case badAddress(String)
        case redirected
        case unreachable(String)
        case refused(Int, String)

        var errorDescription: String? {
            switch self {
            case .badAddress(let why): return why
            case .redirected: return "The server redirected the request — refusing to follow"
            case .unreachable(let why): return why
            case .refused(let code, let why):
                return why.isEmpty ? "The cloud refused the update (HTTP \(code))" : why
            }
        }
    }

    /// Republish one job's portal item, and wait for the cloud to take it.
    ///
    /// AWAITED, like the Telegram message and the webhooks: the move was
    /// refused in the first place because this could not be done, so a send
    /// nobody looks at would put the app back where it started — a customer
    /// reading a page that is quietly out of date.
    ///
    /// `token` is the shop's cloud bearer token, already opened.
    static func republish(_ refresh: PortalRefresh, baseUrl: String, shopId: String,
                          token: String, engine: KhaytEngine,
                          session: URLSession? = nil) async throws {
        let base: String
        do {
            base = try await engine.cloudBaseUrl(baseUrl)
        } catch {
            throw Failure.badAddress((error as? LocalizedError)?.errorDescription
                                     ?? String(describing: error))
        }
        let path = (try? await engine.portalPath(shopId: shopId, pubToken: refresh.pubToken)) ?? ""
        guard !path.isEmpty, let url = URL(string: base + path) else {
            throw Failure.badAddress("That address cannot be read")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }

        // The body `lib/cloud-client.js:publishPortal` sends: the kind, the
        // payload, and the customer's address only when there is one. An empty
        // `customerEmail` is OMITTED rather than sent as "", because the server
        // reads its presence as "link this to an account".
        var body: [String: JSONValue] = [
            "kind": .string(refresh.kind),
            "payload": refresh.payload,
        ]
        if !refresh.customerEmail.isEmpty {
            body["customerEmail"] = .string(refresh.customerEmail)
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (session ?? Self.session).data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) { throw Failure.redirected }
        guard status == 200 else { throw Failure.refused(status, serverReason(data)) }
    }

    /// A session that does NOT follow redirects.
    ///
    /// `URLSession.shared` follows them, and it cannot be given a delegate — so
    /// checking for a 3xx after the fact would check the status of wherever the
    /// redirect LANDED, having already sent the shop's bearer token there. The
    /// refusal has to be armed before the request goes out, which is what a
    /// delegate on an own session is for. `lib/cloud-client.js` says the same
    /// thing as `redirect: 'manual'`.
    private static let session: URLSession = {
        URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // nil = do not follow; the 3xx is handed back as the response.
            completionHandler(nil)
        }
    }

    /// What the cloud said, when it said anything worth repeating.
    private static func serverReason(_ data: Data) -> String {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return body["error"] as? String ?? ""
    }
}

