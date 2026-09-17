import Foundation
import Network
import KhaytCore

/// The phone's way in: a small HTTP server on the shop's own network.
///
/// ── WHAT THIS IS, AND IS NOT ──────────────────────────────────────────────
///
/// The Windows and Linux app runs `lib/lan-server.js` — 3,200 lines of Node
/// HTTP that serve a phone the live queue, take a customer's print request,
/// show a quote to approve, feed a calendar and answer webhooks. None of that
/// can run here: it wants `node:http`, `node:fs` and `node:crypto` at module
/// scope. What CAN run here is everything that is a rule rather than
/// plumbing, and that has been lifted out as it is needed: the lockout in
/// front of the PIN (`lib/lan-auth.js`) and what the phone is shown
/// (`lib/lan-pages.js`). This file is the plumbing — a listener, an HTTP/1.1
/// parser wide enough for what phones send, the gate, and a route table —
/// and it serves the SAME BYTES the Node server serves, from the same
/// modules, which `LanServerTests` holds it to.
///
/// This first slice is the floor: the live queue page, the status and queue
/// APIs, and the three files that make the queue installable on a phone's
/// home screen. The intake form, quote approval, the calendar feed and the
/// webhooks are the other app's still; they follow, one slice each.
///
/// ── THE GATE ──────────────────────────────────────────────────────────────
///
/// Owner data (names of customers and jobs) is behind the shop's PIN, sent
/// as `x-khayt-pin` or `?pin=`. Ten wrong PINs from one address lock it out
/// for a minute — the rule is `lan-auth`'s, run in JavaScriptCore, so the two
/// apps cannot come to disagree about what a lockout is. The comparison is
/// constant-time and in Swift: a primitive, not a rule (see lan-auth.js).
/// Every response carries the same four security headers, JSON included,
/// set once before any route runs — the shape the Node server arrived at
/// after finding a route that had forgotten them.
@MainActor
final class LanServer {

    /// Where the listener binds. A test binds loopback on an ephemeral port;
    /// a shop binds every interface so a phone on the Wi‑Fi can reach it.
    enum Bind: Sendable { case loopback, lan }

