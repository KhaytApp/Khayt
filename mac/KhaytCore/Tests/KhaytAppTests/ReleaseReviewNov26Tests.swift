import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The pre-beta.43 findings of the Nov 26 release review
/// (`~/Khayt-proposals/release-review-nov26/security.md` MED-1 and MED-5,
/// `mac.md` M1, L3 and L5). Each test was run against main first and failed
/// there.
@MainActor
@Suite(.serialized)
struct ReleaseReviewNov26Tests {

    // MARK: - MED-1: a repeated JSON key

    /// The role rule reads a body with JavaScript (the LAST of a repeated key
    /// wins); the route reads it with Swift (the FIRST wins). Sent twice, a key
    /// could be one thing to the rule and another to the route.
    @Test("a signed phone's body with a repeated key is refused before the rule or the route reads it")
    func repeatedKey() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let op = try PhoneRolesTests.codePaired(bench.devices, role: "operator")
        let manager = try PhoneRolesTests.codePaired(bench.devices, role: "manager", name: "M")
        guard case .array(let before)? = bench.book.value["printLog"] else { Issue.record("no jobs"); return }
        let quote = before.compactMap { row -> String? in
            if case .object(let o) = row, o["status"] == .string("quote"), case .string(let id)? = o["id"] { return id }; return nil
        }.first
        func send(_ peer: LanConnectorRoutesTests.Peer, _ method: String, _ path: String, _ body: String) async throws -> (Int, [String: Any]) {
            try await PhoneRolesTests.status(bench, peer, method, path, body: Data(body.utf8))
        }
        // Pricing a new job: to the rule, no price; to the route, 999.
        let priced = try await send(op, "POST", "/api/orders", #"{"project":"x","price":999,"price":null}"#)
        #expect(priced.0 == 400 && priced.1["reason"] as? String == "repeated-key", Comment(rawValue: "\(priced)"))
        // Moving a quote on: to the rule, no status; to the route, "pending".
        if let quote {
            let moved = try await send(op, "PATCH", "/api/orders/\(quote)", #"{"status":"pending","status":null}"#)
            #expect(moved.0 == 400 && moved.1["reason"] as? String == "repeated-key", Comment(rawValue: "\(moved)"))
        }
        // Whoever sends it: a manager's repeated key is not an operator's, and it is still not read.
        #expect(try await send(manager, "POST", "/api/orders", #"{"project":"x","notes":"a","notes":"b"}"#).0 == 400)
        // Nested, and spelled another way: "price" is "price".
        #expect(try await send(op, "POST", "/api/orders", #"{"project":"x","parts":[{"q":1,"q":2}]}"#).0 == 400)
        #expect(try await send(op, "POST", "/api/orders", #"{"project":"x","price":5,"\u0070rice":null}"#).0 == 400)
        // Nothing was written by any of them.
        guard case .array(let after)? = bench.book.value["printLog"] else { Issue.record("no jobs"); return }
        #expect(after.count == before.count, "a job was created from a body with a repeated key")
        if let quote {
            let now = after.first { if case .object(let o) = $0 { return o["id"] == .string(quote) }; return false }
            if case .object(let o)? = now { #expect(o["status"] == .string("quote"), "the quote was moved on") }
        }
        // An ordinary body is not refused: the same key in two different objects is not a repeat.
        let fine = try await send(op, "POST", "/api/orders", #"{"project":"x","parts":[{"q":1},{"q":2}],"notes":"\"q\":1,\"q\":2"}"#)
        #expect(fine.0 != 400, Comment(rawValue: "\(fine)"))
    }

    // MARK: - MED-5: the shop's per-printer limits

    @Test("an operator's phone may not control a printer when the shop took printer control away from operators")
    func printerLimits() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let op = try PhoneRolesTests.codePaired(bench.devices, role: "operator")
        let manager = try PhoneRolesTests.codePaired(bench.devices, role: "manager", name: "M")
        // Roles ▸ Printers: "control" unticked for operators.
        var settings: [String: JSONValue] = { if case .object(let s)? = bench.book.value["settings"] { return s }; return [:] }()
        settings["roleLimits"] = .object(["operator": .object(["printers": .object(["control": .bool(false)])])])
        bench.book.value["settings"] = .object(settings)
        for path in ["/api/printer/M1/pause", "/api/printer/M1/stop", "/api/printer/M1/bed-clear"] {
            let (status, json) = try await PhoneRolesTests.status(bench, op, "POST", path)
            #expect(status == 403 && json["reason"] as? String == "role-scope", Comment(rawValue: "\(path) \(status)"))
        }
        #expect(bench.printerCalls.calls.isEmpty && bench.bedCalls.calls.isEmpty, "an operator's phone moved a printer the shop had taken from operators")
        // A manager is not limited by the operators' row.
        #expect(try await PhoneRolesTests.status(bench, manager, "POST", "/api/printer/M1/pause").0 == 200)
        // And with the limit lifted, the operator may again.
        settings["roleLimits"] = nil
        bench.book.value["settings"] = .object(settings)
        #expect(try await PhoneRolesTests.status(bench, op, "POST", "/api/printer/M1/pause").0 == 200)
    }

    // MARK: - M1: "An update is ready" must reappear

    /// SwiftUI shows one sheet at a time on a window, and a sheet whose
    /// condition becomes true while another is up is dropped. Setting the same
    /// held update again is no change, so it is never shown again either.
    @Test("holding an update that is already held is a change: cleared now, set again on the next turn")
    func holdIsAChange() async throws {
        let shop = Shop()
        let release = [KhaytEngine.GatedRelease(version: "4.0.0-beta.99", items: ["Read me."])]
        shop.holdUpdate("4.0.0-beta.99", release)
        for _ in 0..<200 where shop.updateOffer == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shop.updateOffer?.version == "4.0.0-beta.99")
        // A check, by hand or the hourly one, finds the same update unread again.
        shop.holdUpdate("4.0.0-beta.99", release)
        #expect(shop.updateOffer == nil, "the same value set again: nothing changed, so a dropped sheet stays dropped")
        for _ in 0..<200 where shop.updateOffer == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shop.updateOffer?.version == "4.0.0-beta.99")
    }

