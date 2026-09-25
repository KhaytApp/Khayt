import Foundation
import Testing
@testable import KhaytApp

/// "When adding a product the price does not update when I make changes to
/// values" (the shop, Sep 2026).
struct ProductSheetPricingTests {
    static func part(_ name: String, grams: String = "", hours: String = "") -> ProductSheet.PartRow {
        var p = ProductSheet.PartRow()
        p.name = name; p.grams = grams; p.hours = hours
        return p
    }

    @Test("a part being typed counts toward the price as soon as it has a weight or a time")
    func pendingCounts() {
        let list = [Self.part("base", grams: "50")]
        #expect(ProductSheet.pricedParts(list, pending: Self.part("lid"), editingAt: nil).count == 1,
                "an empty part is not priced")
        let priced = ProductSheet.pricedParts(list, pending: Self.part("lid", grams: "20"), editingAt: nil)
        #expect(priced.map(\.name) == ["base", "lid"], "a part being typed moves the price, and saves")
    }

    @Test("a part taken back to be edited is priced in its own place, not duplicated")
    func editedInPlace() {
        let list = [Self.part("a", grams: "1"), Self.part("c", grams: "3")]   // "b" was at index 1
        let priced = ProductSheet.pricedParts(list, pending: Self.part("b", grams: "2.5"), editingAt: 1)
        #expect(priced.map(\.name) == ["a", "b", "c"])
        #expect(priced.map(\.grams) == ["1", "2.5", "3"], "the changed figure is the one priced")
    }
}
