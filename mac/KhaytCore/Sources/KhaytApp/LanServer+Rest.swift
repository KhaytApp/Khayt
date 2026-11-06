import Foundation
import KhaytCore

/// The LAN REST API on this Mac: `/api/orders`, `/api/clients`,
/// `/api/inventory`, `/api/waste`, `/api/waiting-list`, `/api/machines` and
/// the printer webhook — the routes `lib/lan-server.js` serves the Windows
/// and Linux app's phones and scripts, which this server answered 404.
///
/// ── THE RULES ARE NOT HERE ────────────────────────────────────────────────
///
/// What each route reads and writes is `lib/lan-rest.js`, run in
/// JavaScriptCore — the same function the Node server calls — so a record a
/// script makes here is the record it would have made there, field for field.
/// This file is the plumbing: the gate, the body, and the write.
///
/// ── THE GATE IS THE NODE SERVER'S ─────────────────────────────────────────
///
/// Every route is behind the owner PIN (`pinGate`: the header only, the host
/// check, the lockouts) OR a scoped API token (`apiTokenGate`): a token
/// stands in for the PIN only where the route is in the scope model and the
/// token holds the scope it needs (`lib/api-token-scopes.js requiredScope`). A
/// wrong token is 401 and counted in its own bucket, ten to a lockout; a
/// token without the scope is 403 and the route never runs. `/api/waste` is
/// in no scope, so only the PIN opens it — as on the desktop. The printer
/// webhook has its own token, compared in constant time, its own lockout
/// channel, and nothing else.
///
/// ── THE WRITE IS THE BOOK'S ───────────────────────────────────────────────
///
/// A write is decided twice: once on the book the server holds, so a refusal
/// costs no write, and again INSIDE the write (`Shop.lanRestWrite` through
/// `StoreWriter.update`) on the book as it is then, and that answer is sent.
/// Bodies are capped at `maxBody` (413 before the route runs) and nested at
/// most `maxBodyDepth`.
extension LanServer {

    /// Routes the Node server answers without the PIN or a token — where a
    /// bearer means nothing and is not judged (`isAlwaysPublic` there).
    nonisolated static func isAlwaysPublic(path: String, method: String) -> Bool {
        if path == "/api/status" || path == "/manifest.json" || path == "/sw.js" { return true }
        if path == "/icon-192.png" || path == "/icon-512.png" || path == "/icon-maskable-512.png" { return true }
        if path == "/api/proof" && method == "GET" { return true }
        if path.hasPrefix("/order/") && (method == "GET" || method == "HEAD" || method == "POST") { return true }
        if path.hasPrefix(storefrontHookPath) { return true }
        return false
    }

    /// The `/v1` form of a path, which the scope rule reads — the Node
    /// server's `pathname.replace('/api', '/v1')`.
    nonisolated static func v1Path(_ path: String) -> String {
        path.hasPrefix("/api") ? "/v1" + path.dropFirst(4) : path
    }

