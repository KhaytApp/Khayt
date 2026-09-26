import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's Q3 margin read −495.8%: nineteen test prints charged nothing,
/// and the Mac had no way to say they were not business.
@MainActor
struct NonBusinessTests {

    static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }

    @Test("the shared setter marks a job and takes the mark away, as the other app writes it")
    func setter() async throws {
        let engine = try KhaytEngine()
        let job: JSONValue = .object(["id": .string("j1"), "price": .number(0)])
        let marked = try await engine.setNonBusiness(job, on: true)
        guard case .object(let m) = marked else { Issue.record("not an object"); return }
        #expect(m["nonBusiness"] == .bool(true))
        let unmarked = try await engine.setNonBusiness(marked, on: false)
        guard case .object(let u) = unmarked else { Issue.record("not an object"); return }
        #expect(u["nonBusiness"] == nil, "cleared by removing the field, not by writing false")
    }

    // ── THE DASHBOARD ASKS (Sep 2026) ────────────────────────────────────────
    //
    // Triage said "0 things need you" over the same nineteen jobs.

    static func job(_ id: String, _ status: String, price: Double?, extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status),
                                      "project": .string(id), "date": .string("2026-09-10")]
        if let price { o["price"] = .number(price) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static let book: [JSONValue] = [
        job("paid", "completed", price: 50),
        job("zero", "completed", price: 0),
        job("missing", "delivered", price: nil),
        job("marked", "completed", price: 0, extra: ["nonBusiness": .bool(true)]),
        job("voided", "completed", price: 0, extra: ["voidedAt": .string("2026-09-11")]),
        job("quote", "quote", price: 0),
        job("open", "printing", price: 0),
    ]

    @Test("the dashboard's facts count finished jobs charged nothing, and only those")
    func factsCountThem() async throws {
        let facts = try await KhaytEngine().dashboardFacts(orders: Self.book, machines: [], settings: [:])
        let unpriced = try #require(facts.unpriced, "the bundle's dashboard-facts carries no `unpriced`")
        #expect(unpriced.ids == ["zero", "missing"])
        #expect(!facts.attn.items.contains { $0.id == "zero" }, "and it is not an attention item")
    }

    @Test("marking them all touches only the jobs the rule still counts")
    func markingThemAll() async throws {
        let engine = try KhaytEngine()
        // `paid` is asked for too — a stale card — and must be left alone.
        let changed = try await Shop.markedNotBusiness(Self.book, ids: ["zero", "missing", "paid", "voided"],
                                                        engine: engine)
        #expect(changed.compactMap(Shop.recordId) == ["zero", "missing"])
        for row in changed {
            guard case .object(let o) = row else { Issue.record("not an object"); continue }
            #expect(o["nonBusiness"] == .bool(true))
        }
        let after = Self.book.map { row in changed.first { Shop.recordId($0) == Shop.recordId(row) } ?? row }
        #expect(try await engine.unpricedFinished(orders: after).count == 0)
    }

    @Test("the triage card writes through the store, one undo, and is wired to its button")
    func triageIsWired() throws {
        let shop = try Self.source("Shop.swift")
        let body = try #require(shop.range(of: "func markNotBusiness(").map { String(shop[$0.lowerBound...].prefix(1800)) })
        #expect(body.contains("StoreWriter.update("), "a book write that is not StoreWriter.update")
        #expect(body.contains("registerMoveUndo(undo"), "marking nineteen jobs cannot be undone")
        let model = try Self.source("TriageModel.swift")
        #expect(model.contains("run: .markNotBusiness(unpriced.ids)"))
        #expect(model.contains("await markNotBusiness(ids)"))
    }

    @Test("a job can be marked from its right-click menu and from Edit job")
    func reachable() throws {
        #expect(try Self.source("OrdersTable.swift").contains("await shop.setNonBusiness(job.id, on)"))
        #expect(try Self.source("EditJobSheet.swift").contains("await shop.setNonBusiness(id, nowNonBusiness)"))
        #expect(try Self.source("Reports.swift").contains("mac.pnl_unpriced"),
                "the P&L no longer says why a margin is negative")
        #expect(try Self.source("Reports.swift").contains("callIt(\"pnl.cogs\")"),
                "the net takes the cost of goods off, so the P&L has to show that line")
    }
}
