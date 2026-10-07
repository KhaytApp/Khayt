import Foundation
import JavaScriptCore
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's staff on the Mac: the records, the delete, a job's operator, the
/// time log, and the two report cards.
@Suite @MainActor struct OperatorsTests {

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func book() -> [String: JSONValue] {
        [
            "operators": .array([
                .object(["id": .string("OP-a"), "name": .string("Ali"), "role": .string("Technician"),
                         "roleKey": .string("manager"), "hourlyRate": .number(40), "active": .bool(true),
                         "pinHash": .string("p2$1000$abcd$ef01"), "rev": .number(3),
                         "somethingNew": .string("kept")]),
                .object(["id": .string("OP-b"), "name": .string("Sara"), "role": .string("Admin")]),
            ]),
            "printLog": .array([.object(["id": .string("o1"), "operatorId": .string("OP-a")]),
                                .object(["id": .string("o2")])]),
            "timeEntries": .array([]),
        ]
    }

    static func record(_ root: [String: JSONValue], _ collection: String, _ id: String) -> [String: JSONValue]? {
        for row in Shop.rows(root, collection) {
            if case .object(let r) = row, r["id"] == .string(id) { return r }
        }
        return nil
    }

    // ── THE RECORD ──────────────────────────────────────────────────────

    @Test("saving someone deleted elsewhere while the sheet was open does not re-create them")
    func editOfDeletedIsRefused() throws {
        var root = Self.book()
        let op = try #require(ShopOperator(row: Shop.rows(root, "operators")[0]))
        root["operators"] = .array([Shop.rows(root, "operators")[1]])   // OP-a deleted meanwhile
        let before = root
        var undo: [Shop.ChangedRecord] = []
        var changed = op.fields
        changed.name = "Ali Al-Hassan"
        let saved = Shop.writeOperator(into: &root, id: "OP-a", changed, opened: op.fields,
                                       newId: "OP-new", undo: &undo)
        #expect(!saved)
        #expect(root == before, "a deleted operator came back under a new id")
        #expect(undo.isEmpty)
    }

    @Test("an edit writes only what changed; pinHash and every other field survive")
    func editKeepsFields() throws {
        var root = Self.book()
        var undo: [Shop.ChangedRecord] = []
        let op = try #require(ShopOperator(row: Shop.rows(root, "operators")[0]))
        var changed = op.fields
        changed.name = "Ali Al-Hassan"
        changed.hourlyRate = 55
        Shop.writeOperator(into: &root, id: "OP-a", changed, opened: op.fields, newId: "unused", undo: &undo)
        let after = try #require(Self.record(root, "operators", "OP-a"))
        #expect(after["name"] == .string("Ali Al-Hassan"))
        #expect(after["hourlyRate"] == .number(55))
        #expect(after["pinHash"] == .string("p2$1000$abcd$ef01"), "the other app's lock still opens")
        #expect(after["somethingNew"] == .string("kept"))
        #expect(after["roleKey"] == .string("manager"))
        if case .number(let rev)? = after["rev"] { #expect(rev > 3, "stamped") } else { Issue.record("rev lost") }
        #expect(undo.count == 1)
    }

    @Test("saving an old record untouched stamps no access level on it")
    func untouchedLegacyRecord() throws {
        var root = Self.book()
        var undo: [Shop.ChangedRecord] = []
        let legacy = try #require(ShopOperator(row: Shop.rows(root, "operators")[1]))
        #expect(legacy.roleKey == nil)
        #expect(legacy.shownRoleKey == "owner", "the other app reads an Admin title as owner")
        Shop.writeOperator(into: &root, id: "OP-b", legacy.fields, opened: legacy.fields,
                           newId: "unused", undo: &undo)
        #expect(Self.record(root, "operators", "OP-b")?["roleKey"] == nil)
        #expect(undo.isEmpty, "nothing changed, nothing written")
    }

    @Test("a new operator is the other app's shape")
    func newShape() throws {
        var root = Self.book()
        var undo: [Shop.ChangedRecord] = []
        let f = ShopOperator.Fields(name: " Reem ", role: "Finishing", roleKey: "viewer", hourlyRate: 35, active: true)
        Shop.writeOperator(into: &root, id: nil, f, opened: nil, newId: "OP-new", undo: &undo)
        let r = try #require(Self.record(root, "operators", "OP-new"))
        #expect(r["name"] == .string("Reem"))
        #expect(r["roleKey"] == .string("viewer"))
        #expect(r["active"] == .bool(true))
        #expect(Set(r.keys).isSuperset(of: ["id", "name", "role", "roleKey", "hourlyRate", "active"]))
        #expect(undo.first?.kind == .created)
        #expect(Shop.uid("OP").hasPrefix("OP-"))
    }

    @Test("the access levels are lib/rbac.js's, and an old title reads as it does there")
    func rolesAgree() throws {
        let src = try String(contentsOf: Self.repoRoot().appending(path: "lib/rbac.js"), encoding: .utf8)
        let line = try #require(src.split(separator: "\n").first { $0.hasPrefix("const ROLES = [") })
        let names = line.split(separator: "'").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(names == ShopOperator.roles)

        let ctx = try #require(JSContext())
        ctx.evaluateScript(src)
        for title in ["", "Admin", "Shop manager", "Sales", "Senior Technician", "Viewer", "read only", "Painter"] {
            let js = ctx.evaluateScript("globalThis.KhaytRbac.roleFromLegacy(\(String(reflecting: title)))")?.toString()
            let row: JSONValue = .object(["id": .string("x"), "role": .string(title)])
            #expect(ShopOperator(row: row)?.shownRoleKey == js, "\(title)")
        }
    }

    // ── THE DELETE ──────────────────────────────────────────────────────

    @Test("deleting somebody with work makes them inactive and keeps their record whole")
    func deleteWithWork() async throws {
        var root = Self.book()
        let before = Shop.rows(root, "operators")
        let out = try await KhaytEngine().removeOperator(book: root, id: "OP-a")
        #expect(out.outcome == "deactivated")
        let undo = Shop.operatorRemoval(&root, before: before, after: out.operators, id: "OP-a")
        let r = try #require(Self.record(root, "operators", "OP-a"))
        #expect(r["active"] == .bool(false))
        #expect(r["pinHash"] == .string("p2$1000$abcd$ef01"))
        #expect(Self.record(root, "printLog", "o1")?["operatorId"] == .string("OP-a"),
                "who did the job is history, not cleared")
        #expect(undo.first?.kind == .edited)
    }

