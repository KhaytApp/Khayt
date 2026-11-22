import Foundation
import Testing
@testable import KhaytCore

/// What a shop has to bill to cover what it pays anyway, against the
/// JavaScript it came from.
///
/// This figure is a FLOOR, so the cases worth pinning are the ones where a
/// plausible reading makes it too low: no data read as no margin, and a loss
/// read as a negative target.
@MainActor
struct BreakEvenParityTests {

    private func js() throws -> JSModule { try JSModule(["break-even"]) }

    /// The same two functions on both sides: revenue is the order's `price`,
    /// and a part costs its `unitCost`. The real ones are `order-money` and
    /// `calculator-cost`, neither of which has moved.
    private func check(_ fixed: [JSONValue], _ completed: [JSONValue],
                       since: String, month: String, _ what: String,
                       _ js: JSModule) throws {
        let revenues = completed.map { order -> Double in
            guard case .object(let o) = order else { return 0 }
            return JSSemantics.number(o["price"])
        }
        let partCosts = completed.map { order -> Double in
            guard case .object(let o) = order, case .array(let parts)? = o["parts"]
            else { return 0 }
            return parts.reduce(0.0) { sum, part in
                guard case .object(let p) = part else { return sum }
                let n = JSSemantics.number(p["unitCost"])
                return sum + (n.isFinite ? n : 0)
            }
        }
        let mine = BreakEven.report(fixedCosts: fixed, completed: completed,
                                    revenues: revenues, partCosts: partCosts,
                                    since: since, month: month)
        let v = try js.value("""
            globalThis.KhaytBreakEven.breakEven(
              { fixedCosts: ARG0, completed: ARG1, since: ARG2, month: ARG3 },
              { revenueOf: function (o) { return Number(o && o.price); },
                partCostOf: function (p) { return Number(p && p.unitCost); } })
            """, [.array(fixed), .array(completed), .string(since), .string(month)])
        guard case .object(let o) = v else { Issue.record("not a report"); return }
        func maybe(_ k: String) -> Double? {
            if case .number(let n)? = o[k] { return n }; return nil
        }
        var theirCosts: [BreakEven.Cost] = []
        if case .array(let rows)? = o["costs"] {
            theirCosts = rows.map { row in
                guard case .object(let c) = row else { return .init(name: "?", amount: -1) }
                return .init(name: JSSemantics.text(c["name"]),
                             amount: JSSemantics.number(c["amount"]))
            }
        }
        let theirs = BreakEven.Report(
            totalFixed: JSSemantics.number(o["totalFixed"]),
            breakEvenRevenue: maybe("breakEvenRevenue"), marginPct: maybe("marginPct"),
            avgRevenuePerJob: maybe("avgRevenuePerJob"),
            jobsCounted: Int(JSSemantics.number(o["jobsCounted"])),
            billedThisMonth: JSSemantics.number(o["billedThisMonth"]),
            surplus: maybe("surplus"), progressPct: maybe("progressPct"),
            costs: theirCosts)
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine)
              js    \(theirs)
            """))
    }

    private func job(_ date: String, price: Double, parts: [Double] = []) -> JSONValue {
        .object(["date": .string(date), "price": .number(price),
                 "parts": .array(parts.map { .object(["unitCost": .number($0)]) })])
    }

    private let rent: [JSONValue] = [
        .object(["name": .string("Rent"), "amount": .number(4000)]),
        .object(["name": .string("Accountant"), "amount": .number(500)]),
    ]

    @Test("a real quarter, and the month so far inside it")
    func aRealQuarter() throws {
        let js = try js()
        try check(rent, [job("2026-07-04", price: 1200, parts: [220, 40]),
                         job("2026-08-19", price: 3000, parts: [640]),
                         job("2026-09-02", price: 900, parts: [130]),
                         job("2026-09-21", price: 2400, parts: [410, 55])],
                  since: "2026-07-01", month: "2026-09", "a quarter", js)
    }

    @Test("no finished work in the window answers NOTHING, not nought")
    func noDataIsNotZero() throws {
        // Zero margin renders as "you can never break even", which is a claim
        // about the shop rather than about the absence of data.
        let js = try js()
        try check(rent, [], since: "2026-07-01", month: "2026-09", "no orders", js)
        try check(rent, [job("2026-01-01", price: 900)],
                  since: "2026-07-01", month: "2026-09", "all before the window", js)
        let empty = BreakEven.report(fixedCosts: rent, completed: [], revenues: [],
                                     partCosts: [], since: "2026-07-01", month: "2026-09")
        #expect(empty.breakEvenRevenue == nil)
        #expect(empty.marginPct == nil)
        #expect(empty.totalFixed == 4500, "the costs are still known")
    }

    @Test("a window that lost money has no target, not a negative one")
    func lossesHaveNoTarget() throws {
        let js = try js()
        try check(rent, [job("2026-09-01", price: 100, parts: [400])],
                  since: "2026-01-01", month: "2026-09", "a loss", js)
        try check(rent, [job("2026-09-01", price: 0, parts: [400])],
                  since: "2026-01-01", month: "2026-09", "no revenue", js)
        try check(rent, [job("2026-09-01", price: 100, parts: [100])],
                  since: "2026-01-01", month: "2026-09", "exactly break-even work", js)
    }

    @Test("no fixed costs means no target either")
    func noFixedCosts() throws {
        let js = try js()
        for fixed: [JSONValue] in [[], [.object(["name": .string(""), "amount": .number(0)])],
                                   [.object(["name": .string("Rent")])],
                                   [.object(["amount": .number(0)])],
                                   [.null, .string("x"), .number(1)]] {
            try check(fixed, [job("2026-09-01", price: 1000, parts: [200])],
                      since: "2026-01-01", month: "2026-09", "fixed \(fixed)", js)
        }
    }

    @Test("progress is a share of the target, clamped at both ends")
    func progressIsClamped() throws {
        let js = try js()
        // Billed nothing, billed some, billed past the target.
        for month in ["2026-09", "2026-08", "2026-01", ""] {
            try check(rent, [job("2026-09-01", price: 20000, parts: [2000]),
                             job("2026-08-01", price: 500, parts: [100])],
                      since: "2026-01-01", month: month,
                      "month \(month.debugDescription)", js)
        }
    }

    @Test("dates and figures that are not what they should be")
    func degenerate() throws {
        let js = try js()
        try check([.object(["name": .number(7), "amount": .string("120")]),
                   .object(["name": .string("NaN"), "amount": .string("nope")])],
                  [.object([:]), .string("x"), .number(1), .bool(true), .array([]),
                   .object(["date": .null, "price": .string("100")]),
                   .object(["date": .number(20260901), "price": .number(100)]),
                   .object(["date": .string("2026-09-01T10:00:00Z"), "price": .number(100),
                            "parts": .string("not a list")]),
                   job("2026-09-01", price: 100, parts: [50])],
                  since: "", month: "2026-09", "a mess", js)
        // A `null` order survives on BOTH sides — `o && o.date` and
        // `order && Array.isArray(order.parts)` both short-circuit — so it is
        // compared rather than excused. Checked rather than assumed: the first
        // version of this test asserted the original threw, and it does not.
        try check([], [.null, job("2026-09-01", price: 100, parts: [50])],
                  since: "", month: "2026-09", "a null order", js)
    }
}
