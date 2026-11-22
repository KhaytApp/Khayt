import Foundation
import Testing
@testable import KhaytCore

/// What each machine earned, through the engine.
///
/// `test/machine-pl.test.js` pins the arithmetic. What matters here is that
/// this app asks the same rule with the SAME money underneath it: revenue from
/// `order-money` and part cost from `calculator-cost`, so a machine's share of
/// a quarter cannot disagree with the quarter.
@Suite struct MachineProfitTests {

    static func job(_ id: String, machine: String, price: Double, grams: Double = 0) -> JSONValue {
        .object([
            "id": .string(id), "status": .string("completed"),
            "date": .string("2026-09-01"), "machineId": .string(machine),
            "price": .number(price), "paidAmount": .number(price),
            "parts": .array([.object([
                "id": .string("p-" + id), "name": .string("Part"),
                "material": .string("PLA"), "qty": .number(1),
                "printWeight": .number(grams), "baseCost": .number(grams / 10),
                "unitCost": .number(0), "colour": .string("#fff"),
            ])]),
        ])
    }

    @Test("a machine's net is its revenue less what it spent")
    func theNetIsTheNet() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.machineProfit(
            machines: [.object(["id": .string("M1"), "name": .string("U1"),
                                "color": .string("#112233")])],
            completed: [Self.job("a", machine: "M1", price: 1000, grams: 500)],
            expenses: [.object(["orderId": .string("a"), "amount": .number(120)])],
            maintenance: [.object(["machineId": .string("M1"), "cost": .number(80)])],
            settings: [:], clients: [], unassigned: "Unassigned")

        let row = try #require(report.rows.first)
        #expect(row.name == "U1")
        #expect(row.jobs == 1)
        #expect(row.revenue == 1000)
        #expect(row.linkedExpenses == 120)
        #expect(row.maintenance == 80)
        // The totals are the rows, so a screen cannot show a sum that is not
        // in the table above it.
        #expect(report.totals.net == row.net)
    }

    /// Zero would read as "broke even". The truth is that there is no answer,
    /// and the screen has to be able to tell those apart.
    @Test("a machine that earned nothing has no margin, not a margin of zero")
    func noRevenueMeansNoMargin() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.machineProfit(
            machines: [.object(["id": .string("M1"), "name": .string("U1")])],
            completed: [Self.job("a", machine: "M1", price: 0, grams: 400)],
            expenses: [], maintenance: [],
            settings: [:], clients: [], unassigned: "Unassigned")
        #expect(try #require(report.rows.first).marginPct == nil)
    }

    /// Money the shop earned on work that names no machine — or names one that
    /// has since been deleted. Dropping it makes the machine rows fail to add
    /// up to the shop's own P&L, and the difference is invisible.
    @Test("work with no machine is its own row and is named")
    func unassignedIsShown() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.machineProfit(
            machines: [.object(["id": .string("M1"), "name": .string("U1")])],
            completed: [Self.job("a", machine: "M1", price: 100),
                        Self.job("b", machine: "", price: 400),
                        Self.job("c", machine: "DELETED", price: 250)],
            expenses: [], maintenance: [],
            settings: [:], clients: [], unassigned: "Unassigned")
        let none = try #require(report.rows.first { $0.machineId == "__none__" })
        #expect(none.jobs == 2, "a job naming a deleted machine was lost")
        #expect(none.name == "Unassigned", "the row has no words on it")
        #expect(report.totals.revenue == 750)
    }

    /// The sample book is what the screen is designed against, so what it can
    /// show is worth pinning: this page draws something rather than an empty
    /// state, which is the trap that shipped Colour Studio looking unfinished.
    @Test("the sample shop has machines that earned, so the page is not designed empty")
    func theSampleReachesIt() async throws {
        let engine = try KhaytEngine()
        let sample = BundledLogicIsNotAForkTests.repoRoot
            .appending(path: "mac/KhaytCore/Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: sample))
        guard case .object(let book) = root,
              case .array(let orders)? = book["printLog"],
              case .array(let fleet)? = book["machines"] else {
            Issue.record("the sample book moved"); return
        }
        let done = orders.filter {
            if case .object(let o) = $0, case .string(let s)? = o["status"] { return s == "completed" }
            return false
        }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = book["settings"] { settings = s }
        let report = try await engine.machineProfit(
            machines: fleet, completed: done, expenses: [], maintenance: [],
            settings: settings, clients: [], unassigned: "Unassigned")
        #expect(!report.rows.isEmpty, "the sample cannot reach this screen")
        #expect(report.totals.revenue > 0)
    }
}