    @Test("deleting somebody with no work removes them, and undo can put them back where they were")
    func deleteWithoutWork() async throws {
        var root = Self.book()
        let before = Shop.rows(root, "operators")
        let out = try await KhaytEngine().removeOperator(book: root, id: "OP-b")
        #expect(out.outcome == "removed")
        let undo = Shop.operatorRemoval(&root, before: before, after: out.operators, id: "OP-b")
        #expect(Self.record(root, "operators", "OP-b") == nil)
        #expect(undo.first?.kind == .deleted)
        #expect(undo.first?.at == 1)
    }

    // ── A JOB'S OPERATOR AND ITS HOURS ─────────────────────────────────

    @Test("a job is put on somebody, or on nobody, as the other app writes it")
    func jobOperator() {
        let on = Shop.withOperator(.object(["id": .string("o2")]), "OP-b")
        #expect(Shop.asObject(on)?["operatorId"] == .string("OP-b"))
        let off = Shop.withOperator(on, nil)
        #expect(Shop.asObject(off)?["operatorId"] == nil, "nobody is no field, as the other app leaves it")
    }

    @Test("a job's operatorId reads leniently")
    func lenientDecode() throws {
        // A number reads as its digits — the app's lenient decoding — and names
        // nobody on the list, so it shows as an operator no longer there
        // rather than making the job unreadable.
        let job = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"o","operatorId":7}"#.utf8))
        #expect(job.operatorId == nil || job.operatorId == "7")
        let junk = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"o","operatorId":{"a":1}}"#.utf8))
        #expect(junk.operatorId == nil)
        let blank = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"o","operatorId":""}"#.utf8))
        #expect(blank.operatorId == nil)
    }

    @Test("logged time is the other app's shape, with the rate frozen")
    func timeEntryShape() throws {
        var root = Self.book()
        var undo: [Shop.ChangedRecord] = []
        Shop.writeTimeEntry(into: &root, id: "TE-1", jobId: "o1", operatorId: "OP-a", hours: 2.5,
                            day: "2026-10-07", notes: " sanding ", at: "2026-10-07T10:00:00.000Z", undo: &undo)
        let r = try #require(Self.record(root, "timeEntries", "TE-1"))
        // The keys `openTimeEntryModal` writes (renderer/ops-locations.js).
        for key in ["id", "orderId", "operatorId", "operatorName", "hours", "hourlyRate", "cost",
                    "date", "notes", "createdAt"] {
            #expect(r[key] != nil, "\(key)")
        }
        #expect(r["operatorName"] == .string("Ali"))
        #expect(r["hourlyRate"] == .number(40))
        #expect(r["cost"] == .number(100))
        #expect(r["notes"] == .string("sanding"))
        #expect(undo.first?.kind == .created)
        let entry = try #require(TimeEntry(row: .object(r)))
        #expect(entry.cost == 100 && entry.hours == 2.5)
    }

    // ── THE SAMPLE SHOP REACHES EVERYTHING ──────────────────────────────

    @Test("the sample shop reaches both staff cards, every row with something in it")
    func sampleReachesThem() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.operators.count == 3)
        #expect(shop.operators.contains { !$0.active }, "an inactive operator, so that state is drawn")
        let engine = try KhaytEngine()
        let perf = try await engine.operatorPerformance(
            operators: shop.operatorRows, orders: shop.orderRows, wasteLog: shop.wasteRows,
            settings: shop.settingsDict, clients: shop.clientRows)
        #expect(perf.hasOperators)
        #expect(perf.rows.allSatisfy { $0.jobs > 0 })
        #expect(perf.rows.contains { !$0.known }, "work by somebody no longer on the list")
        #expect(perf.rows.contains { $0.known && !$0.active })
        #expect(perf.rows.contains { $0.wasteGrams > 0 }, "waste on a job that has not finished")
        #expect(perf.rows.filter { $0.accuracyPct != nil }.count >= 2)

        let time = try await engine.operatorTime(
            timeEntries: shop.timeEntryRows, orders: shop.orderRows, operators: shop.operatorRows,
            settings: shop.settingsDict, clients: shop.clientRows)
        #expect(time.entries >= 8)
        #expect(time.operators.allSatisfy { $0.hours > 0 && $0.cost > 0 })
        #expect(time.operators.allSatisfy { $0.revenuePerHour != nil })
        #expect(time.topOrders.contains { $0.operators.count > 1 }, "a job two people shared")
        // Time on no job is counted in the hours and left out of hours per job.
        let onJobs = time.totals.avgHoursPerOrder.map { $0 * Double(time.totals.orders) } ?? 0
        #expect(time.totals.hours > onJobs)
        let shared = try #require(time.topOrders.first { $0.operators.count > 1 })
        #expect(shop.timeEntries(for: shared.orderId).count >= 2)
    }

    @Test("the staff cards and sections, photographed")
    func picture() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try KhaytEngine()
        let perf = try await engine.operatorPerformance(
            operators: shop.operatorRows, orders: shop.orderRows, wasteLog: shop.wasteRows,
            settings: shop.settingsDict, clients: shop.clientRows)
        let time = try await engine.operatorTime(
            timeEntries: shop.timeEntryRows, orders: shop.orderRows, operators: shop.operatorRows,
            settings: shop.settingsDict, clients: shop.clientRows)
        let snap = SnapshotTests()
        let perfCard = OperatorPerformanceCard(shop: shop, report: perf)
            .card(rail: Khayt.brand, padding: 14).padding(16).background(Role.bg)
        try snap.render(perfCard, "operator-performance", size: CGSize(width: 820, height: 300))
        try snap.renderDark(perfCard, "operator-performance-dark", size: CGSize(width: 820, height: 300))
        let timeCard = OperatorTimeCard(shop: shop, report: time)
            .card(rail: Khayt.brand, padding: 14).padding(16).background(Role.bg)
        try snap.render(timeCard, "operator-time", size: CGSize(width: 820, height: 470))
        try snap.renderDark(timeCard, "operator-time-dark", size: CGSize(width: 820, height: 470))
        let section = OperatorsSection(shop: shop).padding(20).background(Role.bg)
        try snap.render(section, "operators-settings", size: CGSize(width: 600, height: 330))
        let shared = try #require(time.topOrders.first { $0.operators.count > 1 })
        let job = try #require(shop.orders.first { $0.id == shared.orderId })
        let onJob = JobStaffSection(shop: shop, job: job).frame(width: 340).padding(16).background(Role.bg)
        try snap.render(onJob, "job-staff", size: CGSize(width: 380, height: 260))
    }
}
