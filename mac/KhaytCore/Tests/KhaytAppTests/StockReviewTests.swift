import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The stock review's Mac half: waste logged against a job, goods with
/// nowhere to land, a receive that cannot run twice, and "mark dried" writing
/// the drying log.
@MainActor
struct StockReviewTests {

    private static func sources(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/" + file),
            encoding: .utf8)
    }

    private static func number(_ v: JSONValue?) -> Double? {
        if case .number(let n)? = v { return n }
        return nil
    }

    private static func field(_ row: JSONValue, _ key: String) -> JSONValue? {
        if case .object(let o) = row { return o[key] }
        return nil
    }

    private static let shelf: [JSONValue] = [
        .object(["id": .string("S1"), "material": .string("PLA"), "weight": .number(1000),
                 "cost": .number(80), "spoolWeight": .number(1000)]),
        .object(["id": .string("S2"), "material": .string("PLA"), "weight": .number(800),
                 "cost": .number(80), "spoolWeight": .number(1000), "lot": .string("L2")]),
    ]

    private static let job: JSONValue = .object([
        "id": .string("J1"), "project": .string("Lamp"), "machineId": .string("M1"),
        "parts": .array([.object(["filamentId": .string("S2"), "printWeight": .number(300),
                                  "qty": .number(1)])]),
    ])

    private static func input(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var i: [String: JSONValue] = [
            "material": .string("PLA"), "weight": .number(120), "cost": .number(9.6),
            "failureType": .string("warping"), "reason": .string("lifted corner"),
            "orderId": .string("J1"), "machineId": .string(""), "deduct": .bool(true),
        ]
        for (k, v) in extra { i[k] = v }
        return i
    }

    @Test("waste on a job comes off THAT job's spool, records what it took, and deletes cleanly")
    func wasteOnAJob() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.newWasteEntry(Self.input(), id: "W1", today: "2026-10-18",
                                                  inventory: Self.shelf, order: Self.job)
        let entry = try #require(made.entry)
        #expect(Self.number(Self.field(made.inventory[0], "weight")) == 1000,
                "the first PLA spool is not what the job was printing from")
        #expect(Self.number(Self.field(made.inventory[1], "weight")) == 680)
        #expect(Self.field(entry, "drawn") == .array([.object([
            "spoolId": .string("S2"), "grams": .number(120), "lot": .string("L2")])]))
        #expect(Self.field(entry, "orderId") == .string("J1"))
        // What the sheet asked that `forOrder` does not write is kept.
        #expect(Self.field(entry, "reason") == .string("lifted corner"))
        #expect(Self.field(entry, "machineId") == .string("M1"), "the job's printer")
        #expect(Self.field(entry, "cost") == .number(9.6), "the typed cost")
        // The spool's history line carries the lot, so a recall finds it…
        guard case .array(let hist)? = Self.field(made.inventory[1], "usageHistory") else {
            Issue.record("no history line"); return
        }
        #expect(Self.field(hist[0], "lot") == .string("L2"))

        // …and deleting the entry takes the line out with the grams.
        let out = try await engine.removeWasteEntry([entry], id: "W1", inventory: made.inventory)
        #expect(out.removed)
        #expect(Self.number(Self.field(out.inventory[1], "weight")) == 800)
        if case .array(let after)? = Self.field(out.inventory[1], "usageHistory") {
            #expect(after.isEmpty, "a deleted failure still shows in the lot's recall")
        }
    }

    @Test("a job with no spool on any part still takes the grams off the material")
    func wasteOnAnUnassignedJob() async throws {
        let engine = try KhaytEngine()
        let bare: JSONValue = .object(["id": .string("J1"), "parts": .array([])])
        let made = try await engine.newWasteEntry(Self.input(), id: "W1", today: "2026-10-18",
                                                  inventory: Self.shelf, order: bare)
        let entry = try #require(made.entry)
        #expect(Self.number(Self.field(made.inventory[0], "weight")) == 880)
        #expect(Self.field(entry, "spoolId") == .string("S1"))
    }

    @Test("waste on a job with deduct off takes nothing")
    func wasteNoDeduct() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.newWasteEntry(Self.input(["deduct": .bool(false)]), id: "W1",
                                                  today: "2026-10-18", inventory: Self.shelf,
                                                  order: Self.job)
        #expect(made.entry != nil)
        #expect(made.inventory == Self.shelf)
    }

    @Test("the waste sheet hands logWaste the shop's settings and machines")
    func wasteWired() throws {
        let stock = try Self.sources("Shop+Stock.swift")
        #expect(stock.contains("settings: Self.settings(root), machines: Self.rows(root, \"machines\")"),
                "forOrder cannot pick the job's spools without them")
    }

    @Test("receiving against a deleted spool is refused, in words")
    func receiveNoItem() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("PO1"), "itemId": .string("gone"),
                                        "qty": .number(1000), "unitPrice": .number(0.08)])
        let done = try await engine.receiveGoods(order: order, item: nil, consumable: nil,
                                                 quantity: 250, notes: "", today: "2026-10-18",
                                                 expenseId: "E1", expenseLabel: "PO")
        #expect(!done.ok)
        #expect(done.reason == "no_item")
        #expect(done.expense == nil, "an expense booked for goods that landed nowhere")
        let stock = try Self.sources("Shop+Stock.swift")
        #expect(stock.contains("done.reason == \"no_item\" ? \"po.item_gone\""))
        let en = Words(); await en.load("en", engine: engine)
        let ar = Words(); await ar.load("ar", engine: engine)
        #expect(en.callIt("po.item_gone") != "po.item_gone", "the sentence has no English")
        #expect(ar.callIt("po.item_gone") != "po.item_gone", "the sentence has no Arabic")
        #expect(ar.callIt("po.item_gone") != en.callIt("po.item_gone"))
    }

    @Test("the receive button cannot fire twice while it writes")
    func receiveBusy() throws {
        let sheet = try Self.sources("ReceiveSheet.swift")
        #expect(sheet.contains("guard !busy else { return }"))
        #expect(sheet.contains(".disabled(amount <= 0 || busy)"))
        #expect(sheet.contains("busy = false"), "a refused receive left the button dead")
    }

    @Test("mark dried writes the drying log row, through the shared rule")
    func markDriedLogs() throws {
        let stock = try Self.sources("Shop+Stock.swift")
        guard let at = stock.range(of: "func markDried(") else { Issue.record("gone"); return }
        let body = String(stock[at.lowerBound...].prefix(2400))
        #expect(body.contains("FilamentDryness.recordDrying("))
        #expect(body.contains("record[\"dryingLog\"]"))

        let out = FilamentDryness.recordDrying(
            .object(["id": .string("S1"), "driedAt": .string("2026-10-18")]),
            entry: ["id": .string("DRY-1"), "date": .string("2026-10-18")])
        #expect(out.dryingLog.count == 1)
        #expect(out.driedAt == "2026-10-18")
    }
}
