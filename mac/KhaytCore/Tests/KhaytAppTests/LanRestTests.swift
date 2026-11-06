import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The LAN REST API on this Mac (`LanServer+Rest`), held to the Node server:
/// the same gate (owner PIN, or a scoped API token), the same bodies — built
/// by `lib/lan-rest.js` through the engine — and the same write rules.
@MainActor
struct LanRestTests {
    typealias Bench = LanServerTests.Bench
    static let pin = ["x-khayt-pin": "24682468"]

    /// A token minted the way the Settings section mints one, put in the book.
    static func withToken(_ bench: Bench, scopes: [String]) -> String {
        let minted = ApiTokens.mint(label: "Test", scopes: scopes, known: scopes, now: "2027-01-15T00:00:00.000Z")
        Shop.editApiTokens(&bench.book.value) { $0.append(.object(minted.record)) }
        return minted.token
    }
    static func bearer(_ token: String) -> [String: String] { ["Authorization": "Bearer " + token] }
    static func json(_ s: String) -> Data { Data(s.utf8) }
    static func rows(_ bench: Bench, _ key: String) -> [[String: JSONValue]] {
        guard case .array(let list)? = bench.book.value[key] else { return [] }
        return list.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    @Test("every REST route refuses a caller with no PIN and no token, and a wrong PIN")
    func unauthenticated() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        let before = bench.book.value
        let routes: [(String, String, String?)] = [
            ("GET", "/api/orders", nil), ("POST", "/api/orders", #"{"project":"X"}"#),
            ("PATCH", "/api/orders/any", #"{"status":"qc"}"#), ("GET", "/api/orders/any/quote-url", nil),
            ("POST", "/api/orders/any/approve", "{}"), ("GET", "/api/machines", nil),
            ("GET", "/api/inventory", nil), ("POST", "/api/inventory", #"{"material":"PLA"}"#),
            ("PATCH", "/api/inventory/s1", #"{"remaining":1}"#), ("DELETE", "/api/inventory/s1", nil),
            ("GET", "/api/waiting-list", nil), ("PATCH", "/api/waiting-list/w1", #"{"status":"declined"}"#),
            ("GET", "/api/clients", nil), ("POST", "/api/waste", #"{"material":"PLA"}"#),
            ("GET", "/v1/orders", nil),
        ]
        for (method, path, body) in routes {
            let none = try await bench.send(method, path, body: body.map(Self.json))
            #expect(none.status == 401, Comment(rawValue: "\(method) \(path) answered \(none.status) with no PIN"))
            let wrong = try await bench.send(method, path, body: body.map(Self.json), headers: ["x-khayt-pin": "00000000"])
            #expect(wrong.status == 401 || wrong.status == 429,
                    Comment(rawValue: "\(method) \(path) answered \(wrong.status) to a wrong PIN"))
            bench.advance(seconds: 120)   // past any lockout the wrong PINs earned
        }
        #expect(bench.book.value == before, "a refused request wrote nothing")
    }

    @Test("the reads are the shared rule's bodies, behind the PIN")
    func reads() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        for (path, op) in [("/api/orders", "ordersList"), ("/api/machines", "machinesList"),
                           ("/api/inventory", "inventoryList"), ("/api/waiting-list", "waitingList"),
                           ("/api/clients", "clientsList")] {
            let reply = try await bench.send("GET", path, headers: Self.pin)
            #expect(reply.status == 200, Comment(rawValue: path))
            let args: [JSONValue] = op == "ordersList" ? [.object(["limit": .null, "status": .null])] : []
            let expected = try await bench.engine.lanRest(op, store: .object(bench.book.value), args: args)
            let got = try JSONValue.decode(JSONValue.self, from: reply.body)
            #expect(got == expected.body, Comment(rawValue: "\(path) is not the rule's body"))
        }
    }

    @Test("a bad token is 401 and counted; ten lock the address out")
    func badToken() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        _ = Self.withToken(bench, scopes: ["orders:read"])
        let bad = try await bench.send("GET", "/api/orders", headers: Self.bearer("khayt_not-a-real-token"))
        #expect(bad.status == 401)
        #expect(bad.text == #"{"error":"invalid_token"}"#)
        for _ in 0..<10 { _ = try await bench.send("GET", "/api/orders", headers: Self.bearer("khayt_guess")) }
        let locked = try await bench.send("GET", "/api/orders", headers: Self.bearer("khayt_guess"))
        #expect(locked.status == 429)
        // Its own bucket: the owner's PIN still opens the queue from the same address.
        let owner = try await bench.send("GET", "/api/orders", headers: Self.pin)
        #expect(owner.status == 200)
    }

    @Test("a token opens only its scopes, and never a route outside the scope model")
    func scopes() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        let token = Self.withToken(bench, scopes: ["orders:read"])
        #expect(try await bench.send("GET", "/api/orders", headers: Self.bearer(token)).status == 200)
        #expect(try await bench.send("GET", "/v1/orders", headers: Self.bearer(token)).status == 200)
        #expect(try await bench.send("GET", "/api/queue", headers: Self.bearer(token)).status == 200)
        let write = try await bench.send("POST", "/api/orders", body: Self.json(#"{"project":"X"}"#), headers: Self.bearer(token))
        #expect(write.status == 403)
        #expect(write.text.contains("insufficient_scope") && write.text.contains("orders:write"))
        #expect(try await bench.send("GET", "/api/clients", headers: Self.bearer(token)).status == 403)
        // Outside the scope model the PIN still applies: a token is not a PIN.
        #expect(try await bench.send("GET", "/api/store", headers: Self.bearer(token)).status == 401)
        let writer = Self.withToken(bench, scopes: ["orders:write", "inventory:write"])
        let waste = try await bench.send("POST", "/api/waste", body: Self.json(#"{"material":"PLA"}"#), headers: Self.bearer(writer))
        #expect(waste.status == 401, "waste is in no scope, so only the PIN logs it")
        // Revoked: the record goes, and the very next request is refused.
        Shop.editApiTokens(&bench.book.value) { $0.removeAll() }
        #expect(try await bench.send("GET", "/api/orders", headers: Self.bearer(token)).status == 401)
    }

    @Test("a body over a megabyte is 413 and nothing is written")
    func oversize() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        let before = bench.book.value
        let port = bench.port
        // The head promises the body and none is sent: the refusal comes from
        // the head, before a byte is read (see `LanSecurityReviewTests`).
        for path in ["/api/orders", "/api/inventory", "/api/waste", "/api/webhook/printer/m1"] {
            let line = await offPool { LanSecurityReviewTests.headOnly(port: port, path: path, length: 2 << 20) }
            #expect(line.hasPrefix("HTTP/1.1 413"), Comment(rawValue: "\(path): \(line)"))
        }
        #expect(bench.book.value == before)
        let deep = Data((String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)).utf8)
        #expect(try await bench.send("POST", "/api/orders", body: deep, headers: Self.pin).status == 400)
        #expect(try await bench.send("POST", "/api/orders", body: Self.json("{nope"), headers: Self.pin).status == 400)
    }

    @Test("no secret leaves: printer keys, token hashes and tokens themselves")
    func secretsNeverLeak() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        let token = Self.withToken(bench, scopes: ["machines:read", "orders:read", "inventory:read", "clients:read"])
        let hash = ApiTokens.hash(token)
        var machines: [JSONValue] = []
        if case .array(let had)? = bench.book.value["machines"] { machines = had }
        machines.append(.object(["id": .string("m-secret"), "name": .string("Vault"),
                                 "printerApi": .object(["type": .string("octoprint"), "apiKey": .string("__enc__SEALED-KEY"),
                                                        "accessCode": .string("12345678")])]))
        bench.book.value["machines"] = .array(machines)
        for path in ["/api/machines", "/api/orders", "/api/inventory", "/api/clients", "/api/machines/live"] {
            let reply = try await bench.send("GET", path, headers: Self.bearer(token))
            #expect(reply.status == 200, Comment(rawValue: path))
            for secret in ["SEALED-KEY", "12345678", hash, token] {
                #expect(!reply.text.contains(secret), Comment(rawValue: "\(path) leaked a secret"))
            }
        }
        let store = try await bench.send("GET", "/api/store?scope=whole", headers: Self.pin)
        #expect(store.status == 200)
        #expect(!store.text.contains(hash), "a phone is handed a token's hash")
    }

    @Test("an order made, patched and approved is the rule's record, written into the book")
    func orders() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        let made = try await bench.send("POST", "/api/orders", body: Self.json(#"{"project":"Gear","price":12.345}"#),
                                        headers: Self.pin)
        #expect(made.status == 201)
        let first = try #require(Self.rows(bench, "printLog").first)
        #expect(first["project"] == .string("Gear"))
        #expect(first["price"] == .number(12.35))
        guard case .string(let id)? = first["id"] else { Issue.record("no id"); return }
        // Tagged from `tokens.id` (four 0x07 bytes → "7777"), as the desktop
        // tags it, and given a tracking link from `tokens.tracking`.
        #expect(id.hasSuffix("-7777"))
        #expect(first["trackingToken"] == .string(String(repeating: "07", count: 16)))
        #expect(first["quoteApprovalToken"] == nil, "a job is not a quote")
        let patched = try await bench.send("PATCH", "/api/orders/" + id, body: Self.json(#"{"status":"qc"}"#), headers: Self.pin)
        #expect(patched.status == 200)
        #expect(bench.book.job(id)?["status"] == .string("qc"))
        #expect(try await bench.send("PATCH", "/api/orders/" + id, body: Self.json(#"{"status":"nope"}"#),
                                     headers: Self.pin).status == 400)
        #expect(try await bench.send("PATCH", "/api/orders/missing", body: Self.json(#"{"status":"qc"}"#),
                                     headers: Self.pin).status == 404)
        #expect(try await bench.send("PATCH", "/api/orders/" + id, body: Self.json(#"{"machineId":true}"#),
                                     headers: Self.pin).status == 400, "a machineId that is not an id is refused")
        #expect(try await bench.send("PATCH", "/api/orders/" + id, body: Self.json(#"{"machineId":null}"#),
                                     headers: Self.pin).status == 200, "null still unassigns")
        bench.book.put(["id": .string("Q-1"), "status": .string("quote"), "project": .string("Q"),
                        "quoteExpiresAt": .string("2099-01-01")])
        let approved = try await bench.send("POST", "/api/orders/Q-1/approve", body: Self.json("{}"), headers: Self.pin)
        #expect(approved.status == 200)
        #expect(bench.book.job("Q-1")?["status"] == .string("pending"))
        #expect(try await bench.send("POST", "/api/orders/Q-1/approve", body: Self.json("{}"), headers: Self.pin).status == 409)
    }

    @Test("a declined request leaves the list for its history, and the write chain tombstones it")
    func waitingListDecline() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        bench.book.value["waitingList"] = .array([.object(["id": .string("w1"), "project": .string("Ask"), "rev": .number(3)])])
        let reminded = try await bench.send("PATCH", "/api/waiting-list/w1",
                                            body: Self.json(#"{"status":"reminded","reminderDate":"2027-02-01"}"#), headers: Self.pin)
        #expect(reminded.status == 200)
        #expect(Self.rows(bench, "waitingList").first?["reminderDate"] == .string("2027-02-01"))
        #expect(try await bench.send("PATCH", "/api/waiting-list/w1", body: Self.json(#"{"status":"reminded","reminderDate":"tomorrow"}"#),
                                     headers: Self.pin).status == 400)
        let reply = try await bench.send("PATCH", "/api/waiting-list/w1", body: Self.json(#"{"status":"declined"}"#), headers: Self.pin)
        #expect(reply.status == 200)
        #expect(Self.rows(bench, "waitingList").isEmpty)
        let history = Self.rows(bench, "waitingListHistory")
        #expect(history.first?["id"] == .string("w1"))
        #expect(history.first?["status"] == .string("declined"))
        // Through the real write chain, on a real file: the entry that left is tombstoned.
        let dir = FileManager.default.temporaryDirectory.appending(path: "lanrest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) } // scratch
        let url = dir.appending(path: "store.json")
        let root: [String: JSONValue] = ["settings": .object([:]),
                                         "waitingList": .array([.object(["id": .string("w1"), "rev": .number(3)])])]
        try JSONValue.encode(root).write(to: url)
        let ctx = bench.server.restContext()
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            _ = try await Shop.applyLanRest(into: &root, engine: bench.engine, op: "waitingListPatch",
                                            args: [.string("w1"), .object(["status": .string("declined")]), ctx])
        }
        let written = try JSONValue.decode([String: JSONValue].self, from: Data(contentsOf: url))
        guard case .array(let tombs)? = written["tombstones"] else { Issue.record("no tombstones"); return }
        #expect(tombs.contains { if case .object(let t) = $0 { return t["collection"] == .string("waitingList") && t["id"] == .string("w1") } else { return false } })
    }

    @Test("the printer webhook takes its own token, by header, and moves the job on that machine")
    func printerWebhook() async throws {
        let closed = try await Bench(rest: true)
        defer { closed.stop() }
        #expect(try await closed.send("POST", "/api/webhook/printer/m1", body: Self.json(#"{"topic":"PrintDone"}"#)).status == 401,
                "no token configured refuses everybody")
        let bench = try await Bench(rest: true, printerWebhookToken: "hook-secret-123")
        defer { bench.stop() }
        bench.book.value["machines"] = .array([.object(["id": .string("m1"), "name": .string("MK4")])])
        // WITH a history: the desktop wrote this job's twice over (#2252 review),
        // because its probe and its write shared one book. Here the probe and
        // the write each cross into JavaScriptCore as a fresh JSON copy.
        bench.book.put(["id": .string("J1"), "status": .string("printing"), "machineId": .string("m1"), "project": .string("Vase"),
                        "statusHistory": .array([.object(["status": .string("printing"), "at": .string("2027-01-15T08:00:00.000Z")])])])
        let wrong = try await bench.send("POST", "/api/webhook/printer/m1", body: Self.json(#"{"topic":"PrintDone"}"#),
                                         headers: ["x-khayt-webhook-token": "nope"])
        #expect(wrong.status == 401)
        #expect(try await bench.send("POST", "/api/webhook/printer/m1?token=hook-secret-123",
                                     body: Self.json(#"{"topic":"PrintDone"}"#)).status == 401, "never from the address")
        let ok = try await bench.send("POST", "/api/webhook/printer/m1", body: Self.json(#"{"topic":"PrintDone"}"#),
                                      headers: ["x-khayt-webhook-token": "hook-secret-123"])
        #expect(ok.status == 200)
        #expect(bench.book.job("J1")?["status"] == .string("post"))
        guard case .array(let trail)? = bench.book.job("J1")?["statusHistory"] else { Issue.record("no history"); return }
        #expect(trail.count == 2, "one new entry, not one per decision")
    }

    /// A shelf and a job that prints 160 g off it, in a shop that deducts.
    static func shelfAndJob(_ bench: Bench, status: String = "printing", settings: [String: JSONValue] = [:]) {
        var s: [String: JSONValue] = ["autoDeduct": .bool(true)]
        for (k, v) in settings { s[k] = v }
        bench.book.value["settings"] = .object(s)
        bench.book.value["inventory"] = .array([
            .object(["id": .string("S1"), "material": .string("PLA"), "weight": .number(1000), "rev": .number(1)]),
        ])
        bench.book.put(["id": .string("J1"), "project": .string("Bracket"), "status": .string(status), "rev": .number(1),
                        "parts": .array([.object(["filamentId": .string("S1"), "printWeight": .number(150),
                                                  "supportWeight": .number(10), "qty": .number(1)])]),
                        "statusHistory": .array([.object(["status": .string(status), "at": .string("2027-01-15T08:00:00.000Z")])])])
    }

    static func weight(_ bench: Bench, _ id: String) -> JSONValue? {
        rows(bench, "inventory").first { $0["id"] == .string(id) }?["weight"]
    }

    @Test("a job finished over the LAN runs the board's move: the shelf, the completion, one history entry — once")
    func lanCompletionIsTheBoardsMove() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        Self.shelfAndJob(bench)
        let done = try await bench.send("PATCH", "/api/orders/J1", body: Self.json(#"{"status":"completed"}"#), headers: Self.pin)
        #expect(done.status == 200)
        let job = try #require(bench.book.job("J1"))
        #expect(job["status"] == .string("completed"))
        #expect(job["completedAt"] != nil, "the completion is dated")
        #expect(job["materialDeducted"] == .bool(true))
        #expect(Self.weight(bench, "S1") == .number(840), "160 g off the spool, as a move on the board takes")
        guard case .array(let trail)? = job["statusHistory"] else { Issue.record("no history"); return }
        #expect(trail.count == 2, "one new entry — the rule applied once, not by JavaScript and again by the move")

        // The same status again is no move: nothing more comes off the shelf.
        let again = try await bench.send("PATCH", "/api/orders/J1", body: Self.json(#"{"status":"completed"}"#), headers: Self.pin)
        #expect(again.status == 200)
        #expect(Self.weight(bench, "S1") == .number(840), "never deducted twice")
        guard case .array(let still)? = bench.book.job("J1")?["statusHistory"] else { Issue.record("no history"); return }
        #expect(still.count == 2)
    }

    @Test("the move and the machine in one PATCH: both land, the status once")
    func moveAndMachine() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        Self.shelfAndJob(bench, status: "pending")
        bench.book.value["machines"] = .array([.object(["id": .string("m1"), "name": .string("MK4")])])
        let reply = try await bench.send("PATCH", "/api/orders/J1", body: Self.json(#"{"status":"printing","machineId":"m1"}"#),
                                         headers: Self.pin)
        #expect(reply.status == 200)
        let job = try #require(bench.book.job("J1"))
        #expect(job["status"] == .string("printing"))
        #expect(job["machine"] == .string("MK4"))
        #expect(job["timerStart"] != nil, "the timer starts, as on the board")
        #expect(Self.rows(bench, "auditLog").first?["detail"] == .string("J1 → printing"),
                "and the move is in the team's activity log")
        let body = try JSONValue.decode(JSONValue.self, from: reply.body)
        guard case .object(let b) = body, case .object(let o)? = b["order"] else { Issue.record("no order"); return }
        #expect(o["status"] == .string("printing"))
        #expect(o["machineId"] == .string("m1"))
        // A machine that is not there is refused before anything moves.
        Self.shelfAndJob(bench, status: "pending")
        let bad = try await bench.send("PATCH", "/api/orders/J1", body: Self.json(#"{"status":"printing","machineId":"nope"}"#),
                                       headers: Self.pin)
        #expect(bad.status == 404)
        #expect(bench.book.job("J1")?["status"] == .string("pending"))
    }

    @Test("a move the shop's rules refuse is the desktop's 409, word for word, and writes nothing")
    func refusedMoveIs409() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        Self.shelfAndJob(bench, status: "pending", settings: ["productionPaused": .bool(true)])
        let before = bench.book.value
        let reply = try await bench.send("PATCH", "/api/orders/J1", body: Self.json(#"{"status":"printing"}"#), headers: Self.pin)
        #expect(reply.status == 409)
        #expect(reply.text == #"{"code":"production_paused","error":"Move refused","params":{}}"#)
        #expect(bench.book.value == before)
    }

    @Test("inside the write, a refused move is the same 409 body and the book is untouched")
    func refusalInsideTheWrite() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        var root: [String: JSONValue] = [
            "settings": .object(["productionPaused": .bool(true)]),
            "printLog": .array([.object(["id": .string("J1"), "status": .string("pending")])]),
        ]
        let before = root
        let done = try await Shop.applyLanRestWrite(into: &root, engine: engine, words: words, op: "orderPatch",
                                                    args: [.string("J1"), .object(["status": .string("printing")]), .object([:])])
        #expect(done.outcome.status == 409)
        #expect(done.outcome.body == .object(["error": .string("Move refused"), "code": .string("production_paused"),
                                              "params": .object([:])]))
        #expect(done.move == nil)
        #expect(root == before)
    }

    @Test("the board's own refusal carries the gate's code and params, which the LAN 409 sends")
    func moveRefusalCarriesTheCode() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        var root: [String: JSONValue] = [
            "settings": .object(["productionPaused": .bool(true)]),
            "printLog": .array([.object(["id": .string("J1"), "status": .string("pending")])]),
        ]
        do {
            _ = try await Shop.applyMove(to: &root, id: "J1", stage: .printing, engine: engine, words: words)
            Issue.record("a paused shop moved a job to printing")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.code == "production_paused")
            #expect(refused.params.isEmpty)
            #expect(!refused.sentence.isEmpty, "the person at the board still reads a sentence")
        }
        do {
            _ = try await Shop.applyMove(to: &root, id: "missing", stage: .printing, engine: engine, words: words)
            Issue.record("a missing job moved")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.code == "order_gone")
        }
    }

    @Test("a quote accepted over the LAN earns its invoice number, as on the board")
    func quoteAcceptedGetsInvoiceNumber() async throws {
        let bench = try await Bench(rest: true)
        defer { bench.stop() }
        bench.book.value["settings"] = .object([:])
        bench.book.put(["id": .string("QUO-2027-0001-abcd"), "jobNumber": .string("QUO-2027-0001"),
                        "status": .string("quote"), "project": .string("Sign"), "invoiceNum": .null])
        let reply = try await bench.send("PATCH", "/api/orders/QUO-2027-0001-abcd", body: Self.json(#"{"status":"pending"}"#),
                                         headers: Self.pin)
        #expect(reply.status == 200)
        let job = try #require(bench.book.job("QUO-2027-0001-abcd"))
        #expect(job["status"] == .string("pending"))
        #expect(job["quoteAcceptedAt"] != nil)
        guard case .string(let number)? = job["invoiceNum"] else { Issue.record("no invoice number"); return }
        #expect(number.hasPrefix("INV-"))
    }

    @Test("a server that has not wired the writes does not have the write routes")
    func unwired() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        #expect(try await bench.send("POST", "/api/orders", body: Self.json(#"{"project":"X"}"#), headers: Self.pin).status == 404)
        #expect(try await bench.send("GET", "/api/orders", headers: Self.pin).status == 200, "the reads are always here")
    }
}
