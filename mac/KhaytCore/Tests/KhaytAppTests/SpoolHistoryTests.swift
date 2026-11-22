import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Where a spool went — a record both apps write and only one has drawn.
///
/// Every deduction appends to `usageHistory`. The other app has shown it since
/// it was added; this one held the record and could not read it. That is the
/// third instance of the same shape found in two days — the marketing opt-out
/// was a field read and not writable, the campaign log one written and not
/// readable, and this is the second of those.
@MainActor
struct SpoolHistoryTests {

    static func sampleSpools() async -> [Spool] {
        let shop = Shop()
        await shop.load(.sample)
        return shop.spools
    }

    @Test("the sample reaches a spool that has been printed with AND one that has not")
    func theSampleSpansBoth() async {
        // Without both, one branch of the screen has never been drawn — the
        // empty state or the list. `sample-data-must-span-its-cases`.
        let spools = await Self.sampleSpools()
        #expect(spools.contains { !($0.usageHistory ?? []).isEmpty },
                "no sample spool has been printed with, so the list is never drawn")
        #expect(spools.contains { ($0.usageHistory ?? []).isEmpty },
                "every sample spool has history, so the empty state is never drawn")
    }

    @Test("the total is the sum of what was taken, not the spool's own weight")
    func theTotal() async throws {
        let spools = await Self.sampleSpools()
        let used = try #require(spools.first { !($0.usageHistory ?? []).isEmpty })
        let expected = (used.usageHistory ?? []).filter { !$0.isReceipt }.reduce(0) { $0 + $1.weightUsed }
        #expect(used.totalUsed == expected)
        #expect(used.totalUsed > 0)
        // And it is NOT what is left on the spool — a screen that showed the
        // remaining weight under "used altogether" would be believed.
        #expect(used.totalUsed != used.weight)
    }

    @Test("the total under the rows is what the rows on screen add up to")
    func theTotalAddsUp() async throws {
        // A sample spool showed 298 g and 79 g over a total of 376 g: the
        // rows were rounded one by one and the total once.
        for spool in await Self.sampleSpools() where !(spool.usageHistory ?? []).isEmpty {
            let shown = (spool.usageHistory ?? []).filter { !$0.isReceipt }
                .reduce(0) { $0 + $1.weightUsed.rounded() }
            #expect(SpoolHistorySheet.shownTotal(spool, places: 0) == shown, "\(spool.id)")
        }
    }

    @Test("an entry survives the shapes the book actually holds")
    func decodesLoosely() throws {
        // Written by the deduction chain in two apps over two years; a row
        // missing a field is not a row to refuse, because refusing it loses
        // plastic the shop really spent.
        let rows: [JSONValue] = [
            .object(["date": .string("2026-09-17"), "project": .string("Portrait"),
                     "orderId": .string("INV-2026-0001"), "weightUsed": .number(141)]),
            .object(["orderId": .string("ORD-9"), "weightUsed": .number(12)]),   // no date, no project
            .object(["date": .string("2026-01-01")]),                            // nothing taken
        ]
        let spool = try JSONDecoder().decode(Spool.self, from: JSONEncoder().encode(
            JSONValue.object(["id": .string("SP-X"), "material": .string("PLA"),
                              "usageHistory": .array(rows)])))
        #expect((spool.usageHistory ?? []).count == 3, "a row with a missing field was dropped")
        #expect(spool.totalUsed == 153)
        #expect(spool.usageHistory?[1].date.isEmpty == true)
    }

    @Test("two equal deductions on one day for one job are two rows, not one")
    func rowsAreKeyedByPosition() throws {
        // The book writes no id. A key built from the row — date, job, grams —
        // REPEATS for two equal draws on one day, and SwiftUI drew them as one.
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/SpoolHistorySheet.swift"),
            encoding: .utf8)
        #expect(sheet.contains("ForEach(Array(uses.enumerated()), id: \\.offset)"),
                "the rows are keyed by something that can repeat")
        let spool = try JSONDecoder().decode(Spool.self, from: JSONEncoder().encode(
            JSONValue.object(["id": .string("SP-Y"), "material": .string("PLA"),
                              "usageHistory": .array([
                                .object(["date": .string("2026-09-01"), "orderId": .string("O1"),
                                         "weightUsed": .number(40)]),
                                .object(["date": .string("2026-09-01"), "orderId": .string("O1"),
                                         "weightUsed": .number(40)])])])))
        #expect(spool.usageHistory?.count == 2)
        #expect(spool.totalUsed == 80, "a reprint on the same day vanished from the total")
    }

    @Test("a receipt is shown but is not counted as use")
    func receiptsAreNotUse() throws {
        // The history is what LEFT the spool, so a delivery is a NEGATIVE row.
        // Added in, 1000 g received and 300 g used read as "-700 g".
        let spool = try JSONDecoder().decode(Spool.self, from: JSONEncoder().encode(
            JSONValue.object(["id": .string("SP-R"), "material": .string("PLA"),
                              "usageHistory": .array([
                                .object(["date": .string("2026-09-02"), "orderId": .string("O1"),
                                         "weightUsed": .number(300.4)]),
                                .object(["date": .string("2026-09-01"), "orderId": .string("PO-1"),
                                         "type": .string("received"),
                                         "weightUsed": .number(-1000)])])])))
        #expect(spool.usageHistory?.count == 2, "the receipt row is no longer shown")
        #expect(spool.totalUsed == 300.4)
        #expect(SpoolHistorySheet.shownTotal(spool, places: 0) == 300)
    }

    @Test("the sheet is presented, and offered only when there is something to show")
    func wired() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"),
                                encoding: .utf8)
        #expect(window.contains("SpoolHistorySheet(shop: shop, spool: $0)"),
                "the sheet exists and is never presented")
        let floor = try String(contentsOf: sources.appending(path: "ShopFloor.swift"),
                               encoding: .utf8)
        #expect(floor.contains("shop.spoolHistoryFor = spool"), "there is no way to open it")
        #expect(floor.contains("!(spool.usageHistory ?? []).isEmpty"), Comment(rawValue:
            "the menu item is offered on a spool with no history, and an empty sheet "
            + "teaches a shop the feature does nothing"))
    }
}
