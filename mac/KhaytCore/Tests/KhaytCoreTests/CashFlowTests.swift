import Foundation
import Testing
@testable import KhaytCore

/// What reached and left the bank, through the engine.
///
/// `test/cash-flow.test.js` pins the rules. What matters here is that the Mac
/// app asks them with the same money underneath — and that the correction the
/// module carries survives the trip: a deposit is the deposit.
@Suite struct CashFlowTests {

    static func order(_ id: String, price: Double, paid: Double, on day: String,
                      voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "status": .string("completed"),
            "date": .string(day), "price": .number(price),
            "paidAmount": .number(paid), "paidAt": .string(day),
        ]
        if voided { o["voidedAt"] = .string(day) }
        return .object(o)
    }

    static func run(_ engine: KhaytEngine, orders: [JSONValue],
                    expenses: [JSONValue] = [],
                    settings: [String: JSONValue] = [:]) async throws -> KhaytEngine.CashFlow {
        try await engine.cashFlow(orders: orders, expenses: expenses,
                                  endMonth: "2026-09", months: 4,
                                  settings: settings, clients: [])
    }

    /// 8.25% sales tax added on top of the price.
    static let salesTax: [String: JSONValue] = [
        "currency": .string("USD"),
        "tax": .object([
            "name": .string("Sales Tax"), "mode": .string("exclusive"),
            "rates": .array([.object(["id": .string("st"), "label": .string("Sales tax"),
                                      "percent": .number(8.25)])]),
        ]),
    ]

    /// 15% VAT already inside the price.
    static let vat15: [String: JSONValue] = [
        "currency": .string("SAR"), "enableVat": .bool(true), "vatRate": .number(15),
    ]

    @Test("the months come back oldest first, and there are as many as asked for")
    func theWindowIsTheWindow() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [])
        #expect(flow.rows.map(\.month) == ["2026-06", "2026-07", "2026-08", "2026-09"])
        #expect(flow.totals.anyMovement == false)
    }

    /// THE CORRECTION. `paidAt` is set on any payment, a deposit included, and
    /// the rule this replaces counted the job's WHOLE revenue on that day — on
    /// the one chart whose subject is money the shop actually has.
    @Test("a deposit moves the deposit, not the whole job")
    func aDepositIsTheDeposit() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            Self.order("A", price: 20000, paid: 2000, on: "2026-08-10"),
        ])
        let august = try #require(flow.rows.first { $0.month == "2026-08" })
        #expect(august.collected == 2000)
        #expect(august.collected != 20000)
    }

    @Test("a voided order is not cash, however much was paid on it")
    func voidedIsNotCash() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            Self.order("A", price: 5000, paid: 5000, on: "2026-08-01", voided: true),
            Self.order("B", price: 1000, paid: 1000, on: "2026-08-03"),
        ])
        #expect(flow.totals.collected == 1000)
    }

    @Test("what went out is counted on the day it was paid")
    func expensesGoOutWhenPaid() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            Self.order("A", price: 1000, paid: 1000, on: "2026-08-02"),
        ], expenses: [
            .object(["date": .string("2026-08-05"), "amount": .number(1400)]),
            .object(["date": .string("2026-07-05"), "amount": .number(200)]),
        ])
        let august = try #require(flow.rows.first { $0.month == "2026-08" })
        #expect(august.paidOut == 1400)
        #expect(august.net == -400)
        #expect(flow.totals.paidOut == 1600)
    }

    /// The whole reason this is not the P&L: a finished job that nobody has
    /// paid for is revenue and is not cash.
    @Test("a finished job nobody has paid for moves nothing")
    func earnedIsNotCollected() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            .object(["id": .string("A"), "status": .string("completed"),
                     "date": .string("2026-08-01"), "price": .number(9000),
                     "paidAmount": .number(0)]),
        ])
        #expect(flow.totals.collected == 0)
        #expect(flow.totals.anyMovement == false)
    }

    /// A screen needs to tell "nothing happened" from "things happened and
    /// cancelled out", and the totals alone cannot.
    @Test("a month that nets zero is not an empty month")
    func balancedIsNotEmpty() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            Self.order("A", price: 500, paid: 500, on: "2026-08-02"),
        ], expenses: [.object(["date": .string("2026-08-03"), "amount": .number(500)])])
        #expect(flow.totals.net == 0)
        #expect(flow.totals.anyMovement == true)
    }

    /// A tax-on-top shop bills 108.25 on a 100 job at 8.25%. Capping what was
    /// paid at the PRICE counted 100 of the 108.25 that reached the bank.
    @Test("tax added on top: the tax the customer paid is cash in")
    func taxOnTopIsCollected() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            Self.order("A", price: 100, paid: 108.25, on: "2026-08-10"),
        ], settings: Self.salesTax)
        #expect(abs(flow.totals.collected - 108.25) < 1e-9)
    }

    @Test("tax added on top: paying more than was billed still counts only the bill")
    func taxOnTopCapsAtTheBill() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            Self.order("A", price: 100, paid: 150, on: "2026-08-10"),
        ], settings: Self.salesTax)
        #expect(abs(flow.totals.collected - 108.25) < 1e-9)
    }

    /// Settled before #1718: `recordPayment` capped at the price, so the order
    /// holds `paidAmount == price` and `'paid'`. Cash in is what was paid.
    @Test("tax added on top: an order settled at its price before the fix counts the price")
    func settledBeforeTaxOnTopCountsWhatWasPaid() async throws {
        let engine = try KhaytEngine()
        guard case .object(var o) = Self.order("A", price: 100, paid: 100, on: "2026-08-10")
        else { return }
        o["paymentStatus"] = .string("paid")
        let flow = try await Self.run(engine, orders: [.object(o)], settings: Self.salesTax)
        #expect(flow.totals.collected == 100)
    }

    @Test("VAT inside the price: what was paid is what came in, unchanged")
    func inclusiveIsUnchanged() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            Self.order("A", price: 115, paid: 115, on: "2026-08-10"),
            Self.order("B", price: 115, paid: 200, on: "2026-08-11"),
        ], settings: Self.vat15)
        #expect(flow.totals.collected == 230)
    }

    @Test("no tax: an overpayment is still capped at the price")
    func untaxedIsUnchanged() async throws {
        let engine = try KhaytEngine()
        let flow = try await Self.run(engine, orders: [
            Self.order("A", price: 100, paid: 108.25, on: "2026-08-10"),
            Self.order("B", price: 100, paid: 40, on: "2026-08-11"),
        ])
        #expect(flow.totals.collected == 140)
    }
}
