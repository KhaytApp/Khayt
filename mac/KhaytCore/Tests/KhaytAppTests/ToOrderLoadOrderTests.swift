import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The offer to order is built from the jobs, so it must be built after them.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// How much to reorder comes from how fast a spool is going, which comes from
/// the shop's finished jobs. The first version of this asked the rule BEFORE
/// `orderRows` was read, so the first load of a book answered from an empty
/// job list and a later one answered from a full one — the same shelf offering
/// a different count depending on when you looked.
///
/// Nothing failed: both answers are plausible small numbers.
@MainActor
struct ToOrderLoadOrderTests {

    @Test("the same book offers the same count twice running")
    func theOfferIsStable() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let first = shop.needsOrdering.map(\.id).sorted()
        await shop.load(.sample)
        let second = shop.needsOrdering.map(\.id).sorted()
        #expect(first == second,
                "the first load answered from a different book than the second: \(first) vs \(second)")
    }

    @Test("what is offered is what the rule says, given the whole book")
    func theOfferMatchesTheRule() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let direct = try await engine.needsOrdering(
            spools: shop.inventoryRows, consumables: shop.consumableRows,
            orders: shop.orderRows, purchaseOrders: shop.purchaseOrderRows,
            settings: shop.settingsDict, now: Date())
        #expect(shop.needsOrdering.map(\.id).sorted() == direct.map(\.id).sorted(),
                "the screen and the rule disagree about what to order")
    }
}