    /// Judge a presented API token. Nil lets the request on (with
    /// `tokenScoped` set when the token holds this route's scope); otherwise
    /// the refusal: 429 locked out, 401 unknown or revoked, 403 not this scope.
    func apiTokenGate(_ request: inout Request, bearer: String, path: String) async -> Response? {
        await lockCounters()
        defer { unlockCounters() }
        let now = Date(timeIntervalSince1970: host.lockoutClock())
        let key = Self.throttleKey(request.remote) + ":apitok"
        let record = tokenFailures[key]
        if (try? await host.engine.lanIsLockedOut(record, now: now)) == true {
            return .open(429, #"{"error":"Too many attempts — try again in 1 minute"}"#)
        }
        var settings: [String: JSONValue]?
        if case .object(let s)? = host.store()["settings"] { settings = s }
        guard let token = ApiTokens.verify(bearer, against: ApiTokens.records(in: settings)) else {
            if let bumped = try? await host.engine.lanBumpFailure(record, now: now) { tokenFailures[key] = bumped }
            sweep(&tokenFailures, now: now)
            return .open(401, #"{"error":"invalid_token"}"#)
        }
        let asked = try? await host.engine.apiTokenScope(path: Self.v1Path(path), method: request.method)
        guard let need = asked ?? nil else { return nil }
        guard ApiTokens.hasScope(token, need) else {
            let body = (try? JSONEncoder().encode(["error": "insufficient_scope", "required": need])) ?? Data()
            return Response(status: 403, headers: ["Content-Type": "application/json", "Access-Control-Allow-Origin": "*"],
                            body: body)
        }
        request.tokenScoped = true
        return nil
    }

    /// The id after `prefix` and what follows it: `/api/orders/A1/approve` →
    /// (`A1`, `approve`). The path is already percent-decoded.
    nonisolated static func restSegment(_ path: String, under prefix: String) -> (id: String, rest: String)? {
        guard path.hasPrefix(prefix) else { return nil }
        let tail = path.dropFirst(prefix.count)
        let parts = tail.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        return (String(first), parts.count > 1 ? String(parts[1]) : "")
    }

    /// The REST route this request is for, answered; nil when it is not one.
    func restRoute(_ request: Request, path: String, isGet: Bool) async -> Response? {
        let m = request.method
        switch path {
        case "/api/orders" where isGet:
            let q: JSONValue = .object(["limit": request.query["limit"].map { .string($0) } ?? .null,
                                        "status": request.query["status"].map { .string($0) } ?? .null])
            return await restRead(request, "ordersList", [q])
        case "/api/orders" where m == "POST":
            return await restWrite(request, "orderCreate") { [$0, self.restContext()] }
        case "/api/machines" where isGet:
            return await restRead(request, "machinesList", [])
        case "/api/inventory" where isGet:
            return await restRead(request, "inventoryList", [])
        case "/api/inventory" where m == "POST":
            return await restWrite(request, "inventoryCreate") { [$0, self.restContext()] }
        case "/api/waiting-list" where isGet:
            return await restRead(request, "waitingList", [])
        case "/api/clients" where isGet:
            return await restRead(request, "clientsList", [])
        case "/api/waste" where m == "POST":
            // Not JSON, or empty, is the rule's own "Invalid waste payload".
            return await restWrite(request, "wasteCreate", empty: .null) { [$0, self.restContext()] }
        default:
            break
        }
        if let (id, rest) = Self.restSegment(path, under: "/api/orders/") {
            if rest.isEmpty && m == "PATCH" {
                return await restWrite(request, "orderPatch") { [.string(id), $0] }
            }
            if rest == "quote-url" && isGet {
                let base = "http://" + (request.headers["host"] ?? "localhost")
                return await restRead(request, "orderQuoteUrl", [.string(id), .string(base), restContext()])
            }
            if rest == "approve" && m == "POST" {
                return await restWrite(request, "orderApprove") { _ in [.string(id), self.restContext()] }
            }
        }
        if let (id, rest) = Self.restSegment(path, under: "/api/inventory/"), rest.isEmpty {
            if m == "PATCH" { return await restWrite(request, "inventoryPatch") { [.string(id), $0, self.restContext()] } }
            if m == "DELETE" { return await restWrite(request, "inventoryDelete") { _ in [.string(id)] } }
        }
        if let (id, rest) = Self.restSegment(path, under: "/api/waiting-list/"), rest.isEmpty, m == "PATCH" {
            return await restWrite(request, "waitingListPatch") { [.string(id), $0, self.restContext()] }
        }
        if let (id, _) = Self.restSegment(path, under: "/api/webhook/printer/"), m == "POST" {
            return await printerHook(request, machineId: id)
        }
        return nil
    }

    /// The moment, the shop's day and two random bytes — built ONCE per
    /// request, so the record decided on the held book and the one written
    /// inside the write carry the same id.
    func restContext() -> JSONValue {
        let now = host.now()
        return .object([
            "nowMs": .number((now.timeIntervalSince1970 * 1000).rounded()),
            "nowIso": .string(StoreWriter.iso(now)),
            "today": .string(Self.localDay(now)),
            "rand": .string(host.randomHex()),
        ])
    }

    private var restBookNow: JSONValue { .object(host.restBook?() ?? host.store()) }

    private func restRead(_ request: Request, _ op: String, _ args: [JSONValue]) async -> Response {
        if let refused = await pinGate(request) { return refused }
        guard let out = try? await host.engine.lanRest(op, store: restBookNow, args: args) else {
            return .json(500, Self.errorBody("The book could not be read"))
        }
        return Self.restResponse(out)
    }

    /// A write route: the gate, the body, the rule on the held book, then the
    /// rule again inside the write. `args` builds the rule's arguments after
    /// the book from the parsed body. With no `restWrite` wired, the route is
    /// not here at all.
    private func restWrite(_ request: Request, _ op: String, empty: JSONValue = .object([:]),
                           args: (JSONValue) -> [JSONValue]) async -> Response? {
        guard let write = host.restWrite else { return nil }
        if let refused = await pinGate(request) { return refused }
        let body: JSONValue
        if request.body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            body = empty
        } else if let parsed = Self.body(request.body) {
            body = parsed
        } else {
            return .json(400, #"{"error":"Invalid JSON"}"#)
        }
        let built = args(body)
        return await commit(op, built, write: write)
    }

    /// Decide on the held book; only a change goes to the write.
    private func commit(_ op: String, _ args: [JSONValue],
                        write: (_ op: String, _ args: [JSONValue]) async throws -> KhaytEngine.LanRestOutcome) async -> Response {
        guard let probe = try? await host.engine.lanRest(op, store: restBookNow, args: args) else {
            return .json(500, Self.errorBody("The book could not be read"))
        }
        guard probe.changed != nil else { return Self.restResponse(probe) }
        do {
            return Self.restResponse(try await write(op, args))
        } catch {
            // OUR failure, not the caller's: the book could not be written.
            return .json(500, Self.errorBody("The book could not be written"))
        }
    }

    nonisolated static func restResponse(_ out: KhaytEngine.LanRestOutcome) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(out.body)) ?? Data("null".utf8)
        return Response(status: out.status, headers: ["Content-Type": "application/json"], body: data)
    }

