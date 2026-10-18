import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Lot tracing on the Mac: `materialDrawn` decodes, the inspector's rows are
/// the same answer `lib/lot-trace.js` gives, and the search box finds a job by
/// the lot it drew from. Run on the SAMPLE book, which carries one job with a
/// recorded lot (ORD-01002) and one that can only be inferred (ORD-01016).
@MainActor
struct FilamentUsedTests {
    private func sample() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample, asOf: try #require(SampleBook.anchor))
        return shop
    }

    @Test("materialDrawn decodes, with its lot; a malformed one never loses the job")
    func decodes() throws {
        let json = """
        {"id":"J1","materialDrawn":{"spools":[{"spoolId":"sp-1","grams":12.5,"lot":"  L-1 ","poId":"PO-1"},
                                               {"spoolId":"sp-2","grams":3}],"consumables":[]}}
        """
        let o = try JSONDecoder().decode(Order.self, from: Data(json.utf8))
        let d = try #require(o.materialDrawn)
        #expect(d.spools.count == 2)
        #expect(d.spools[0].lot == "L-1")
        #expect(d.spools[0].poId == "PO-1")
        #expect(d.spools[1].lot == nil)

        let odd = try JSONDecoder().decode(Order.self,
            from: Data(#"{"id":"J2","materialDrawn":"junk"}"#.utf8))
        #expect(odd.materialDrawn == nil)
        let none = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"J3"}"#.utf8))
        #expect(none.materialDrawn == nil)
    }

    @Test("the sample book spans a recorded lot and an inferred one")
    func sampleRows() async throws {
        let shop = try await sample()
        let recorded = try #require(shop.orders.first { $0.id == "ORD-01002" })
        let rows = FilamentUsed.rows(for: recorded, spools: shop.spools)
        #expect(rows.count == 1, "the history line is the same draw, not a second one")
        #expect(rows.first?.lot == "GB-2406-17")
        #expect(rows.first?.inferred == false)
        #expect(rows.first?.grams == 752.84)
        #expect(rows.first?.name == "PLA+ 2.0 · Galaxy Black")

        let inferred = try #require(shop.orders.first { $0.id == "ORD-01016" })
        let old = FilamentUsed.rows(for: inferred, spools: shop.spools)
        #expect(old.contains { $0.spoolId == "sp-1" && $0.lot == "GB-2406-17" && $0.inferred })

        let untouched = try #require(shop.orders.first { order in
            !shop.spools.contains { ($0.usageHistory ?? []).contains { $0.orderId == order.id } }
                && order.materialDrawn == nil
        })
        #expect(FilamentUsed.rows(for: untouched, spools: shop.spools).isEmpty,
                "a job that drew nothing has no section")
    }

    @Test("the Swift rows are lib/lot-trace.js's lotsForJob, job by job")
    func parityWithTheRule() async throws {
        let shop = try await sample()
        let engine = try #require(shop.engine)
        var compared = 0
        for (order, row) in zip(shop.orders, shop.orderRows) {
            let swift = FilamentUsed.rows(for: order, spools: shop.spools)
                .map { "\($0.spoolId)|\($0.lot)|\($0.grams)|\($0.inferred)" }
            let js = try await engine.lotsForJob(order: row, inventory: shop.inventoryRows)
                .map { "\($0.spoolId)|\($0.lot)|\($0.grams)|\($0.inferred)" }
            #expect(swift == js, "\(order.id)")
            compared += swift.count
        }
        #expect(compared > 0, "the sample book must draw something to compare")
    }

    @Test("typing a lot in the search box finds the jobs that drew from it")
    func searchFindsLot() async throws {
        let shop = try await sample()
        shop.search = "gb-2406"
        let found = Set(shop.matching(shop.orders).map(\.id))
        #expect(found.contains("ORD-01002"))
        #expect(found.contains("ORD-01016"), "inferred from the spool's lot")
        shop.search = ""
    }

    @Test("a job found by its lot says which lot; one found by its name says nothing")
    func searchSaysWhy() async throws {
        let shop = try await sample()
        shop.search = "gb-2406"
        let why = shop.lotReasons(shop.matching(shop.orders))
        #expect(why["ORD-01002"] == "GB-2406-17", "the lot as written, not as typed")
        #expect(why["ORD-01016"] == "GB-2406-17")
        shop.search = "ord-01002"
        #expect(shop.lotReasons(shop.matching(shop.orders)).isEmpty,
                "a job found by its number needs no reason")
        shop.search = ""
        #expect(shop.lotReasons(shop.orders).isEmpty)
    }

    @Test("a recall on the sample lot lists both jobs, as CSV")
    func recall() async throws {
        let shop = try await sample()
        let engine = try #require(shop.engine)
        let r = try await engine.lotRecall(lot: " gb-2406-17 ", printLog: shop.orderRows,
                                           wasteLog: shop.wasteRows, inventory: shop.inventoryRows)
        #expect(Set(r.jobs.map(\.orderId)).isSuperset(of: ["ORD-01002", "ORD-01016"]))
        #expect(r.csv.hasPrefix("Job,Project,Client,Date,Grams,Lots,Status\n"))
    }

    @Test("receiving a different lot onto a stocked spool hands back a NEW spool")
    func receiveSplits() async throws {
        let shop = try await sample()
        let engine = try #require(shop.engine)
        let spool: JSONValue = .object(["id": .string("sp-1"), "material": .string("PLA"),
                                        "weight": .number(300), "lot": .string("OLD")])
        let po: JSONValue = .object(["id": .string("PO-1"), "qty": .number(1000), "itemId": .string("sp-1")])
        let split = try await engine.receiveGoods(order: po, item: spool, consumable: nil, quantity: 1000,
                                                  notes: "", today: "2026-10-01", expenseId: "E",
                                                  expenseLabel: "PO", lot: "NEW", newSpoolId: "INV-new")
        #expect(split.item == nil, "the old spool is untouched")
        guard case .object(let fresh)? = split.newItem else { Issue.record("no new spool"); return }
        #expect(fresh["id"] == .string("INV-new"))
        #expect(fresh["lot"] == .string("NEW"))
        #expect(fresh["weight"] == .number(1000))

        let same = try await engine.receiveGoods(order: po, item: spool, consumable: nil, quantity: 1000,
                                                 notes: "", today: "2026-10-01", expenseId: "E",
                                                 expenseLabel: "PO", lot: "old", newSpoolId: "INV-new")
        #expect(same.newItem == nil)
        guard case .object(let topped)? = same.item else { Issue.record("no spool"); return }
        #expect(topped["weight"] == .number(1300))
    }

    /// The split above, as the sample book holds it, so the screens that draw
    /// a received spool are drawn with one: PO-sample03 was raised for sp-1
    /// (lot GB-2406-17) and arrived as GB-2408-05, which became sp-14.
    @Test("the sample book holds a delivery that arrived in another lot, as its own spool")
    func sampleSplit() async throws {
        let shop = try await sample()
        let old = try #require(shop.spools.first { $0.id == "sp-1" })
        let fresh = try #require(shop.spools.first { $0.id == "sp-14" })
        #expect(old.lot == "GB-2406-17", "the spool the order was raised for keeps its lot")
        #expect(fresh.lot == "GB-2408-05")
        #expect(fresh.material == old.material)
        #expect(fresh.usageHistory?.first?.orderId == "PO-sample03")
        let po = try #require(shop.purchaseOrderRows.first {
            if case .object(let o) = $0 { return o["id"] == .string("PO-sample03") } else { return false }
        })
        guard case .object(let o) = po else { Issue.record("shape"); return }
        #expect(o["itemId"] == .string("sp-1"))
        #expect(o["receivedInto"] == .array([.string("sp-14")]))
        #expect(o["status"] == .string("received"))
    }

    @Test("a second part delivery of the same new lot tops up the spool the first one made")
    func receiveSameNewLotTwice() async throws {
        let shop = try await sample()
        let engine = try #require(shop.engine)
        let spool: JSONValue = .object(["id": .string("sp-1"), "material": .string("PLA"),
                                        "weight": .number(300), "lot": .string("A")])
        let po: JSONValue = .object(["id": .string("PO-1"), "qty": .number(1000), "itemId": .string("sp-1")])
        let first = try await engine.receiveGoods(order: po, item: spool, consumable: nil, quantity: 500,
                                                  notes: "", today: "2026-10-01", expenseId: "E",
                                                  expenseLabel: "PO", lot: "B", newSpoolId: "INV-b")
        let made = try #require(first.newItem)
        let written = try #require(first.po)
        let second = try await engine.receiveGoods(order: written, item: spool, consumable: nil, quantity: 500,
                                                   notes: "", today: "2026-10-02", expenseId: "E",
                                                   expenseLabel: "PO", lot: " b ", newSpoolId: "INV-b2",
                                                   receivedSpools: [made])
        #expect(second.newItem == nil, "no second lot-B spool")
        guard case .object(let topped)? = second.item else { Issue.record("no spool"); return }
        #expect(topped["id"] == .string("INV-b"))
        #expect(topped["weight"] == .number(1000))
        #expect(second.complete == true)
    }

    @Test("every new string is in English and Arabic")
    func strings() async throws {
        let shop = try await sample()
        for key in ["mac.filament_used", "mac.lot_inferred", "mac.lot_label", "mac.lot_copy_csv",
                    "mac.lot_copied", "mac.lot_receive_hint"] {
            #expect(shop.words.callIt(key) != key, "\(key)")
        }
    }
}
