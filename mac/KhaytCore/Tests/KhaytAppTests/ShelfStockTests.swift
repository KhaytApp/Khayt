import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What a shop has already printed and boxed.
///
/// ── THE RULE THAT MAKES THE NUMBER SAFE TO SEND ───────────────────────────
///
/// Khayt says how many were COUNTED. A storefront says how many are LEFT,
/// because it is the thing watching orders. Re-applying Khayt's figure on
/// every poll would resurrect units somebody had already bought — so
/// `stockCountedAt` sits beside the number, and a storefront re-applies a
/// count only when that moves.
///
/// Comparing the NUMBERS is not enough, and this is the part that is easy to
/// get backwards: a shop that sells three, prints three and re-counts
/// publishes the same figure. A number comparison reads that as nothing having
/// happened and leaves the shop under-selling its own shelf.
///
/// ── AND IT IS ONE CONTRACT ACROSS TWO APPS ────────────────────────────────
///
/// `renderer/settings.js` has written these two maps since #1113. This is the
/// same book: a count typed on the Mac must be the one the other app shows,
/// and vice versa, or a shop keeps two shelves.
@MainActor
struct ShelfStockTests {

    static let when = Date(timeIntervalSince1970: 1_790_000_000)

    static func settings(_ json: String) -> [String: JSONValue] {
        let data = Data(json.utf8)
        guard let any = try? JSONSerialization.jsonObject(with: data),
              case .object(let o) = JSONValue.from(any) else { return [:] }
        return o
    }

    // MARK: - The contract

    /// The exact shape the other app writes. A rename here is a shop whose
    /// count vanishes when it opens the other app.
    @Test("the count is written where the other app looks for it")
    func oneContract() {
        var settings: [String: JSONValue] = [:]
        Shop.putStockCount(12, for: "PRD-1", into: &settings, at: Self.when)

        guard case .object(let store)? = settings["storefront"] else {
            Issue.record("no storefront block"); return
        }
        #expect(store["stockQty"] != nil, "the other app reads `stockQty`")
        #expect(store["stockCountedAt"] != nil, "the other app reads `stockCountedAt`")
        guard case .object(let counts)? = store["stockQty"],
              case .number(let n)? = counts["PRD-1"] else {
            Issue.record("the count is not keyed by product id"); return
        }
        #expect(n == 12)
        guard case .object(let when)? = store["stockCountedAt"],
              case .string(let at)? = when["PRD-1"] else {
            Issue.record("no timestamp"); return
        }
        // ISO, like every other stamp this book holds.
        #expect(at.contains("T") && at.hasSuffix("Z"), "the stamp is not ISO: \(at)")
    }

    /// EMPTY IS NOT ZERO — the other app's own words. Empty means the shop
    /// does not stock this piece and a storefront must leave its inventory
    /// alone entirely; zero means it stocks it and the batch has sold out,
    /// which is a state it reverses next week. Reading one as the other moves
    /// a customer's quoted date by weeks in whichever direction is wrong.
    @Test("zero is a count and absent is not")
    func zeroIsAValue() {
        var settings: [String: JSONValue] = [:]
        Shop.putStockCount(0, for: "PRD-1", into: &settings, at: Self.when)
        #expect(Shop.stockCount(of: "PRD-1", in: .object(settings)) == 0,
                "a counted-and-empty shelf came back as not stocked")
        #expect(Shop.stockCountedAt(of: "PRD-1", in: .object(settings)) != nil,
                "counting zero is still counting, and must be dated")

        Shop.putStockCount(nil, for: "PRD-1", into: &settings, at: Self.when)
        #expect(Shop.stockCount(of: "PRD-1", in: .object(settings)) == nil)
        #expect(Shop.stockCountedAt(of: "PRD-1", in: .object(settings)) == nil,
                "a product that is no longer stocked kept its timestamp")
    }

    /// THE ONE THAT MATTERS. Sell three, print three, count the same number —
    /// and the stamp must still move, or the storefront is told nothing
    /// happened and goes on under-selling the shelf.
    @Test("re-counting the same number still dates it")
    func theStampMovesOnTouch() {
        var settings: [String: JSONValue] = [:]
        Shop.putStockCount(12, for: "PRD-1", into: &settings, at: Self.when)
        let first = Shop.stockCountedAt(of: "PRD-1", in: .object(settings))

        Shop.putStockCount(12, for: "PRD-1", into: &settings,
                           at: Self.when.addingTimeInterval(86_400))
        let second = Shop.stockCountedAt(of: "PRD-1", in: .object(settings))

        #expect(Shop.stockCount(of: "PRD-1", in: .object(settings)) == 12)
        #expect(first != second, """
            the count was re-recorded and the date did not move — which is the \
            exact bug the date exists to fix: a shop that sells three, prints \
            three and re-counts publishes the same figure, and nothing \
            downstream learns the shelf was refilled
            """)
    }

    /// One product being counted must not disturb another. The other app
    /// rebuilds both maps from a dialog holding every product; here a single
    /// shelf is counted and the rest of the book has to be left alone.
    @Test("counting one product leaves the others exactly as they were")
    func neighboursAreUntouched() {
        var settings = Self.settings("""
        {"storefront": {"stockQty": {"PRD-A": 5, "PRD-B": 9},
                        "stockCountedAt": {"PRD-A": "2026-01-01T00:00:00Z",
                                           "PRD-B": "2026-02-02T00:00:00Z"},
                        "payUrl": "https://pay.example"}}
        """)
        Shop.putStockCount(7, for: "PRD-A", into: &settings, at: Self.when)

        #expect(Shop.stockCount(of: "PRD-A", in: .object(settings)) == 7)
        #expect(Shop.stockCount(of: "PRD-B", in: .object(settings)) == 9, "a neighbour's count moved")
        #expect(Shop.stockCountedAt(of: "PRD-B", in: .object(settings)) == "2026-02-02T00:00:00Z",
                "a neighbour's timestamp moved, so its count will be re-applied downstream")
        // And nothing else in the storefront block is lost.
        guard case .object(let store)? = settings["storefront"] else { Issue.record("gone"); return }
        #expect(store["payUrl"] != nil, "the rest of the storefront settings were dropped")
    }

    /// A negative count is not a thing a shelf can be.
    @Test("a count below zero is clamped rather than stored")
    func noNegativeShelves() {
        var settings: [String: JSONValue] = [:]
        Shop.putStockCount(-4, for: "PRD-1", into: &settings, at: Self.when)
        #expect(Shop.stockCount(of: "PRD-1", in: .object(settings)) == 0)
    }

    /// And a book that has never heard of this says so, rather than zero.
    @Test("a product nobody has counted is not zero")
    func unknownIsNotZero() {
        #expect(Shop.stockCount(of: "PRD-nope", in: .object([:])) == nil)
        #expect(Shop.stockCount(of: "PRD-nope",
                                in: .object(Self.settings("""
                                {"storefront": {"stockQty": {}}}
                                """))) == nil)
    }
}
