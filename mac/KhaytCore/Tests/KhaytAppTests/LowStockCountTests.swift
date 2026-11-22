import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's real book, Sep 2026: three spools at 859 g, 1000 g and 1000 g,
/// threshold 200 g. The sidebar said ▼3 beside Inventory and the dashboard
/// tinted all three as low. Nothing was low; the screens counted the rule's
/// `[id: Bool]` answer by its entries rather than by its trues.
@MainActor
struct LowStockCountTests {

    @Test("a shelf of full spools has nothing low, and a spool under the threshold is the only one")
    func onlyTheLowOnesCount() async throws {
        let engine = try KhaytEngine()
        let shelf: [JSONValue] = [
            .object(["id": .string("a"), "material": .string("PLA+ 2.0"), "weight": .number(859)]),
            .object(["id": .string("b"), "material": .string("Sunlu PETG"), "weight": .number(1000)]),
            .object(["id": .string("c"), "material": .string("Sunlu TPU"), "weight": .number(150)]),
        ]
        let answer = try await engine.lowStock(shelf, settings: ["lowStockThreshold": .number(200)])
        #expect(answer.count == 3, "the rule answers for every spool — which is the trap")
        let low = Set(answer.filter(\.value).keys)
        #expect(low == ["c"])
    }

    @Test("the sidebar and the dashboard read the low ones, not every spool")
    func screensReadTheSet() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.lowSpools.count < shop.spools.count,
                "every sample spool counted as low — the badge is counting entries again")
        #expect(shop.lowSpools.allSatisfy { id in shop.spools.contains { $0.id == id } })
    }
}