    /// What the server needs from the shop, as closures so a test can hand it
    /// a fixture book and a fixed clock.
    struct Host {
        /// The book, as `lan-pages` reads it: printLog, waitingList, settings, machines.
        var store: @MainActor () -> [String: JSONValue]
        /// The owner PIN, opened. Empty means "not configured": owner routes refuse.
        var pin: String
        var engine: KhaytEngine
        /// The clock, for the page's "Updated 09:16" and the lockout arithmetic.
        var now: () -> Date = { Date() }
        /// The time as the page prints it. Injectable so a test can render the
        /// same page twice and compare.
        var nowText: () -> String = { LanServer.clockText(Date()) }
        /// A PWA icon by file name, or nil.
        var icon: (String) -> Data? = { LanServer.bundledIcon($0) }
        /// The calendar subscription token (`settings.lanApi.calendarToken`),
        /// opened. Empty means only the owner PIN opens the feed.
        var calendarToken: String = ""
        /// The legacy intake token (`settings.lanApi.intakeToken`), opened.
        /// Empty means the header route is closed; the cookie route is open.
        var intakeToken: String = ""
        /// Write one intake entry into the book's `waitingList`. Throws when
        /// the book cannot be written, which the customer is told is OUR
        /// failure, not theirs.
        var record: (JSONValue) async throws -> Void = { _ in throw CocoaError(.fileWriteUnknown) }
        /// The id an entry is minted with — the Node server's `uniqueLanId`.
        var mintId: () -> String = { LanServer.uniqueId("intake") }
        /// Random bytes for a session token, hex. Injectable for a test.
        var token: () -> String = { LanServer.randomToken() }
        /// Apply a customer's approval to the book, inside the write. Returns
        /// the approved record, or nil when the rule refused on the book as it
        /// is NOW (it moved underneath the phone). Throws when the book cannot
        /// be written.
        var approve: (String, String) async throws -> JSONValue? = { _, _ in throw CocoaError(.fileWriteUnknown) }
        /// Write a customer's survey onto the order that holds `token`, inside
        /// the write. Returns false when no order holds it any more (spent by
        /// a concurrent submit, or never issued). Throws when the book cannot
        /// be written.
        var survey: (_ token: String, _ rating: Double, _ comment: String?, _ nowIso: String) async throws -> Bool
            = { _, _, _, _ in throw CocoaError(.fileWriteUnknown) }
        /// Measure an uploaded mesh. The bytes are written to a scratch file,
        /// read, and deleted — Khayt does not keep a stranger's model on the
        /// shop's disk, which keeps retention and consent simple.
        var measure: (Data, String) throws -> JSONValue? = { data, ext in
            try LanServer.measureUpload(data, ext: ext)
        }
        /// Slice a CLEARED upload with the shop's own slicer and take the
        /// slicer's own figures. Nil when the shop has not turned this on, has
        /// no slicer, or the slice produced nothing usable — in every case the
        /// caller falls back to measuring the shape, which is what it did
        /// before this existed.
        var sliceUpload: (Data, String) async -> JSONValue? = { _, _ in nil }
    }

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]   // lower-cased names
        let body: Data
        let remote: String
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ status: Int, _ body: String) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
        static func redirect(_ location: String) -> Response {
            Response(status: 302, headers: ["Location": location, "Cache-Control": "no-cache"])
        }
        /// JSON a customer's browser may read from any origin — the intake
        /// routes, which the Node server answers with `Access-Control-Allow-Origin: *`.
        static func open(_ status: Int, _ body: String) -> Response {
            Response(status: status,
                     headers: ["Content-Type": "application/json", "Access-Control-Allow-Origin": "*"],
                     body: Data(body.utf8))
        }
        static func html(_ status: Int, _ html: String, extra: [String: String] = [:]) -> Response {
            var headers = ["Content-Type": "text/html; charset=utf-8"]
            for (k, v) in extra { headers[k] = v }
            return Response(status: status, headers: headers, body: Data(html.utf8))
        }
    }

    let host: Host
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private(set) var running = false
    /// Failed PINs by address — the Node server's `failedAttempts` map.
    private var failures: [String: KhaytEngine.LanFailures] = [:]
    /// Intake form sessions by token — the Node server's `intakeSessions`.
    private var sessions: [String: (created: Date, ip: String)] = [:]
    /// Form opens and form submissions per address, each its own bucket.
    private var grants: [String: KhaytEngine.LanFailures] = [:]
    private var submits: [String: KhaytEngine.LanFailures] = [:]
    private var surveys: [String: KhaytEngine.LanFailures] = [:]
    private var estimates: [String: KhaytEngine.LanFailures] = [:]
    /// What was quoted, by reference — so a submitted form is attached to the
    /// figure THIS server produced and not to whatever the browser posts back.
    private var quoted: [String: (quote: JSONValue, at: Date, ip: String)] = [:]
    /// Meshes being measured right now. Reading a 32 MB model is not free, and
    /// three at once is a shop's machine given over to strangers.
    private var measuring = 0
    nonisolated static let maxMeasuring = 3
    nonisolated static let maxUpload = 32 * 1024 * 1024
    /// Above this a model is measured but not walked for risk — the walk is
    /// the expensive half, and the shop can re-check it on a real printer.
    nonisolated static let maxRiskBytes = 8 * 1024 * 1024
    nonisolated static let quoteTTL: TimeInterval = 2 * 60 * 60
    static let maxFailureKeys = 5000
    static let maxBody = 1_048_576

    /// How long a client may take to finish sending its request.
    ///
    /// ── A HAND-ROLLED LISTENER GETS NO DEFAULTS ───────────────────────────
    ///
    /// Node's http server applies `headersTimeout` and `requestTimeout` on its
    /// own, so the other app has always been covered by machinery it never had
    /// to ask for. `NWListener` gives nothing: a client that connected and said
    /// nothing, or sent a `Content-Length` and then no body, was waited on for
    /// ever — no answer, no close, the connection and its task held until the
    /// app quit.
    ///
    /// That is a shop's Wi-Fi, so anyone on it could hold as many as they
    /// liked. Fifteen seconds is far longer than a phone on the same network
    /// needs and far shorter than "never".
    ///
    /// A `var` only so the tests can shorten it: a regression test for this
    /// that waited fifteen real seconds per connection would be a test people
    /// stop running.
    static var readTimeout: TimeInterval = 15

    init(host: Host) { self.host = host }

    // MARK: - Listening

    /// Start, and return the port actually bound (asked for 0, given one).
    func start(port wanted: UInt16, bind: Bind) async throws -> UInt16 {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: wanted) ?? .any
        let listener: NWListener
        switch bind {
        case .loopback:
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            listener = try NWListener(using: params)
        case .lan:
            listener = try NWListener(using: params, on: nwPort)
        }
        self.listener = listener

        let bound: UInt16 = try await withCheckedThrowingContinuation { cont in
            // The handler fires for every state for the listener's whole
            // life; the continuation may be resumed exactly once.
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { cont.resume(returning: listener.port?.rawValue ?? wanted) }
                case .failed(let error):
                    if once.first() { cont.resume(throwing: error) }
                case .cancelled:
                    if once.first() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel(); return }
                    await self.serve(connection)
                }
            }
            listener.start(queue: DispatchQueue(label: "khayt.lan.listener"))
        }
        port = bound
        running = true
        return bound
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        port = 0
    }

    // MARK: - One connection

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "khayt.lan.connection"))
        defer { connection.cancel() }
        let remote: String = {
            if case .hostPort(let h, _) = connection.endpoint { return "\(h)" }
            return "?"
        }()
        // ── THE READ IS BOUNDED, BY CANCELLING THE CONNECTION ─────────────
        //
        // A watchdog rather than a race between two tasks, and the difference
        // is the whole reason this works. `readRequest` parks in a
        // `withCheckedThrowingContinuation` waiting on `NWConnection.receive`,
        // and CANCELLING THAT TASK DOES NOT RESUME IT — only the connection's
        // own callback does. A task group would therefore wait for a child
        // that can never finish, and the `defer` that cancels the connection
        // cannot run until the group returns: a deadlock that holds the
        // connection exactly as long as having no timeout at all did. Measured,
        // not reasoned about — the first version of this fix was that deadlock
        // and the stalled connection was still open twenty seconds later.
        //
        // Cancelling the CONNECTION is what unblocks the read: the pending
        // receive fires with an error, `readRequest` throws, and this function
        // unwinds normally. The client sees the connection close, which is what
        // a read timeout looks like on the wire.
        let watchdog = Task { [connection] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { watchdog.cancel() }
        do {
            guard let request = try await readRequest(connection, remote: remote) else { return }
            // The head and body are in; the clock stops. A slow READER must not
            // be killed halfway through the response it asked for.
            watchdog.cancel()
            let response = await respond(to: request)
            try await write(response, method: request.method, to: connection)
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            try? await write(.open(413, #"{"error":"Request too large"}"#), method: "POST", to: connection)
        } catch {
            // A client that hung up mid-request, a read that ran out of time,
            // or a listener being stopped.
        }
    }

    /// Read one HTTP/1.1 request: the head to the blank line, then as much
    /// body as Content-Length says, capped. Nil when the client sent nothing.
    private func readRequest(_ connection: NWConnection, remote: String) async throws -> Request? {
        var buffer = Data()
        let headEnd = Data("\r\n\r\n".utf8)
        var headRange: Range<Data.Index>?
        while headRange == nil {
            guard let chunk = try await receive(connection) else { return nil }
            buffer.append(chunk)
            headRange = buffer.range(of: headEnd)
            if buffer.count > 64 * 1024 { throw URLError(.badServerResponse) }
        }
        let head = String(decoding: buffer[buffer.startIndex..<headRange!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        var body = Data(buffer[headRange!.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        if length > Self.maxBody { throw URLError(.dataLengthExceedsMaximum) }
        while body.count < length {
            guard let chunk = try await receive(connection) else { break }
            body.append(chunk)
        }
        // The target: path and query, the query percent-decoded.
        let target = requestLine[1]
        let components = URLComponents(string: target.hasPrefix("/") ? "http://localhost\(target)" : target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: requestLine[0].uppercased(), path: components?.path ?? target,
                       query: query, headers: headers, body: body, remote: remote)
    }

    private func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                cont.resume(returning: complete ? nil : Data())
            }
        }
    }

    private func write(_ response: Response, method: String, to connection: NWConnection) async throws {
        var lines = ["HTTP/1.1 \(response.status) \(Self.reason(response.status))"]
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if method != "HEAD" { data.append(response.body) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    nonisolated static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"; case 302: "Found"; case 400: "Bad Request"; case 401: "Unauthorized"
        case 404: "Not Found"; case 413: "Payload Too Large"; case 429: "Too Many Requests"
        default: "OK"
        }
    }

    // MARK: - The routes

    func respond(to request: Request) async -> Response {
        var response = await route(request)
        // Set for every response, JSON included, whatever the route did.
        let security = (try? await host.engine.lanSecurityHeaders()) ?? [:]
        for (name, value) in security where response.headers[name] == nil { response.headers[name] = value }
        return response
    }

    private func route(_ request: Request) async -> Response {
        let engine = host.engine
        let store = JSONValue.object(host.store())
        // `/v1` is the documented public surface and maps onto the same
        // handlers as `/api`, exactly as the Node server treats it.
        var path = request.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/v1" || path.hasPrefix("/v1/") { path = "/api" + path.dropFirst(3) }
        let isGet = request.method == "GET" || request.method == "HEAD"

        switch (path, isGet) {
        case ("/api/status", true):
            // Without `?format=json` a browser gets the intake form, as on the PC.
            if request.query["format"] != "json" { return .redirect("/intake") }
            let body = (try? await engine.lanStatusBody(store: store, today: Self.localDay(host.now()))) ?? "{}"
            return .json(200, body)

        case ("/api/queue", true):
            if let refused = await pinGate(request) { return refused }
            let body = (try? await engine.lanQueueBody(store: store)) ?? "[]"
            return .json(200, body)

        case ("", true), ("/", true):
            if case .object(let settings)? = host.store()["settings"], settings["onlineEnabled"] == .bool(true) {
                return .redirect("/intake")
            }
            if let refused = await pinGate(request) { return refused }
            let html = (try? await engine.lanQueuePage(store: store, now: host.nowText())) ?? ""
            return Response(status: 200,
                            headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache"],
                            body: Data(html.utf8))

        case ("/intake", true):
            return await intakePage(request, store: store)

        case (_, true) where Self.quotePath(path) != nil:
            return await quotePage(request, id: Self.quotePath(path)!, store: store)

        case (_, false) where request.method == "POST" && Self.approvePath(path) != nil:
            return await quoteApprove(request, id: Self.approvePath(path)!, store: store)

        case (_, true) where Self.trackingPath(path) != nil:
            return await trackingPage(request, id: Self.trackingPath(path)!, store: store)

        case ("/api/survey", false) where request.method == "POST":
            return await surveySubmit(request)

        case ("/calendar.ics", true):
            return await calendar(request, store: store)

        case ("/api/intake/estimate", false) where request.method == "POST":
            return await estimate(request, store: store)

        case ("/api/intake", false) where request.method == "POST":
            return await intakeSubmit(request, store: store)

        case ("/manifest.json", true):
            let body = (try? await engine.lanManifestBody(store: store)) ?? "{}"
            return Response(status: 200, headers: ["Content-Type": "application/manifest+json"], body: Data(body.utf8))

        case ("/sw.js", true):
            let js = (try? await engine.lanServiceWorker()) ?? ""
            return Response(status: 200,
                            headers: ["Content-Type": "application/javascript", "Service-Worker-Allowed": "/"],
                            body: Data(js.utf8))

        case ("/icon-192.png", true), ("/icon-512.png", true), ("/icon-maskable-512.png", true):
            let name = String(path.dropFirst())
            // The size the manifest asked for — not one file for all three.
            let png = host.icon(name) ?? Self.onePixel
            return Response(status: 200,
                            headers: ["Content-Type": "image/png", "Cache-Control": "public, max-age=86400"],
                            body: png)

        default:
            let body = (try? await engine.lanNotFoundBody()) ?? #"{"error":"Not found"}"#
            return .json(404, body)
        }
    }

    // MARK: - The intake form

    /// `GET /intake`. A visitor with a live session gets the form; one without
    /// gets the form AND a session cookie, unless this address has opened the
    /// form too often, which gets the "too many requests" page.
    private func intakePage(_ request: Request, store: JSONValue) async -> Response {
        let engine = host.engine
        let now = host.now()
        // The upload widget is offered exactly when the shop turned public
        // pricing on — which is also exactly when `/api/intake/estimate` will
        // answer. A widget whose request would be refused is worse than none.
        let page = (try? await engine.lanIntakePage(store: store,
                                                    quoteEnabled: Self.quotingIsOn(host.store()))) ?? ""
        let limits = try? await engine.lanIntakeLimits()
        if hasSession(request, now: now, sessionMs: limits?.SESSION_MS ?? 14_400_000) {
            return .html(200, page, extra: ["Cache-Control": "no-cache"])
        }
        let step = try? await engine.lanIntakeRate(grants[request.remote], now: now,
                                                   limit: Int(limits?.SESSION_GRANT_LIMIT ?? 40))
        if let step { grants[request.remote] = step.rec; sweep(&grants, now: now) }
        guard step?.allowed != false else {
            let tooMany = (try? await engine.lanIntakeTooManyPage()) ?? ""
            return .html(429, tooMany)
        }
        let token = grantSession(ip: request.remote, now: now, sessionMs: limits?.SESSION_MS ?? 14_400_000)
        let cookie = "\(limits?.COOKIE ?? "khayt_intake")=\(token); HttpOnly; Path=/; SameSite=Lax; Max-Age=\(Int((limits?.SESSION_MS ?? 14_400_000) / 1000))"
        return .html(200, page, extra: ["Cache-Control": "no-cache", "Set-Cookie": cookie])
    }

    /// `POST /api/intake`. The gate is the session cookie (or the legacy
    /// intake token header); then the submission rate; then the rule; then
    /// the book. The answers, in that order, are the Node server's.
    private func intakeSubmit(_ request: Request, store: JSONValue) async -> Response {
        let engine = host.engine
        let now = host.now()
        let limits = try? await engine.lanIntakeLimits()
        guard hasSession(request, now: now, sessionMs: limits?.SESSION_MS ?? 14_400_000) || hasIntakeToken(request) else {
            return .open(401, #"{"error":"Unauthorized"}"#)
        }
        let step = try? await engine.lanIntakeRate(submits[request.remote], now: now,
                                                   limit: Int(limits?.SUBMIT_LIMIT ?? 20))
        if let step { submits[request.remote] = step.rec; sweep(&submits, now: now) }
        guard step?.allowed != false else {
            return .open(429, #"{"error":"Too many submissions — try again later"}"#)
        }
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: request.body), case .object = body else {
            return .open(400, #"{"error":"Invalid request — please check your submission and try again"}"#)
        }
        var shopName = "this shop"
        if case .object(let settings)? = host.store()["settings"], case .string(let name)? = settings["shopName"],
           !name.isEmpty { shopName = name }
        var estimateRef: String?
        if case .object(let posted) = body, case .string(let ref)? = posted["estimateRef"] { estimateRef = ref }
        let priced = recallQuote(estimateRef, ip: request.remote, now: now)
        guard let outcome = try? await engine.lanIntakeSubmission(body: body, shopName: shopName, id: host.mintId(),
                                                                  nowIso: Self.isoNow(now), quoted: priced) else {
            return .open(500, #"{"error":"The shop could not record your request right now. Please try again shortly."}"#)
        }
        guard outcome.ok, let entry = outcome.entry else {
            let error = outcome.error ?? "Invalid request"
            let escaped = (try? String(decoding: JSONEncoder().encode(error), as: UTF8.self)) ?? "\"Invalid request\""
            return .open(Int(outcome.status ?? 400), "{\"error\":\(escaped)}")
        }
        do { try await host.record(entry) } catch {
            return .open(500, #"{"error":"The shop could not record your request right now. Please try again shortly."}"#)
        }
        return .open(200, #"{"ok":true}"#)
    }

    private func hasSession(_ request: Request, now: Date, sessionMs: Double) -> Bool {
        let cookies = Self.cookies(request.headers["cookie"] ?? "")
        guard let token = cookies["khayt_intake"], let session = sessions[token] else { return false }
        if now.timeIntervalSince(session.created) * 1000 > sessionMs {
            sessions.removeValue(forKey: token)
            return false
        }
        if !session.ip.isEmpty, session.ip != request.remote { return false }
        return true
    }

    private func hasIntakeToken(_ request: Request) -> Bool {
        guard !host.intakeToken.isEmpty else { return false }
        let provided = (request.headers["x-khayt-intake-token"] ?? "").trimmingCharacters(in: .whitespaces)
        return !provided.isEmpty && Self.constantTimeEqual(provided, host.intakeToken)
    }

    private func grantSession(ip: String, now: Date, sessionMs: Double) -> String {
        // Sessions only ever expired when their own token came back; sweep on
        // grant, as the Node server learned to.
        sessions = sessions.filter { now.timeIntervalSince($0.value.created) * 1000 <= sessionMs }
        let token = host.token()
        sessions[token] = (created: now, ip: ip)
        return token
    }

    private func sweep(_ map: inout [String: KhaytEngine.LanFailures], now: Date) {
        guard map.count > Self.maxFailureKeys else { return }
        let ms = now.timeIntervalSince1970 * 1000
        map = map.filter { $0.value.resetAt > ms }
        while map.count > Self.maxFailureKeys, let any = map.keys.first { map.removeValue(forKey: any) }
    }

    nonisolated static func cookies(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            out[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return out
    }

    /// The shop's clock as JavaScript's `toISOString()` prints it.
    nonisolated static func isoNow(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// `prefix-<ms since epoch>-<4 hex>` — the Node server's `uniqueLanId`.
    nonisolated static func uniqueId(_ prefix: String) -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let hex = String(format: "%04x", Int(UInt16.random(in: 0...UInt16.max)))
        return "\(prefix)-\(ms)-\(hex)"
    }

    nonisolated static func randomToken(bytes: Int = 32) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: - The customer's quote

    /// `/order/<id>/quote` → the id, with only the characters the Node route keeps.
    nonisolated static func quotePath(_ path: String) -> String? { orderPath(path, suffix: "/quote") }
    nonisolated static func approvePath(_ path: String) -> String? { orderPath(path, suffix: "/approve") }
    nonisolated static func orderPath(_ path: String, suffix: String) -> String? {
        guard path.hasPrefix("/order/"), path.hasSuffix(suffix) else { return nil }
        let raw = String(path.dropFirst("/order/".count).dropLast(suffix.count))
        guard !raw.isEmpty, !raw.contains("/") else { return nil }
        return raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private func order(_ id: String) -> JSONValue? {
        guard case .array(let log)? = host.store()["printLog"] else { return nil }
        return log.first { if case .object(let o) = $0, o["id"] == .string(id) { return true } else { return false } }
    }

    /// `GET /order/:id/quote`: the page a customer approves from, behind the
    /// job's own token — the same four answers as the Node route.
    private func quotePage(_ request: Request, id: String, store: JSONValue) async -> Response {
        let engine = host.engine
        let html: (Int, String) -> Response = { status, body in
            .html(status, body, extra: ["Cache-Control": "no-cache"])
        }
        guard case .object(let order)? = order(id) else {
            return html(404, (try? await engine.lanQuoteNotice("quote_not_found")) ?? "")
        }
        let token = (request.query["token"] ?? "").trimmingCharacters(in: .whitespaces)
        guard case .string(let expected)? = order["quoteApprovalToken"], !expected.isEmpty, !token.isEmpty,
              Self.constantTimeEqual(token, expected) else {
            return html(403, (try? await engine.lanQuoteNotice("invalid_link")) ?? "")
        }
        let status = Shop.plainString(order["status"]) ?? ""
        let hasQuote = Shop.plainBool(order["hasQuote"]) ?? false
        let alreadyApproved = status != "quote" && !(status == "on_hold" && hasQuote)
        let today = Self.localDay(host.now())
        var expired = false
        if !alreadyApproved {
            expired = (try? await engine.lanQuoteExpired(order: .object(order), today: today)) ?? false
        }
        let shopName = (try? await engine.lanQuoteShopName(store: store)) ?? "Khayt"
        var currency = ""
        if case .object(let settings)? = host.store()["settings"], case .string(let c)? = settings["currency"] { currency = c }
        let page = (try? await engine.lanQuotePage(order: .object(order), shopName: shopName,
                                                    approvePath: "/order/\(id)/approve", approvalToken: expected,
                                                    alreadyApproved: alreadyApproved, expired: expired,
                                                    currencyLabel: currency)) ?? ""
        return html(200, page)
    }

    /// `POST /order/:id/approve`: the customer's yes. Decided on the book as
    /// it is, then applied inside the write on the newest book.
    private func quoteApprove(_ request: Request, id: String, store: JSONValue) async -> Response {
        let engine = host.engine
        var parsed: [String: JSONValue] = [:]
        let trimmed = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let body = try? JSONDecoder().decode(JSONValue.self, from: request.body), case .object(let o) = body else {
                return .json(400, #"{"error":"Invalid JSON"}"#)
            }
            parsed = o
        }
        if case .string(let action)? = parsed["action"], action != "approve" {
            return .json(400, #"{"error":"Invalid action"}"#)
        }
        guard case .object(let order)? = order(id) else {
            return .html(404, (try? await engine.lanQuoteNotice("order_not_found")) ?? "")
        }
        var token = (request.query["token"] ?? "")
        if token.isEmpty, case .string(let t)? = parsed["approvalToken"] { token = t }
        token = token.trimmingCharacters(in: .whitespaces)
        guard case .string(let expected)? = order["quoteApprovalToken"], !expected.isEmpty, !token.isEmpty,
              Self.constantTimeEqual(token, expected) else {
            return .html(403, (try? await engine.lanQuoteNotice("invalid_link_approve")) ?? "")
        }
        let nowIso = Self.isoNow(host.now())
        guard let probe = try? await engine.lanQuoteApply(store: store, orderId: id, nowIso: nowIso), probe.found else {
            return .html(404, (try? await engine.lanQuoteNotice("order_not_found")) ?? "")
        }
        if probe.error == "expired" { return .html(410, (try? await engine.lanQuoteNotice("expired")) ?? "") }
        if probe.error != nil { return .html(409, (try? await engine.lanQuoteNotice("cannot_approve")) ?? "") }
        // Inside the write, on the newest book. A refusal there means the job
        // moved underneath the phone; the page the customer sees is still the
        // one the probe decided, as on the Node server.
        do { _ = try await host.approve(id, nowIso) } catch {
            return .json(500, #"{"error":"The shop could not record your approval right now. Please try again shortly."}"#)
        }
        var project = id
        if case .object(let approved)? = probe.order, let p = Shop.plainString(approved["project"]), !p.isEmpty { project = p }
        let page = (try? await engine.lanQuoteNotice("approved", project: project)) ?? ""
        return .html(200, page)
    }

    // MARK: - The customer's order page

    /// `/order/<id>`, `/order/<id>/status`, with or without a trailing slash —
    /// the id as the Node route keeps it. Not `/quote` or `/approve`.
    nonisolated static func trackingPath(_ path: String) -> String? {
        guard path.hasPrefix("/order/") else { return nil }
        var raw = String(path.dropFirst("/order/".count))
        if raw.hasSuffix("/") { raw.removeLast() }
        if raw.hasSuffix("/status") { raw = String(raw.dropLast("/status".count)) }
        guard !raw.isEmpty, !raw.contains("/") else { return nil }
        return raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// `GET /order/:id`: a quote is sent to its quote page; anything else is
    /// the tracking page behind the order's tracking token.
    private func trackingPage(_ request: Request, id: String, store: JSONValue) async -> Response {
        let engine = host.engine
        let html: (Int, String) -> Response = { status, body in
            .html(status, body, extra: ["Cache-Control": "no-cache"])
        }
        guard case .object(let order)? = order(id) else {
            return html(404, (try? await engine.lanOrderNotice("order_not_found")) ?? "")
        }
        if Shop.plainString(order["status"]) == "quote" {
            return Response(status: 302, headers: ["Location": "/order/\(id)/quote", "Cache-Control": "no-cache"])
        }
        let token = (request.query["token"] ?? "").trimmingCharacters(in: .whitespaces)
        guard case .string(let expected)? = order["trackingToken"], !expected.isEmpty, !token.isEmpty,
              Self.constantTimeEqual(token, expected) else {
            return html(403, (try? await engine.lanOrderNotice("invalid_tracking_link")) ?? "")
        }
        let page = (try? await engine.lanTrackingPage(order: .object(order), store: store)) ?? ""
        return html(200, page)
    }

    /// `POST /api/survey`: the one public write without a PIN, so it is
    /// rate-limited per address and finds its order by token alone.
    private func surveySubmit(_ request: Request) async -> Response {
        let engine = host.engine
        let now = host.now()
        let limit = (try? await engine.lanSurveyLimit()) ?? 30
        let step = try? await engine.lanIntakeRate(surveys[request.remote], now: now, limit: limit)
        if let step { surveys[request.remote] = step.rec; sweep(&surveys, now: now) }
        guard step?.allowed != false else {
            return .open(429, #"{"error":"Too many attempts — try again later"}"#)
        }
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: request.body), case .object = body else {
            return .open(400, #"{"error":"Invalid request"}"#)
        }
        guard let check = try? await engine.lanSurveyCheck(body: body) else {
            return .open(400, #"{"error":"Invalid request"}"#)
        }
        guard check.ok, let token = check.token, let rating = check.rating else {
            let error = check.error ?? "Invalid payload"
            let escaped = (try? String(decoding: JSONEncoder().encode(error), as: UTF8.self)) ?? "\"Invalid payload\""
            return .open(Int(check.status ?? 400), "{\"error\":\(escaped)}")
        }
        do {
            let written = try await host.survey(token, rating, check.comment, Self.isoNow(now))
            guard written else { return .open(404, #"{"error":"Invalid or expired survey token"}"#) }
        } catch {
            return .open(400, #"{"error":"The shop could not record your feedback right now. Please try again shortly."}"#)
        }
        return .open(200, #"{"ok":true}"#)
    }

    // MARK: - Pricing a model the customer uploaded

    /// `POST /api/intake/estimate` — a stranger's file, in, and a number out.
    ///
    /// The order of the refusals is the Node route's, and the order matters:
    /// the off switch is answered BEFORE a single byte is read, because
    /// accepting 32 MB and then saying no turns an off switch into an upload
    /// target.
    private func estimate(_ request: Request, store: JSONValue) async -> Response {
        let engine = host.engine
        let now = host.now()
        let limits = try? await engine.lanIntakeLimits()
        guard hasSession(request, now: now, sessionMs: limits?.SESSION_MS ?? 14_400_000) || hasIntakeToken(request) else {
            return .open(401, #"{"error":"Unauthorized"}"#)
        }
        // The shop's own ceiling on estimates per visitor per hour.
        var perHour = 12
        if case .object(let settings)? = host.store()["settings"],
           case .object(let lan)? = settings["lanApi"], case .object(let cfg)? = lan["intakeQuote"],
           let typed = Shop.plainNumber(cfg["hourlyLimit"]), typed >= 1 {
            perHour = min(10_000, Int(typed))
        }
        let step = try? await engine.lanIntakeRate(estimates[request.remote], now: now, limit: perHour)
        if let step { estimates[request.remote] = step.rec; sweep(&estimates, now: now) }
        guard step?.allowed != false else {
            return .open(429, #"{"error":"Too many estimates — try again later"}"#)
        }
        guard Self.quotingIsOn(host.store()) else {
            return .open(403, #"{"ok":false,"reason":"off"}"#)
        }
        // The name is only ever used to pick a reader — never to open, write or
        // serve anything — so its extension is all that is kept.
        let ext = Self.uploadExtension(request.query["name"] ?? "")
        guard Self.readableUploads.contains(ext) else {
            return .open(400, #"{"ok":false,"reason":"unsupported"}"#)
        }
        guard request.body.count <= Self.maxUpload else {
            return .open(413, #"{"ok":false,"reason":"too-large"}"#)
        }
        guard !request.body.isEmpty else {
            return .open(400, #"{"ok":false,"reason":"no-numbers"}"#)
        }
        guard measuring < Self.maxMeasuring else {
            return .open(503, #"{"ok":false,"reason":"busy"}"#)
        }
        // ── LOOKED AT BEFORE IT IS USED ───────────────────────────────────
        //
        // The file is about to be measured, and where the shop has turned
        // slicing on it will be written down and handed to a native binary.
        // So it is inspected first: is it the kind of file its name claims,
        // does an archive name members outside where it would be opened, does
        // it expand out of all proportion. The judgement is the shared rule's.
        //
        // What this does NOT promise is stated where the shop reads it: a
        // parser bug in somebody else's C++ is not something a structural
        // check can see.
        let facts = Self.uploadFacts(request.body, ext: ext)
        if let verdict = try? await engine.scanUpload(ext: ext, size: request.body.count,
                                                      header: facts.header, entries: facts.entries),
           !verdict.ok {
            let reason = verdict.reason ?? "refused"
            let escaped = (try? String(decoding: JSONEncoder().encode(reason), as: UTF8.self)) ?? "\"refused\""
            return .open(400, "{\"ok\":false,\"reason\":\(escaped)}")
        }
        measuring += 1
        defer { measuring -= 1 }

        // What the file says it is: a sliced file is taken at the slicer's own
        // figures, a mesh is measured here.
        let intake: JSONValue?
        if ext == "gcode" || ext == "gco" {
            intake = try? await engine.gcodeIntake(text: String(decoding: request.body, as: UTF8.self))
        } else if let sliced = await host.sliceUpload(request.body, ext) {
            // THE SLICER'S OWN FIGURES, where the shop has asked for them.
            // Geometry cannot know about purge — on the shop's four-colour
            // dragon the slicer said 57 g where the shape said 13 — so when
            // there is a real answer to be had, it wins.
            intake = sliced
        } else {
            intake = try? host.measure(request.body, ext)
        }
        guard let intake else {
            return .open(400, #"{"ok":false,"reason":"no-numbers"}"#)
        }
        let qty = max(1, min(1000, Int(request.query["qty"] ?? "1") ?? 1))
        guard let quote = try? await engine.publicQuote(intake: intake, store: store, qty: qty),
              case .object(let q) = quote else {
            return .open(500, #"{"ok":false,"reason":"no-price"}"#)
        }
        guard q["ok"] == .bool(true) else {
            let reason = Shop.plainString(q["reason"]) ?? "no-price"
            let escaped = (try? String(decoding: JSONEncoder().encode(reason), as: UTF8.self)) ?? "\"no-price\""
            return .open(200, "{\"ok\":false,\"reason\":\(escaped)}")
        }
        // A reference, not just a number: when the form is submitted the entry
        // is attached to what THIS server said, never to what a browser posts.
        let ref = Self.randomToken(bytes: 12)
        sweepQuotes(now: now)
        quoted[ref] = (quote: quote, at: now, ip: request.remote)
        var answer: [String: JSONValue] = ["ok": .bool(true), "ref": .string(ref), "binding": .bool(false)]
        for key in ["price", "currency", "qty", "grams", "hours", "exact", "slicer", "reliable"] {
            if let value = q[key] { answer[key] = value }
        }
        let body = (try? String(decoding: JSONEncoder().encode(JSONValue.object(answer)), as: UTF8.self)) ?? "{}"
        return .open(200, body)
    }

    /// The figure this server quoted, for a reference the same visitor holds.
    /// Nil for a reference that has expired, was never issued, or belongs to
    /// somebody else — in every case the request is simply taken unpriced.
    func recallQuote(_ ref: String?, ip: String, now: Date) -> JSONValue? {
        guard let ref, !ref.isEmpty, let held = quoted[ref] else { return nil }
        guard now.timeIntervalSince(held.at) <= Self.quoteTTL, held.ip == ip else { return nil }
        return held.quote
    }

    private func sweepQuotes(now: Date) {
        quoted = quoted.filter { now.timeIntervalSince($0.value.at) <= Self.quoteTTL }
    }

    nonisolated static func quotingIsOn(_ store: [String: JSONValue]) -> Bool {
        guard case .object(let settings)? = store["settings"],
              case .object(let lan)? = settings["lanApi"],
              case .object(let cfg)? = lan["intakeQuote"] else { return false }
        return cfg["enabled"] == .bool(true)
    }

    /// The readers this app has. G-code is read as text; the three mesh
    /// formats are measured by `Mesh`.
    nonisolated static let readableUploads: Set<String> = ["stl", "obj", "3mf", "gcode", "gco"]

    nonisolated static func uploadExtension(_ name: String) -> String {
        let tail = name.split(separator: ".").last.map(String.init) ?? ""
        return tail.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// What a stranger's file looks like from the outside, for the scan.
    ///
    /// The opening bytes and — for an archive — its member list, read from the
    /// central directory without unpacking anything. Nothing here decides;
    /// `lib/upload-scan.js` does, on these facts.
    nonisolated static func uploadFacts(_ data: Data, ext: String) -> (header: String, entries: [JSONValue]?) {
        let header = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        guard ext == "3mf" else { return (header, nil) }
        // A zip is read from a file, so this is the one point the bytes touch
        // disk before they have been cleared — in a directory of our own, and
        // removed on the way out whatever happens.
        guard let scratch = try? SlicerRun.scratch() else { return (header, []) }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "upload.3mf")
        guard (try? data.write(to: file, options: .atomic)) != nil,
              let entries = try? Zip.entries(of: file) else { return (header, []) }
        return (header, entries.map {
            .object(["name": .string($0.name),
                     "size": .number(Double($0.size)),
                     "compressedSize": .number(Double($0.compressedSize))])
        })
    }

    /// Measure an uploaded mesh, in the shape `publicQuote` reads.
    ///
    /// Written to a scratch file because every reader here takes a URL — a
    /// 3MF is a zip and is read by seeking, not streaming — and deleted on the
    /// way out whatever happens. `areaMm2` comes from the same walk that
    /// produces the risk analysis, and only under the risk cap: without it the
    /// estimator falls back to its constant, which it says it supports.
    nonisolated static func measureUpload(_ data: Data, ext: String) throws -> JSONValue? {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "khayt-intake-\(UUID().uuidString).\(ext)")
        try data.write(to: scratch, options: .atomic)
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let measured = try Mesh.readGeometry(scratch, ext: ext), measured.volumeMm3 > 0 else { return nil }
        var geometry: [String: JSONValue] = [
            "volumeMm3": .number(measured.volumeMm3),
            "triangleCount": .number(Double(measured.triangleCount)),
            "bbox": .object(["x": .number(measured.x), "y": .number(measured.y), "z": .number(measured.z)]),
        ]
        if data.count <= maxRiskBytes,
           let walked = try? Mesh.overhangs(of: scratch),
           case .number(let area)? = walked["totalAreaMm2"], area > 0 {
            geometry["areaMm2"] = .number(area)
        }
        return .object(["source": .string("geometry"), "exact": .bool(false),
                        "geometry": .object(geometry)])
    }

    // MARK: - The calendar

    /// `GET /calendar.ics`: the shop's due dates, for the calendar token or the
    /// owner PIN — a plain compare with no lockout, as the Node route has it,
    /// because a calendar app polls this on a schedule of its own.
    private func calendar(_ request: Request, store: JSONValue) async -> Response {
        let token = (request.query["token"] ?? "").trimmingCharacters(in: .whitespaces)
        let pin = (request.query["pin"] ?? request.headers["x-khayt-pin"] ?? "").trimmingCharacters(in: .whitespaces)
        let byToken = !host.calendarToken.isEmpty && !token.isEmpty && Self.constantTimeEqual(token, host.calendarToken)
        let byPin = !host.pin.isEmpty && !pin.isEmpty && Self.constantTimeEqual(pin, host.pin)
        guard byToken || byPin else {
            return Response(status: 401, headers: ["Content-Type": "text/plain; charset=utf-8"],
                            body: Data("Unauthorized — use the calendar subscription link from Khayt Settings → Online.".utf8))
        }
        let ics = (try? await host.engine.lanCalendarFeed(store: store)) ?? ""
        return Response(status: 200,
                        headers: ["Content-Type": "text/calendar; charset=utf-8",
                                  "Content-Disposition": "attachment; filename=\"khayt-orders.ics\"",
                                  "Cache-Control": "no-cache"],
                        body: Data(ics.utf8))
    }

    // MARK: - The PIN

    /// Nil when the caller may pass; the refusal to send otherwise. The same
    /// answers, in the same order, as the Node server's `checkPinForGet`.
    private func pinGate(_ request: Request) async -> Response? {
        guard !host.pin.isEmpty else {
            return .json(401, #"{"error":"Configure a LAN PIN in Khayt settings to access this data"}"#)
        }
        let provided = (request.query["pin"] ?? request.headers["x-khayt-pin"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        let now = host.now()
        let record = failures[request.remote]
        if (try? await host.engine.lanIsLockedOut(record, now: now)) == true {
            return .json(429, #"{"error":"Too many attempts — try again in 1 minute"}"#)
        }
        guard Self.constantTimeEqual(provided, host.pin) else {
            if let bumped = try? await host.engine.lanBumpFailure(record, now: now) {
                failures[request.remote] = bumped
            }
            sweepFailures(now: now)
            return .json(401, #"{"error":"Unauthorized"}"#)
        }
        failures.removeValue(forKey: request.remote)
        return nil
    }

    /// The map of failed addresses cannot grow without bound — an attacker
    /// with many addresses would otherwise fill memory one wrong PIN at a
    /// time. Expired records go first; the cap is the Node server's.
    private func sweepFailures(now: Date) {
        guard failures.count > Self.maxFailureKeys else { return }
        let ms = now.timeIntervalSince1970 * 1000
        failures = failures.filter { $0.value.resetAt > ms }
        while failures.count > Self.maxFailureKeys, let any = failures.keys.first {
            failures.removeValue(forKey: any)
        }
    }

    /// Constant-time, in Swift, on the platform's own primitive shape: every
    /// byte is compared whatever the first mismatch, and a length difference
    /// is folded in rather than returned early.
    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            diff |= Int(l ^ r)
        }
        return diff == 0
    }

    // MARK: - Small things

    /// `YYYY-MM-DD` in this Mac's own day, as the Node server's `localDay`.
    nonisolated static func localDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The time as the queue page prints it — the Node server's
    /// `toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })`.
    nonisolated static func clockText(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    nonisolated static func bundledIcon(_ name: String) -> Data? {
        let base = name.replacingOccurrences(of: ".png", with: "")
        guard let url = AppResources.bundle.url(forResource: base, withExtension: "png") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// A one-pixel PNG, for a build with no icon — the Node server's fallback.
    static let onePixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    /// The address a phone should be told: Wi‑Fi/LAN IPv4 (192.168.x, 10.x,
    /// 172.16–31.x) over anything else, loopback never — the Node server's
    /// `pickLanIPv4`, on getifaddrs.
    nonisolated static func lanIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(entry.pointee.ifa_flags) & IFF_UP) != 0,
                  (Int32(entry.pointee.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((String(cString: entry.pointee.ifa_name), String(cString: buffer)))
        }
        let ranked = candidates.sorted { a, b in Self.rank(a) < Self.rank(b) }
        return ranked.first?.address
    }

    nonisolated private static func rank(_ c: (name: String, address: String)) -> Int {
        var score = 10
        if c.address.hasPrefix("192.168.") { score = 0 }
        else if c.address.hasPrefix("10.") { score = 1 }
        else if c.address.hasPrefix("172.") { score = 2 }
        if c.name.hasPrefix("en") { score -= 5 }   // Wi‑Fi and Ethernet before VPNs and bridges
        return score
    }
}

/// A flag that is true for exactly one caller, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - The shop's side

/// What the server was started with. Equatable so a save that changed none of
/// it leaves the server running rather than dropping every phone's connection.
struct LanConfig: Equatable, Sendable {
    var enabled: Bool
    var port: UInt16
    var bindLan: Bool
    /// The PIN as STORED — sealed — not opened. Comparing sealed strings is
    /// enough to know whether it changed, and keeps the opened PIN out of one
    /// more place.
    var pin: String
}

extension Shop {
    /// The LAN block of the settings, read the way the Electron page reads it.
    var lanConfig: LanConfig {
        let lan = SettingsReader(settings: SettingsReader(settings: settingsDict).object("lanApi"))
        let raw = lan.number("port", 3219)
        let port = (raw >= 1 && raw <= 65535) ? UInt16(raw) : 3219
        return LanConfig(enabled: lan.flag("enabled"), port: port, bindLan: lan.flag("bindLan"), pin: lan.text("pin"))
    }

    /// The address a phone is told, while the server is up.
    var lanURL: String? {
        guard let server = lanServer, server.running, let running = lanRunning else { return nil }
        let host = running.bindLan ? (LanServer.lanIPv4() ?? "127.0.0.1") : "127.0.0.1"
        return "http://\(host):\(server.port)/"
    }

    /// Make the running server match the book: start it, stop it, or restart
    /// it when the port or the PIN changed. Called from every `load`, which is
    /// also every save.
    ///
    /// Only a real book autostarts. The sample is opened by every test in the
    /// suite, in parallel, and a listener per test on one port is a suite that
    /// fails on whichever test came second.
    func syncLanServer() async {
        guard source.build != nil else { return }
        let wanted = lanConfig
        guard wanted.enabled else { stopLanServer(); return }
        if let running = lanRunning, running == wanted, lanServer?.running == true { return }
        await startLanServer()
    }

    func startLanServer() async {
        stopLanServer()
        lanProblem = nil
        guard let engine else { lanProblem = words.callIt("mac.move_no_engine"); return }
        let config = lanConfig
        // Sealed on disk by whichever app wrote it; opened here, once, and
        // handed to the server — never read back out of the book per request.
        let pin = (try? await Secrets.open(config.pin, for: source)) ?? ""
        let lan = SettingsReader(settings: SettingsReader(settings: settingsDict).object("lanApi"))
        let intakeToken = (try? await Secrets.open(lan.text("intakeToken"), for: source)) ?? ""
        let calendarToken = await ensureCalendarToken()
        var host = LanServer.Host(store: { [weak self] in self?.lanBook ?? [:] }, pin: pin, engine: engine)
        host.intakeToken = intakeToken
        host.calendarToken = calendarToken
        host.record = { [weak self] entry in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            try await self.recordIntake(entry)
        }
        host.approve = { [weak self] id, nowIso in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            return try await self.approveQuote(id, nowIso: nowIso)
        }
        host.sliceUpload = { [weak self] data, ext in
            guard let self else { return nil }
            return await self.sliceCustomerUpload(data, ext: ext)
        }
        host.survey = { [weak self] token, rating, comment, nowIso in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            return try await self.recordSurvey(token: token, rating: rating, comment: comment, nowIso: nowIso)
        }
        let server = LanServer(host: host)
        do {
            _ = try await server.start(port: config.port, bind: config.bindLan ? .lan : .loopback)
            lanServer = server
            lanRunning = config
            lanCalendarToken = calendarToken
        } catch {
            lanProblem = words.callIt("mac.lan_failed", ["error": .string(String(describing: error))])
        }
    }

    /// A customer's request, into the book's waiting list — the entry the
    /// shared rule built, appended inside the write, then the window reloads
    /// from the file so the request is on the Waiting screen at once.
    func recordIntake(_ entry: JSONValue) async throws {
        guard let build = source.build else { throw CocoaError(.fileWriteNoPermission) }
        try await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
        ) { root in
            var list: [JSONValue] = []
            if case .array(let had)? = root["waitingList"] { list = had }
            list.append(entry)
            root["waitingList"] = .array(list)
        }
        await load(source)
    }

    /// The link a customer approves a quote from: this Mac's address, the job,
    /// and the job's own approval token — minted now if the job has none, the
    /// way the Electron renderer's `ensureQuoteApprovalToken` mints it — and
    /// written into the book so the server recognises it. Nil while the
    /// server is off: a link nobody can open is worse than none.
    func quoteLink(for jobId: String) async -> String? {
        guard let base = lanURL, let build = source.build else { return nil }
        var token = ""
        do {
            try StoreWriter.updateRecord(build, collection: "printLog", id: jobId) { record in
                if case .string(let had)? = record["quoteApprovalToken"], !had.isEmpty {
                    token = had
                } else {
                    token = LanServer.randomToken(bytes: 16)
                    record["quoteApprovalToken"] = .string(token)
                }
            }
        } catch { return nil }
        await load(source)
        let id = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        let tok = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return "\(base)order/\(id)/quote?token=\(tok)"
    }

    /// Approve a quote from the customer's page: the shared rule applied
    /// inside the write, on the newest book, so a job that moved underneath
    /// the phone is left alone. Returns the approved record, or nil when the
    /// rule refused on the book as it is now.
    func approveQuote(_ jobId: String, nowIso: String) async throws -> JSONValue? {
        guard let build = source.build, let engine else { throw CocoaError(.fileWriteNoPermission) }
        var approved: JSONValue?
        try await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
        ) { root in
            let result = try await engine.lanQuoteApply(store: .object(root), orderId: jobId, nowIso: nowIso)
            guard result.found, result.error == nil, let printLog = result.printLog else { return }
            root["printLog"] = printLog
            approved = result.order
        }
        await load(source)
        return approved
    }

    /// Price a customer's cleared upload by slicing it.
    ///
    /// Everything here is conditional on the shop having said so: the switch
    /// is off in a fresh book, and without it this returns nil and the caller
    /// estimates from the shape exactly as before. The slicer is the one the
    /// shop chose for this, else its default.
    ///
    /// The bytes go to a scratch directory and the whole directory is removed
    /// on the way out, whatever happened — a stranger's model is not something
    /// to leave lying on a shop's disk.
    func sliceCustomerUpload(_ data: Data, ext: String) async -> JSONValue? {
        let lan = SettingsReader(settings: SettingsReader(settings: settingsDict).object("lanApi"))
        let quote = SettingsReader(settings: lan.object("intakeQuote"))
        guard quote.flag("sliceUploads"), let engine else { return nil }

        // The one the shop chose for this, else its default. A chosen slicer
        // that has since been removed falls back rather than failing: the
        // customer gets the estimate, not an error about the shop's settings.
        let chosen = quote.text("sliceWithId")
        var slicer = chosen.isEmpty ? nil : slicers.first { $0.id == chosen }
        if slicer == nil { slicer = try? await engine.defaultSlicer(settings: settingsDict) }
        guard let slicer, (try? await engine.mayLaunchAsSlicer(path: slicer.path)) == true else { return nil }

        guard let dir = try? SlicerRun.scratch() else { return nil }
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appending(path: "upload.\(ext)")
        let output = dir.appending(path: "out.gcode")
        guard (try? data.write(to: model, options: .atomic)) != nil else { return nil }
        guard let argv = try? await engine.sliceArgv(template: slicer.args, model: model.path,
                                                     output: output.path, outdir: dir.path) else { return nil }
        guard (try? SlicerRun.slice(model, with: slicer, argv: argv, allowed: true)) != nil,
              let gcode = SlicerRun.gcode(in: dir, expected: output),
              let text = try? SlicerRun.totalsText(of: gcode) else { return nil }
        return try? await engine.gcodeIntake(text: text)
    }

    /// The link a customer follows their order from: this Mac's address, the
    /// job, and the job's own tracking token — minted into the job the first
    /// time, as the Electron renderer's `ensureTrackingToken` mints it.
    func trackingLink(for jobId: String) async -> String? {
        guard let base = lanURL, let build = source.build else { return nil }
        var token = ""
        do {
            try StoreWriter.updateRecord(build, collection: "printLog", id: jobId) { record in
                if case .string(let had)? = record["trackingToken"], !had.isEmpty {
                    token = had
                } else {
                    token = LanServer.randomToken(bytes: 16)
                    record["trackingToken"] = .string(token)
                }
            }
        } catch { return nil }
        await load(source)
        let id = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        let tok = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return "\(base)order/\(id)?token=\(tok)"
    }

    /// A customer's survey, onto the order that holds the token — found inside
    /// the write, by constant-time compare, so a token spent by a concurrent
    /// submit is not spent twice. False when no order holds it.
    func recordSurvey(token: String, rating: Double, comment: String?, nowIso: String) async throws -> Bool {
        guard let build = source.build, let engine else { throw CocoaError(.fileWriteNoPermission) }
        var written = false
        try await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
        ) { root in
            guard case .array(var log)? = root["printLog"] else { return }
            for i in log.indices {
                guard case .object(let order) = log[i], case .string(let held)? = order["surveyToken"],
                      !held.isEmpty, LanServer.constantTimeEqual(token, held) else { continue }
                log[i] = try await engine.lanSurveyPatch(order: .object(order), rating: rating, comment: comment, nowIso: nowIso)
                written = true
                break
            }
            if written { root["printLog"] = .array(log) }
        }
        if written { await load(source) }
        return written
    }

    /// The calendar token, opened — minted and sealed into the book the first
    /// time the server starts, as the Electron main process's
    /// `ensureLanCalendarToken` does. Plumbing with a Keychain in it, not a
    /// rule; the feed itself is the shared module's.
    func ensureCalendarToken() async -> String {
        let lan = SettingsReader(settings: SettingsReader(settings: settingsDict).object("lanApi"))
        let stored = lan.text("calendarToken")
        if !stored.isEmpty { return (try? await Secrets.open(stored, for: source)) ?? "" }
        guard let build = source.build else { return "" }
        let minted = LanServer.randomToken(bytes: 16)
        guard let sealed = try? await Secrets.seal(minted, for: build) else { return "" }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings: [String: JSONValue] = [:]
                if case .object(let s)? = root["settings"] { settings = s }
                var lanApi: [String: JSONValue] = [:]
                if case .object(let l)? = settings["lanApi"] { lanApi = l }
                // Another writer may have minted one first; keep theirs.
                if case .string(let had)? = lanApi["calendarToken"], !had.isEmpty { return }
                lanApi["calendarToken"] = .string(sealed)
                settings["lanApi"] = .object(lanApi)
                root["settings"] = .object(settings)
            }
        } catch { return "" }
        return minted
    }

    /// The link a calendar app subscribes to, while the server is up.
    var calendarLink: String? {
        guard let base = lanURL, let token = lanCalendarToken, !token.isEmpty else { return nil }
        return "\(base)calendar.ics?token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
    }

    func stopLanServer() {
        lanServer?.stop()
        lanServer = nil
        lanRunning = nil
    }

    /// Save the Online pane. A typed PIN is sealed for the book before it goes
    /// in, the way a printer key is; a blank one keeps the stored PIN, which
    /// is the rule's own reading of a blank.
    func saveLanSettings(enabled: Bool, port: Int, pin typed: String, bindLan: Bool,
                         intakeQuote: [String: JSONValue]? = nil) async {
        var lan: [String: JSONValue] = ["enabled": .bool(enabled), "port": .number(Double(port)),
                                        "bindLan": .bool(bindLan)]
        // Kept whole rather than spread, as the other app's page keeps it, so
        // an older book without the key simply arrives as "off".
        if let intakeQuote { lan["intakeQuote"] = .object(intakeQuote) }
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let build = source.build {
            do { lan["pin"] = .string(try await Secrets.seal(trimmed, for: build)) }
            catch { settingsProblem = String(describing: error); return }
        }
        await saveSettings(["lanApi": .object(lan)])
    }
}
