import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Recalculate from parts" on the Mac: the shared vectors
/// (`test/fixtures/reprice-vectors.json`, the file desktop and phone run)
/// through the Mac's engine, and the sheet's answer mapping.
@Suite struct RepriceTests {

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "test/fixtures")

    static func vectors() throws -> [String: JSONValue] {
        let v = try JSONValue.decode(JSONValue.self, from: Data(contentsOf: fixtures.appending(path: "reprice-vectors.json")))
        guard case .object(let o) = v else { throw CocoaError(.fileReadCorruptFile) }
        return o
    }

    static func obj(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    static func num(_ v: JSONValue?) -> Double? {
        if case .number(let n)? = v { return n }
        return nil
    }

    /// Each case: a job made by newOrder from its cart, a price typed over it,
    /// disturbed as the case says, then priced again from its parts.
    @Test("the shared reprice vectors, through the engine")
    func vectorsAgree() async throws {
        let v = try Self.vectors()
        guard case .array(let cases)? = v["cases"] else { Issue.record("no cases"); return }
        #expect(cases.count >= 12)
        let engine = try KhaytEngine()
        let made = Date(timeIntervalSince1970: 1_795_593_600)  // 2026-11-19T08:00:00Z
        for value in cases {
            let c = Self.obj(value)
            let why: String = { if case .string(let s)? = c["why"] { return s }; return "?" }()
            var settings = Self.obj(v["settings"])
            var input: [String: JSONValue] = ["parts": .array([v["part"] ?? .null]), "project": .string("R"),
                                              "margin": settings["defaultMargin"] ?? .number(0)]
            for (k, x) in Self.obj(c["cart"]) { input[k] = x }
            input["asQuote"] = .bool(c["asQuote"] == .bool(true))
            let consumables: [JSONValue] = { if case .array(let a)? = c["makeConsumables"] { return a }; return [] }()
            let out = try await engine.newOrder(input, orders: [], settings: settings, now: made,
                                          tokens: (tracking: Array(repeating: 0, count: 16), quoteApproval: Array(repeating: 0, count: 16)),
                                          consumables: consumables,
                                          clients: [.object(["id": .string("CU"), "currency": .string("USD")])])
            var order = Self.obj(out.order)
            let madeAt = Self.num(order["price"]) ?? 0
            if case .array(let unset)? = c["unset"] {
                for k in unset { if case .string(let s) = k { order.removeValue(forKey: s) } }
            }
            let typed = c["typed"] ?? .null
            order["price"] = typed; order["priceSource"] = .string("override")
            order["priceOverride"] = typed; order["computedPrice"] = typed
            for (k, x) in Self.obj(c["set"]) { order[k] = x }
            if let later = c["laterRates"] { settings["exchangeRates"] = later }
            let ctx = Self.obj(c["ctx"])
            let r = try await engine.applyJobEdit(
                order: .object(order), fields: ["reprice": c["req"] ?? .object([:])], clients: [], settings: settings,
                priceSeenOk: ctx["priceSeenOk"] == .bool(true), milestonesOk: ctx["milestonesOk"] == .bool(true),
                now: Date(timeIntervalSince1970: 1_795_597_200), editId: "e", priceId: "p")
            let want = Self.obj(c["want"])
            #expect(r.ok == (want["ok"] == .bool(true)), "\(why): \(r.reason ?? "")")
            if want["ok"] != .bool(true) {
                if case .string(let reason)? = want["reason"] { #expect(r.reason == reason, "\(why)") }
                #expect(r.step == "reprice", "\(why)")
                continue
            }
            let after = Self.obj(r.order)
            let expected = want["priceFromNewOrder"] == .bool(true) ? madeAt : (Self.num(want["price"]) ?? -1)
            #expect(Self.num(after["price"]) == expected, "\(why): price \(Self.num(after["price"]) ?? -1) vs \(expected)")
            if let used = Self.num(want["usedMarkup"]) { #expect(r.marginPct == used, "\(why): markup") }
            if want["typedGone"] == .bool(true) {
                #expect(after["priceSource"] != .string("override") && after["priceOverride"] == nil, "\(why)")
            }
            if case .array(let amounts)? = want["lineAmounts"], case .array(let lines)? = after["extraLines"] {
                #expect(lines.map { Self.obj($0)["amount"] } == amounts, "\(why): lines")
            }
            // A product's labour and packaging stay on the job (shop currency).
            for (k, x) in Self.obj(want["keepsOnce"]) {
                #expect(Self.num(after[k]) == Self.num(x), "\(why): \(k) kept")
            }
        }
    }

    /// The sheet's mapping: questions are asked, refusals are said in words,
    /// a yes goes through. On the sample book, nothing written to disk.
    @MainActor @Test("the shop's answer: ask, refuse, ready")
    func answers() async throws {
        let engine = try KhaytEngine()
        let v = try Self.vectors()
        var settings = Self.obj(v["settings"])
        settings["defaultMargin"] = .number(30)
        let out = try await engine.newOrder(["parts": .array([v["part"] ?? .null]), "project": .string("R"), "margin": .number(30)],
                                      orders: [], settings: settings, now: Date(),
                                      tokens: (tracking: Array(repeating: 0, count: 16), quoteApproval: Array(repeating: 0, count: 16)))
        var order = Self.obj(out.order)
        order["price"] = .number(999); order["priceSource"] = .string("override"); order["priceOverride"] = .number(999)
        let words = Shop.repriceRefusalWords(Words())
        let ready = await Shop.repriced(.object(order), marginPct: 50, priceSeenOk: true, milestonesOk: true,
                                        clients: [], settings: settings, overheadPerHour: nil,
                                        engine: engine, refusals: words)
        guard case .ready(_, let was, let now, let used) = ready else { Issue.record("not ready: \(ready)"); return }
        #expect(was == 999 && now != 999 && used == 50)
        // Voided: refused, in words, never a raw code.
        var voided = order; voided["voidedAt"] = .string("2026-11-19T09:00:00Z"); voided["status"] = .string("voided")
        let refused = await Shop.repriced(.object(voided), marginPct: nil, priceSeenOk: true, milestonesOk: true,
                                          clients: [], settings: settings, overheadPerHour: nil,
                                          engine: engine, refusals: words)
        if case .refused(let said) = refused { #expect(!said.isEmpty && !said.contains("_")) }
        else { Issue.record("a voided job was not refused: \(refused)") }
    }

    /// Wired: Edit Job opens it, and every word it says exists in 9 languages.
    @MainActor @Test("wired into Edit Job")
    func wired() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let sheet = try String(contentsOf: src.appending(path: "JobSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("RecalculateSheet(") && sheet.contains("\"mac.rc_link\""))
        let rc = try String(contentsOf: src.appending(path: "RecalculateSheet.swift"), encoding: .utf8)
        let words = Words()
        for key in ["mac.rc_link", "mac.rc_title", "mac.rc_use", "mac.rc_keep", "mac.rc_seen_title", "mac.rc_milestones"] {
            #expect(words.callIt(key) != key, "\(key) has words")
        }
        #expect(rc.contains("shop.reprice(") && rc.contains("previewReprice("))
    }
}
