import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Taking a job from a product the shop already makes.
///
/// Reported from the running app: *"I click create a job for an item in
/// catalogue but the price is zero?"*
@MainActor
struct ProductToJobTests {

    /// A product whose parts carry no weight, no time and no filament.
    ///
    /// The catalogue lists it, the Take-a-job button offers it, and the sheet
    /// that opens costs it at nothing — because there is nothing to cost. The
    /// product editor says so when you are editing one ("these parts have no
    /// filament chosen, so they cost nothing"); nothing on the way from the
    /// catalogue to a job says it at all.
    @Test("a product with nothing costed produces nothing to price")
    func anUncostedProductPricesAtNothing() throws {
        // Exactly what the shop's own book holds for this product: nulls.
        let list: [JSONValue] = [.object([
            "name": .string("AquaticFlexiDragon-U1"),
            "printWeight": .null, "printTime": .null, "qty": .null,
        ])]
        let drafts = list.compactMap(NewJobSheet.Draft.from)
        #expect(drafts.count == 1, "the part came across")
        let part = try #require(drafts.first)
        #expect(!part.isComplete, """
            a part with no grams and no hours reads as complete, so the sheet \
            will price it — at zero, silently
            """)
        #expect(part.cost == 0)
    }

    /// THE ONE THE SHOP ACTUALLY HIT.
    ///
    /// `Money.quantity` is a display formatter: at a thousand and over it
    /// writes "1,234.6", and `Double("1,234.6")` is nil. So a part weighing a
    /// kilo or more read back as nothing, the part looked incomplete, nothing
    /// was costed, and a job taken from a product the catalogue prices at
    /// 3,250 opened at zero — with no error anywhere. A shop's biggest prints
    /// are exactly the ones over a kilo: the sample catalogue's two dearest
    /// products are 5,568 g and 5,404 g.
    @Test("a part of a kilo or more survives the trip into the sheet")
    func kilogramPartsSurvive() throws {
        for grams in [999.0, 1000.0, 5568.0, 12345.67] {
            let list: [JSONValue] = [.object([
                "name": .string("big"), "filamentId": .string("seed-1"),
                "printWeight": .number(grams), "printTime": .number(9),
            ])]
            let part = try #require(list.compactMap(NewJobSheet.Draft.from).first)
            #expect(Double(part.grams) != nil, """
                \(grams) g came across as "\(part.grams)", which `Double(_:)` \
                cannot parse — so the part costs nothing and the job prices at zero
                """)
            #expect(part.isComplete, "\(grams) g reads as an empty part")
        }
    }

    /// And nothing recorded stays nothing — not "0", which is a figure.
    @Test("a figure the book was never told arrives empty, not zero")
    func nullIsEmpty() throws {
        let list: [JSONValue] = [.object([
            "name": .string("x"), "printWeight": .null, "printTime": .null,
        ])]
        let part = try #require(list.compactMap(NewJobSheet.Draft.from).first)
        #expect(part.grams.isEmpty, "a field with nothing in it says \"\(part.grams)\"")
        #expect(part.hours.isEmpty)
    }

    /// And one that is costed comes across with its figures.
    @Test("a costed product carries its weight and time into the job")
    func aCostedProductCarriesItsFigures() throws {
        let list: [JSONValue] = [.object([
            "name": .string(""), "filamentId": .string("seed-1"),
            "printWeight": .number(140.91), "printTime": .number(5.25),
        ])]
        let part = try #require(list.compactMap(NewJobSheet.Draft.from).first)
        #expect(part.isComplete, "a part with 140.91 g and 5.25 h is not complete")
        #expect(part.spoolId == "seed-1")
        #expect(Double(part.grams) == 140.91)
        #expect(Double(part.hours) == 5.25)
    }
}