    @Test("a held update waits while another sheet is up, then is shown; Later and Continue stop the wait; on screen, the same hold changes nothing")
    func waitsForTheWindow() async throws {
        let shop = Shop()
        var busy = true
        shop.updateGateWindowBusyForTests = { busy }
        let release = [KhaytEngine.GatedRelease(version: "4.0.0-beta.99", items: ["Read me."])]
        shop.holdUpdate("4.0.0-beta.99", release)
        try await Task.sleep(for: .milliseconds(900))
        #expect(shop.updateOffer == nil, "set while another sheet was up: SwiftUI drops it")
        busy = false
        for _ in 0..<300 where shop.updateOffer == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shop.updateOffer?.version == "4.0.0-beta.99")
        // On screen with the same items: the hourly check does not make it flicker.
        shop.updateGateOnScreen = true
        shop.holdUpdate("4.0.0-beta.99", release)
        #expect(shop.updateOffer?.version == "4.0.0-beta.99")
        // A newer update replaces it, even on screen.
        shop.holdUpdate("4.0.0-beta.100", [KhaytEngine.GatedRelease(version: "4.0.0-beta.100", items: ["Newer."])])
        for _ in 0..<300 where shop.updateOffer?.version != "4.0.0-beta.100" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shop.updateOffer?.version == "4.0.0-beta.100")
        shop.updateGateOnScreen = false
        // Later while one is waiting: it does not come back by itself.
        busy = true
        shop.holdUpdate("4.0.0-beta.99", release)
        shop.putOffUpdate()
        busy = false
        try await Task.sleep(for: .milliseconds(900))
        #expect(shop.updateOffer == nil, "a held update came back after Later")
        // After "Khayt was updated" is read, a held update is shown from scratch.
        shop.holdUpdate("4.0.0-beta.99", release)
        for _ in 0..<300 where shop.updateOffer == nil { try await Task.sleep(for: .milliseconds(10)) }
        shop.showHeldUpdateAgain()
        #expect(shop.updateOffer == nil)
        for _ in 0..<300 where shop.updateOffer == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shop.updateOffer?.version == "4.0.0-beta.99")
    }

    @Test("the repeated-key check: what is a repeat and what is not")
    func repeatedKeyCheck() {
        func found(_ text: String) -> Bool { JSONRepeatedKeys.found(in: Data(text.utf8)) }
        for repeat_ in [#"{"a":1,"a":2}"#, #"{"a":1,"b":{"c":1,"c":2}}"#, #"[{"x":1},{"y":1,"y":2}]"#, #"{"price":1,"\u0070rice":2}"#,
                        #"{ "a" : 1 , "a" : 1 }"#, #"{"a":{"b":1},"a":2}"#, #"{"\"":1,"\"":2}"#] {
            #expect(found(repeat_), Comment(rawValue: repeat_))
        }
        for fine in [#"{"a":1,"b":2}"#, #"[{"a":1},{"a":2}]"#, #"{"a":{"a":{"a":1}}}"#, #"{"a":"\"a\":1,\"a\":2"}"#, #"{"a":["a","a"]}"#,
                     "", "not json", "[]", "{}", #"{"a":"}{\"a\":1,\"a\":2"}"#, #"{"a":1"#] {
            #expect(!found(fine), Comment(rawValue: fine))
        }
    }

    // MARK: - L3 and L5

    @Test("failed accounting pushes wait while the shop makes no internet calls, as webhook retries do")
    func accountingRetriesWait() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/Shop+Integrations.swift"), encoding: .utf8)
        let at = try #require(source.range(of: "func retryFailedAccountingPushes()"))
        let body = source[at.upperBound...].prefix(600)
        #expect(body.contains("outboundGate.verdict(.webhooks).allowed"), "a retry made now would only be refused, and use up a try")
    }

    @Test("bed-clear refuses a request an API token let through, as the other signed-phone routes do")
    func bedClearNotByToken() throws {
        let server = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/LanServer.swift"), encoding: .utf8)
        let at = try #require(server.range(of: "Self.bedClearPath(path) != nil:"))
        let route = server[at.upperBound...].prefix(400)
        #expect(route.contains("guard !request.tokenScoped, LanDevices.isSigned(request.headers)"),
                "a token-scoped request skips the signature check in pinGate; the route must refuse it itself")
    }
}
