import Foundation
import Testing
@testable import KhaytCore

/// Money that actually moved, against the JavaScript it came from.
///
/// The three faults the module exists for are the cases worth pinning: a
/// deposit must not bring a whole job's revenue with it, a voided order must
/// not move the line, and a job outside the shop's trade must not either.
@MainActor
struct CashFlowParityTests {

    private func js() throws -> JSModule { try JSModule(["cash-flow", "business-scope"]) }

    /// The same `revenueOf` on both sides — the real one is `order-money`,
    /// which has not moved, so the harness hands each a per-order figure from
    /// the same place: the order's own `price`.
    private func check(_ orders: [JSONValue], _ expenses: [JSONValue],
                       endMonth: String, months: Double = 6,
                       _ what: String, _ js: JSModule) throws {
        let revenues = orders.map { order -> Double in
            guard case .object(let o) = order else { return 0 }
            return JSSemantics.number(o["price"])
        }
        let mine = CashFlow.report(orders: orders, revenues: revenues, expenses: expenses,
                                   endMonth: endMonth, months: months)
        let v = try js.value("""
            globalThis.KhaytCashFlow.cashFlow(
              { orders: ARG0, expenses: ARG1, endMonth: ARG2, months: ARG3 },
              { revenueOf: function (o) { return Number(o && o.price); },
                countsForBusiness: function (o) {
                  return globalThis.KhaytBusinessScope.countsForBusiness(o);
                } })
            """, [.array(orders), .array(expenses), .string(endMonth), .number(months)])
        guard case .object(let o) = v, case .array(let rows)? = o["rows"],
              case .object(let t)? = o["totals"] else {
            Issue.record(Comment(rawValue: "\(what): not a report")); return
        }
        let theirRows: [CashFlow.Month] = rows.map { row in
            guard case .object(let r) = row else { return .init(month: "?", collected: -1,
                                                                paidOut: -1, net: -1) }
            return .init(month: JSSemantics.text(r["month"]),
                         collected: JSSemantics.number(r["collected"]),
                         paidOut: JSSemantics.number(r["paidOut"]),
                         net: JSSemantics.number(r["net"]))
        }
        var anyMovement = false
        if case .bool(let b)? = t["anyMovement"] { anyMovement = b }
        let theirs = CashFlow.Report(rows: theirRows, totals: .init(
            collected: JSSemantics.number(t["collected"]),
            paidOut: JSSemantics.number(t["paidOut"]),
            net: JSSemantics.number(t["net"]),
            anyMovement: anyMovement,
            undated: JSSemantics.number(t["undated"])))
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine)
              js    \(theirs)
            """))
    }

    private func order(price: Double, paid: Double, paidAt: JSONValue,
                       voided: Bool = false, scope: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["price": .number(price), "paidAmount": .number(paid)]
        if case .null = paidAt {} else { o["paidAt"] = paidAt }
        if voided { o["voidedAt"] = .string("2026-09-01") }
        if let scope { o["businessScope"] = .string(scope) }
        return .object(o)
    }

    /// Whether `lib/cash-flow.js` takes the shop's settings (KhaytApp/Khayt
    /// #1733). Until it does, the JavaScript still caps at the price and there
    /// is nothing to compare the tax-on-top rule against; the vectors are
    /// pinned through the engine in `CashFlowTests` either way.
    nonisolated static let libTakesSettings: Bool = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "lib/cash-flow.js")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("i.settings")
    }()

    /// 8.25% sales tax added on top of the price.
    static let salesTax: JSONValue = .object([
        "currency": .string("USD"),
        "tax": .object([
            "name": .string("Sales Tax"), "mode": .string("exclusive"),
            "rates": .array([.object(["id": .string("st"), "label": .string("Sales tax"),
                                      "percent": .number(8.25)])]),
        ]),
    ])
    static let vat15: JSONValue = .object([
        "currency": .string("SAR"), "enableVat": .bool(true), "vatRate": .number(15),
    ])

    /// THE TAX-ON-TOP CAP, both sides, on the vectors `lib/cash-flow.js` pins
    /// (test/desktop-cash-flow-tax-added.test.js): what was paid is capped at
    /// what was BILLED — `orderGrossRaw` — not at the price.
    @Test("tax on top: cash in is capped at what was billed, the same on both sides",
          .enabled(if: CashFlowParityTests.libTakesSettings,
                   "lib/cash-flow.js does not take settings yet (#1733)"))
    func taxOnTopCap() throws {
        let js = try JSModule(["tax", "order-money", "business-scope", "cash-flow"])
        let vectors: [(String, JSONValue, Double, Double, Double)] = [
            ("100 + 8.25% paid 108.25", Self.salesTax, 100, 108.25, 108.25),
            ("100 + 8.25% paid 150", Self.salesTax, 100, 150, 108.25),
            ("100 + 8.25% settled at its price before #1718", Self.salesTax, 100, 100, 100),
            ("inclusive 115 paid 115", Self.vat15, 115, 115, 115),
            ("inclusive 115 paid 200", Self.vat15, 115, 200, 115),
            ("untaxed 100 paid 150", .object([:]), 100, 150, 100),
        ]
        for (what, settings, price, paid, want) in vectors {
            let o = order(price: price, paid: paid, paidAt: .string("2026-09-02"))
            let billed = JSSemantics.number(try js.value(
                "globalThis.KhaytOrderMoney.orderGrossRaw(ARG0, { settings: ARG1 })",
                [o, settings]))
            let mine = CashFlow.report(orders: [o], revenues: [price], billed: [billed],
                                       expenses: [], endMonth: "2026-09", months: 1)
            let v = try js.value("""
                globalThis.KhaytCashFlow.cashFlow(
                  { orders: [ARG0], expenses: [], endMonth: '2026-09', months: 1, settings: ARG1 },
                  { revenueOf: function (o) { return Number(o && o.price); },
                    countsForBusiness: function () { return true; } }).totals.collected
                """, [o, settings])
            let theirs = JSSemantics.number(v)
            #expect(abs(mine.totals.collected - want) < 1e-9, Comment(rawValue: "\(what): swift \(mine.totals.collected)"))
            #expect(mine.totals.collected == theirs,
                    Comment(rawValue: "\(what): swift \(mine.totals.collected) js \(theirs)"))
        }
    }

    private func expense(_ amount: Double, _ date: JSONValue) -> JSONValue {
        .object(["amount": .number(amount), "date": date])
    }

    @Test("a deposit moves only the share it paid")
    func depositIsScaled() throws {
        // The whole reason the old version was wrong: a 10% deposit in June on
        // a 20,000 job used to put 20,000 of cash in.
        let js = try js()
        try check([order(price: 20000, paid: 2000, paidAt: .string("2026-06-12")),
                   order(price: 20000, paid: 20000, paidAt: .string("2026-07-01")),
                   order(price: 1000, paid: 0, paidAt: .string("2026-07-01")),
                   // Paid more than the price — capped at the price.
                   order(price: 500, paid: 900, paidAt: .string("2026-08-01"))],
                  [], endMonth: "2026-09", "deposits", js)
    }

    @Test("a voided order and a job outside the trade move nothing")
    func excluded() throws {
        let js = try js()
        try check([order(price: 1000, paid: 1000, paidAt: .string("2026-09-01")),
                   order(price: 1000, paid: 1000, paidAt: .string("2026-09-01"), voided: true),
                   order(price: 1000, paid: 1000, paidAt: .string("2026-09-01"),
                         scope: "personal"),
                   order(price: 1000, paid: 1000, paidAt: .string("2026-09-01"),
                         scope: "business")],
                  [], endMonth: "2026-09", "excluded", js)
    }

    @Test("money paid on a day nobody recorded is counted apart, never dropped")
    func undatedIsSeparate() throws {
        let js = try js()
        try check([order(price: 1000, paid: 1000, paidAt: .null),
                   order(price: 1000, paid: 500, paidAt: .string("")),
                   order(price: 1000, paid: 1000, paidAt: .number(0)),
                   order(price: 1000, paid: 1000, paidAt: .string("2026-09-01"))],
                  [], endMonth: "2026-09", "undated", js)
        let report = CashFlow.report(orders: [order(price: 1000, paid: 1000, paidAt: .null)],
                                     revenues: [1000], expenses: [], endMonth: "2026-09")
        #expect(report.totals.undated == 1000)
        #expect(report.totals.collected == 0, "an unplaceable figure reached the timeline")
        #expect(report.totals.anyMovement == false)
    }

    @Test("a payment outside the window is not folded into an end month")
    func outsideTheWindow() throws {
        let js = try js()
        try check([order(price: 100, paid: 100, paidAt: .string("2020-01-01")),
                   order(price: 100, paid: 100, paidAt: .string("2030-01-01")),
                   order(price: 100, paid: 100, paidAt: .string("2026-04-30")),
                   order(price: 100, paid: 100, paidAt: .string("2026-09-30"))],
                  [expense(50, .string("2020-01-01")), expense(50, .string("2026-09-02"))],
                  endMonth: "2026-09", "outside", js)
    }

    @Test("the window itself, including the ones that are not windows")
    func windows() throws {
        let js = try js()
        for (end, count) in [("2026-09", 6.0), ("2026-01", 3.0), ("2026-12", 12.0),
                             ("2026-09", 0.0), ("2026-09", -1.0), ("2026-09", 1.0),
                             ("", 6.0), ("2026-9", 6.0), ("nope", 6.0),
                             ("2026-09-01", 6.0), ("2026-13", 2.0)] {
            try check([order(price: 100, paid: 100, paidAt: .string("2026-09-01"))],
                      [expense(10, .string("2026-08-15"))],
                      endMonth: end, months: count,
                      "\(end.debugDescription) × \(count)", js)
        }
        // A year boundary counted backwards.
        #expect(CashFlow.monthsEnding("2026-02", count: 4) == ["2025-11", "2025-12",
                                                               "2026-01", "2026-02"])
    }

    @Test("dates and amounts that are not what they should be")
    func degenerate() throws {
        let js = try js()
        try check([.null, .string("x"), .number(1), .bool(true), .array([]), .object([:]),
                   order(price: 100, paid: 100, paidAt: .string("2026-09")),
                   order(price: 0, paid: 100, paidAt: .string("2026-09-01")),
                   order(price: -100, paid: -50, paidAt: .string("2026-09-01"))],
                  [.null, .string("x"), .object([:]),
                   expense(10, .null), expense(10, .string("2026-09")),
                   .object(["amount": .string("20"), "date": .string("2026-09-04")]),
                   .object(["amount": .string("nope"), "date": .string("2026-09-04")])],
                  endMonth: "2026-09", "a mess", js)
    }
}
