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
    static let maxFailureKeys = 5000
    static let maxBody = 1_048_576

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
        do {
            guard let request = try await readRequest(connection, remote: remote) else { return }
            let response = await respond(to: request)
            try await write(response, method: request.method, to: connection)
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            try? await write(.open(413, #"{"error":"Request too large"}"#), method: "POST", to: connection)
        } catch {
            // A client that hung up mid-request, or a listener being stopped.
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
        // The estimate route is not served here, so the form never offers the
        // upload — a widget whose request would 404 is worse than no widget.
        let page = (try? await engine.lanIntakePage(store: store, quoteEnabled: false)) ?? ""
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
        guard let outcome = try? await engine.lanIntakeSubmission(body: body, shopName: shopName, id: host.mintId(),
                                                                  nowIso: Self.isoNow(now)) else {
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

    nonisolated static func randomToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
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
        var host = LanServer.Host(store: { [weak self] in self?.lanBook ?? [:] }, pin: pin, engine: engine)
        host.intakeToken = intakeToken
        host.record = { [weak self] entry in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            try await self.recordIntake(entry)
        }
        let server = LanServer(host: host)
        do {
            _ = try await server.start(port: config.port, bind: config.bindLan ? .lan : .loopback)
            lanServer = server
            lanRunning = config
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

    func stopLanServer() {
        lanServer?.stop()
        lanServer = nil
        lanRunning = nil
    }

    /// Save the Online pane. A typed PIN is sealed for the book before it goes
    /// in, the way a printer key is; a blank one keeps the stored PIN, which
    /// is the rule's own reading of a blank.
    func saveLanSettings(enabled: Bool, port: Int, pin typed: String, bindLan: Bool) async {
        var lan: [String: JSONValue] = ["enabled": .bool(enabled), "port": .number(Double(port)),
                                        "bindLan": .bool(bindLan)]
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let build = source.build {
            do { lan["pin"] = .string(try await Secrets.seal(trimmed, for: build)) }
            catch { settingsProblem = String(describing: error); return }
        }
        await saveSettings(["lanApi": .object(lan)])
    }
}
