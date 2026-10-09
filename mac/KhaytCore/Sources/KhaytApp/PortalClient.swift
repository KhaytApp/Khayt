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
        /// A refusal `lib/portal-owner.js errorFor` has named: `code` is what it
        /// means (`viewer`, `other_shop`, …), `text` the server's own words.
        case owner(KhaytEngine.PortalError)

        var errorDescription: String? {
            switch self {
            case .badAddress(let why): return why
            case .redirected: return "The server redirected the request — refusing to follow"
            case .unreachable(let why): return why
            case .refused(let code, let why):
                return why.isEmpty ? "The cloud refused the update (HTTP \(code))" : why
            case .owner(let said): return said.text
            }
        }
    }

    // MARK: - The owner calls

    /// Publish a job's link for the first time — the same PUT a republish
    /// sends. Returns the note when the link went up but the customer's
    /// address was not linked (the shop's daily allowance of new addresses).
    static func publish(_ request: PortalRefresh, baseUrl: String, shopId: String,
                        token: String, engine: KhaytEngine,
                        session: URLSession? = nil) async throws -> String? {
        var body: [String: JSONValue] = ["kind": .string(request.kind), "payload": request.payload]
        if !request.customerEmail.isEmpty { body["customerEmail"] = .string(request.customerEmail) }
        let path = try await engine.portalOwnerPath("item", shopId: shopId, pubToken: request.pubToken)
        let reply = try await send("PUT", path, body: .object(body), baseUrl: baseUrl, token: token,
                                   engine: engine, session: session)
        return try? await engine.portalLinkNote(body: reply)
    }

    /// Take a job's link down.
    static func unpublish(pubToken: String, baseUrl: String, shopId: String, token: String,
                          engine: KhaytEngine, session: URLSession? = nil) async throws {
        let path = try await engine.portalOwnerPath("item", shopId: shopId, pubToken: pubToken)
        _ = try await send("DELETE", path, body: nil, baseUrl: baseUrl, token: token,
                           engine: engine, session: session)
    }

    /// Every published item with what its customer did: `{ items: [...] }`.
    static func listPublished(baseUrl: String, shopId: String, token: String,
                              engine: KhaytEngine, session: URLSession? = nil) async throws -> JSONValue {
        let path = try await engine.portalOwnerPath("list", shopId: shopId)
        let reply = try await send("GET", path, body: nil, baseUrl: baseUrl, token: token,
                                   engine: engine, session: session)
        if case .object(let o) = reply, let items = o["items"] { return items }
        return .array([])
    }

    /// The conversation behind a link — the OWNER's route, never the
    /// customer's (`lib/portal-owner.js paths.messages`).
    static func messages(pubToken: String, baseUrl: String, shopId: String, token: String,
                         engine: KhaytEngine, session: URLSession? = nil) async throws -> [KhaytEngine.PortalMessage] {
        let path = try await engine.portalOwnerPath("messages", shopId: shopId, pubToken: pubToken)
        let reply = try await send("GET", path, body: nil, baseUrl: baseUrl, token: token,
                                   engine: engine, session: session)
        return try await engine.portalThread(body: reply)
    }

    /// Answer the customer, as the shop.
    static func reply(pubToken: String, text: String, baseUrl: String, shopId: String, token: String,
                      engine: KhaytEngine, session: URLSession? = nil) async throws {
        let path = try await engine.portalOwnerPath("reply", shopId: shopId, pubToken: pubToken)
        _ = try await send("POST", path, body: .object(["text": .string(text)]), baseUrl: baseUrl,
                           token: token, engine: engine, session: session)
    }

    /// One owner request, with every rule `republish` keeps: the address
    /// validated and https only, the bearer in the header and nowhere else,
    /// redirects refused, ten seconds. A non-200 is named by
    /// `lib/portal-owner.js errorFor`.
    private static func send(_ method: String, _ path: String, body: JSONValue?, baseUrl: String,
                             token: String, engine: KhaytEngine,
                             session: URLSession?) async throws -> JSONValue {
        let base: String
        do {
            base = try await engine.cloudBaseUrl(baseUrl)
            try CloudSignIn.requireHttps(base)
        } catch {
            throw Failure.badAddress((error as? LocalizedError)?.errorDescription
                                     ?? String(describing: error))
        }
        guard !path.isEmpty, let url = URL(string: base + path) else {
            throw Failure.badAddress("That address cannot be read")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.fetchCapped(request, session: session)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) { throw Failure.redirected }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard status == 200 else {
            if let said = try? await engine.portalError(status: status, body: json) { throw Failure.owner(said) }
            throw Failure.refused(status, serverReason(data))
        }
        return json
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
            // https only — the bearer token rides in the header. See
            // `CloudSignIn.requireHttps`.
            try CloudSignIn.requireHttps(base)
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
            (data, response) = try await Self.fetchCapped(request, session: session)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) { throw Failure.redirected }
        guard status == 200 else { throw Failure.refused(status, serverReason(data)) }
    }

    /// The most of a response this reads. A portal answer is a few kilobytes;
    /// the address is the shop's own setting and can be any server, and
    /// `data(for:)` buffered whatever it sent (alpha.62 review).
    static let maxResponse = 4 << 20

    /// `data(for:)`, read as a stream and stopped at `maxResponse`.
    static func fetchCapped(_ request: URLRequest, session: URLSession?) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await (session ?? Self.session).bytes(for: request)
        if response.expectedContentLength > Int64(maxResponse) {
            throw Failure.unreachable("The server's answer is too large")
        }
        var data = Data()
        data.reserveCapacity(min(maxResponse, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponse { throw Failure.unreachable("The server's answer is too large") }
        }
        return (data, response)
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