    /// `POST /api/webhook/printer/:machineId` — a printer (or its plugin)
    /// saying a print started, finished or was cancelled. Its own token, sent
    /// as `x-khayt-webhook-token` and never in the address; its own lockout
    /// channel, so a misconfigured printer cannot lock the owner out.
    private func printerHook(_ request: Request, machineId: String) async -> Response {
        guard let write = host.restWrite else {
            return .json(404, (try? await host.engine.lanNotFoundBody(endpoints: Self.endpoints)) ?? #"{"error":"Not found"}"#)
        }
        let now = host.now()
        let key = Self.throttleKey(request.remote) + ":wh:printer"
        let record = webhookFailures[key]
        if (try? await host.engine.lanIsLockedOut(record, now: now)) == true {
            return .json(429, #"{"error":"Too many attempts — try again in 1 minute"}"#)
        }
        let provided = request.headers["x-khayt-webhook-token"] ?? ""
        guard !host.printerWebhookToken.isEmpty, Self.constantTimeEqual(provided, host.printerWebhookToken) else {
            if let bumped = try? await host.engine.lanBumpFailure(record, now: now) { webhookFailures[key] = bumped }
            sweepWebhookFailures(now: now)
            return .json(401, #"{"error":"Unauthorized — set webhook token in Khayt LAN settings"}"#)
        }
        let body: JSONValue
        if request.body.isEmpty { body = .object([:]) } else if let parsed = Self.body(request.body) { body = parsed } else {
            return .json(400, #"{"error":"Invalid JSON"}"#)
        }
        return await commit("printerEvent", [.string(machineId), body, restContext()], write: write)
    }
}

extension Shop {
    /// The collections the REST rules read and write: the phone's book plus
    /// the clients, the shelf, the waste log and the declined requests.
    nonisolated static let lanRestKeys = ["printLog", "waitingList", "waitingListHistory", "settings",
                                          "machines", "clients", "inventory", "wasteLog"]

    nonisolated static func lanRestBook(from root: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in lanRestKeys { out[key] = root[key] ?? (key == "settings" ? .object([:]) : .array([])) }
        return out
    }

    /// The mutation `lanRestWrite` runs inside the write — separate so a test
    /// runs exactly it on a real book. Only the collections the rule handed
    /// back are put into the book; everything else (the library, the logs) is
    /// the book's own, never round-tripped through JavaScript.
    nonisolated static func applyLanRest(into root: inout [String: JSONValue], engine: KhaytEngine,
                                         op: String, args: [JSONValue]) async throws -> KhaytEngine.LanRestOutcome {
        let out = try await engine.lanRest(op, store: .object(lanRestBook(from: root)), args: args)
        if let next = out.changed {
            for key in lanRestKeys { if let v = next[key] { root[key] = v } }
        }
        return out
    }

    /// A LAN REST write — a script, or a phone on the desktop's API — into
    /// the book, decided INSIDE the write on the book as it is then. The
    /// write chain tombstones what the rule removed (a declined request
    /// leaving `waitingList`, a deleted spool) and stamps what it changed, so
    /// both sync. Throws when the book cannot be written; answers the rule's
    /// refusal, without writing, when the book moved underneath.
    func lanRestWrite(_ op: String, args: [JSONValue]) async throws -> KhaytEngine.LanRestOutcome {
        guard let build = source.build, let engine else { throw CocoaError(.fileWriteNoPermission) }
        var outcome: KhaytEngine.LanRestOutcome?
        do {
            // lock: system — a LAN REST write; the LAN server gated it with the owner LAN PIN or a scoped API token.
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let out = try await Self.applyLanRest(into: &root, engine: engine, op: op, args: args)
                outcome = out
                // Refused on the book as it is now: nothing to write.
                if out.changed == nil { throw LanRestUnchanged() }
            }
        } catch is LanRestUnchanged {
            if let outcome { return outcome }
        }
        await load(source)
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        return outcome
    }
}

/// Thrown out of the write to leave the book untouched.
private struct LanRestUnchanged: Error {}
