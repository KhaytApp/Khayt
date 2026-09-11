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
                    expenses: [JSONValue] = []) async throws -> KhaytEngine.CashFlow {
        try await engine.cashFlow(orders: orders, expenses: expenses,
                                  endMonth: "2026-09", months: 4,
                                  settings: [:], clients: [])
    }

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
}
