import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's Q3 margin read −495.8%: nineteen test prints charged nothing,
/// and the Mac had no way to say they were not business.
@MainActor
struct NonBusinessTests {

    static func source(_ name: String) throws -> String {
        try ShopSources.read(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"))
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

    /// Edit job saved its fields and then the Not business box as two writes;
    /// ⌘Q between them (the quit hold counts writes IN FLIGHT, and between
    /// two there is none) kept the first and dropped the second.
    @Test("Edit job's fields and its Not business box are one edit of one record")
    func oneEdit() async throws {
        let engine = try KhaytEngine()
        // A quote: no tax invoice yet, so the mark may move (#2562).
        let job: JSONValue = .object(["id": .string("j1"), "status": .string("quote"), "project": .string("Bracket"),
                                      "price": .number(40)])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let both = try await Shop.jobEdited(job, fields: ["project": .string("Bracket v2")], nonBusiness: true,
                                            settings: [:], engine: engine, now: now, editId: "E1")
        guard case .object(let b) = both else { Issue.record("not an object"); return }
        #expect(b["project"] == .string("Bracket v2"))
        #expect(b["nonBusiness"] == .bool(true))
        // The box alone, the fields alone, and neither.
        let boxOnly = try await Shop.jobEdited(job, fields: [:], nonBusiness: true,
                                               settings: [:], engine: engine, now: now, editId: "E2")
        #expect(boxOnly == (try await engine.setNonBusiness(job, on: true)))
        let fieldsOnly = try await Shop.jobEdited(job, fields: ["project": .string("Bracket v2")], nonBusiness: nil,
                                                  settings: [:], engine: engine, now: now, editId: "E3")
        guard case .object(let f) = fieldsOnly else { Issue.record("not an object"); return }
        #expect(f["project"] == .string("Bracket v2"))
        #expect(f["nonBusiness"] == nil)
        #expect(try await Shop.jobEdited(job, fields: [:], nonBusiness: nil,
                                         settings: [:], engine: engine, now: now, editId: "E4") == job)
    }

    @Test("Edit job saves with one write, never a second one after it")
    func oneWrite() throws {
        let sheet = try Self.source("EditJobSheet.swift")
        let commit = String(sheet[try #require(sheet.range(of: "private func commit() {")).upperBound...])
        #expect(commit.components(separatedBy: "await shop.").count == 2, "one write to the book per save")
        #expect(!commit.contains("shop.setNonBusiness("))
        let shop = try Self.source("Shop+Money.swift")
        let edit = try #require(shop.range(of: "func editJob(_ id: Order.ID").map { String(shop[$0.lowerBound...].prefix(900)) })
        #expect(edit.components(separatedBy: "writeToOneOrder(").count == 2)
        #expect(edit.contains("Self.jobEdited(order, fields: fields, nonBusiness: nonBusiness"))
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
        // Edit job hands the box to the SAME write as its fields (below).
        #expect(try Self.source("EditJobSheet.swift").contains("await shop.editJob(id, fields: fields, nonBusiness: mark)"))
        #expect(try Self.source("Reports.swift").contains("mac.pnl_unpriced"),
                "the P&L no longer says why a margin is negative")
        #expect(try Self.source("Reports.swift").contains("callIt(\"pnl.cogs\")"),
                "the net takes the cost of goods off, so the P&L has to show that line")
    }

    // MARK: - The shared rule (#2562)

    struct Vectors: Decodable {
        struct Want: Decodable { let ok: Bool; let nonBusiness: Bool?; let reason: String?; let step: String? }
        struct Case: Decodable { let why: String; let order: JSONValue; let next: [String: JSONValue]; let want: Want }
        let cases: [Case]
    }

    /// `test/fixtures/business-flag-vectors.json` through the Mac's engine:
    /// the mark moves only before a tax invoice is issued, never on a frozen
    /// job, and a refusal writes nothing.
    @Test("the shared business-flag vectors, through the engine")
    func vectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test/fixtures/business-flag-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        #expect(v.cases.count >= 10)
        let engine = try KhaytEngine()
        for c in v.cases {
            let r = try await engine.applyJobEdit(order: c.order, fields: c.next, now: Date(timeIntervalSince1970: 1),
                                                 editId: "e", priceId: "e2")
            #expect(r.ok == c.want.ok, Comment(rawValue: c.why))
            if !c.want.ok {
                #expect(r.reason == c.want.reason && r.step == c.want.step, Comment(rawValue: c.why))
                #expect(r.order == c.order, "a refusal writes nothing: \(c.why)")
                continue
            }
            guard case .object(let o) = r.order else { Issue.record(Comment(rawValue: c.why)); continue }
            #expect((o["nonBusiness"] == .bool(true)) == (c.want.nonBusiness == true), Comment(rawValue: c.why))
        }
    }

    @Test("every Mac path refuses the mark on a booked job, in the shop's words")
    func pathsRefuse() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let booked: JSONValue = .object(["id": .string("J1"), "status": .string("pending"), "price": .number(100)])
        let business = Shop.businessLockWords(shop.words)
        // The single toggle and the older Edit Job.
        do {
            _ = try await Shop.markedBusiness(booked, nonBusiness: true, settings: [:], engine: engine,
                                              words: business, now: Date())
            Issue.record("marked a booked job")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.code == "invoice_issued" && refused.sentence == business["invoice_issued"])
        }
        do {
            _ = try await Shop.jobEdited(booked, fields: [:], nonBusiness: true, settings: [:], engine: engine,
                                         now: Date(), editId: "E", businessWords: business)
            Issue.record("Edit job marked a booked job")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.code == "invoice_issued")
        }
        // The Edit Job sheet: the box in the same edit, the business sentence.
        var save = Shop.JobSave()
        save.nonBusiness = true
        do {
            _ = try await Shop.jobSaved(booked, save, clients: [], settings: [:], engine: engine,
                                        refusals: Shop.jobSaveRefusalWords(shop.words), now: Date())
            Issue.record("the sheet marked a booked job")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.sentence == business["invoice_issued"])
        }
        #expect(Set(business.keys) == ["invoice_issued", "zatca", "voided", "credited", "cancelled"])
        for (code, sentence) in business { #expect(!sentence.hasPrefix("mac."), "no words: \(code)") }
    }
}
