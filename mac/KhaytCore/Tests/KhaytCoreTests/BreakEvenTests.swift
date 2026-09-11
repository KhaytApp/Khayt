import Foundation
import Testing
@testable import KhaytCore

/// What a shop has to bill to cover what it pays anyway, through the engine.
///
/// `test/break-even.test.js` pins the arithmetic. What matters here is that the
/// Mac app asks it with the SAME money underneath: `order-money` for what a job
/// earned, `calculator-cost` for what it cost — so a break-even target cannot
/// disagree with the quarter it is drawn beside.
@Suite struct BreakEvenTests {

    /// `cost` is what the part must come out at. `calculator-cost` prices a
    /// part from the SPOOL — `spoolCost / spoolWeight * printWeight` — and not
    /// from a `baseCost` field, which is what a first draft of this fixture
    /// set and why it asserted a 100% margin against arithmetic that was right.
    static func job(_ date: String, price: Double, grams: Double, cost: Double) -> JSONValue {
        .object([
            "id": .string("J-" + date), "status": .string("completed"),
            "date": .string(date), "price": .number(price), "paidAmount": .number(price),
            "parts": .array([.object([
                "id": .string("p1"), "name": .string("Part"), "material": .string("PLA"),
                "qty": .number(1), "printWeight": .number(grams),
                "spoolWeight": .number(1000), "spoolCost": .number(cost * 1000 / max(grams, 1)),
                "colour": .string("#fff"),
            ])]),
        ])
    }

    @Test("the target is the fixed costs over what is left of each riyal")
    func theTargetIsTheTarget() async throws {
        let engine = try KhaytEngine()
        let result = try await engine.breakEven(
            fixedCosts: [.object(["name": .string("Rent"), "amount": .number(3000)])],
            completed: [Self.job("2026-09-01", price: 1000, grams: 100, cost: 250)],
            since: "2026-01-01", month: "2026-09", settings: [:], clients: [])
        #expect(result.totalFixed == 3000)
        #expect(result.marginPct == 0.75)
        #expect(result.breakEvenRevenue == 4000)
        #expect(result.billedThisMonth == 1000)
        #expect(result.surplus == -3000)
    }

    /// Nulls, not zeroes. A shop with no finished work has an UNKNOWN margin,
    /// and zero would render as "you can never break even" — a statement about
    /// the shop rather than about the absence of data.
    @Test("no finished work is no answer, not an answer of nought")
    func nothingKnownIsNotZero() async throws {
        let engine = try KhaytEngine()
        let result = try await engine.breakEven(
            fixedCosts: [.object(["name": .string("Rent"), "amount": .number(3000)])],
            completed: [], since: "2026-01-01", month: "2026-09",
            settings: [:], clients: [])
        #expect(result.breakEvenRevenue == nil)
        #expect(result.marginPct == nil)
        #expect(result.progressPct == nil)
        // And the fixed costs are still known, so the screen still has
        // something true to draw.
        #expect(result.totalFixed == 3000)
        #expect(result.costs.count == 1)
    }

    /// The correction this module carries. The rule it replaced skipped any
    /// part with no spool linked, so the margin came out too high and the
    /// target too LOW — a shop told to bill less than it must.
    @Test("the work is costed through calculator-cost, so the target cannot be too low")
    func everyPartCosts() async throws {
        let engine = try KhaytEngine()
        let costed = try await engine.breakEven(
            fixedCosts: [.object(["name": .string("Rent"), "amount": .number(1000)])],
            completed: [Self.job("2026-09-01", price: 1000, grams: 100, cost: 500)],
            since: "2026-01-01", month: "2026-09", settings: [:], clients: [])
        let free = try await engine.breakEven(
            fixedCosts: [.object(["name": .string("Rent"), "amount": .number(1000)])],
            completed: [Self.job("2026-09-01", price: 1000, grams: 100, cost: 0)],
            since: "2026-01-01", month: "2026-09", settings: [:], clients: [])
        #expect(try #require(costed.breakEvenRevenue) > #require(free.breakEvenRevenue),
                "costing the work must raise the target, never lower it")
    }

    /// A screen can only have been reviewed against data that reaches it.
    @Test("the sample shop can reach this screen")
    func theSampleReachesIt() async throws {
        // From the checkout, not a bundle: this is a KhaytCore test and the
        // sample shop is a KhaytApp resource.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root, case .object(let settings)? = book["settings"],
              case .array(let costs)? = settings["fixedCosts"] else {
            Issue.record("the sample shop has no fixed costs, so this screen only ever draws its empty state")
            return
        }
        #expect(costs.count >= 2)
    }
}
