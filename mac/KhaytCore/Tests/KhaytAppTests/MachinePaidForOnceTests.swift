import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A machine is paid for once — as its depreciation. Its purchase, recorded as
/// an expense as well, is left out of the Mac's expenses and net and shown
/// beside them as "Equipment bought (depreciated)".
@MainActor
struct MachinePaidForOnceTests {
    @Test("a depreciated printer's purchase reaches the Mac's P&L as capital, not as an expense")
    func purchaseIsNotAnExpense() async throws {
        let shop = Shop()
        await shop.load(.sample, asOf: try #require(SampleBook.anchor))
        let engine = try #require(shop.engine)
        let machines: [JSONValue] = [
            .object(["id": .string("M1"), "name": .string("X1C"),
                     "depreciation": .object(["price": .number(6000), "purchaseDate": .string("2026-07-01"),
                                              "life": .number(3), "lifeUnit": .string("years"),
                                              "method": .string("straightLine")])]),
        ]
        let expenses: [JSONValue] = [
            .object(["id": .string("E1"), "date": .string("2026-07-01"), "category": .string("tools"),
                     "amount": .number(6000), "note": .string("Bambu X1C printer")]),
            .object(["id": .string("E2"), "date": .string("2026-07-10"), "category": .string("other"),
                     "amount": .number(40)]),
        ]
        let rows = try await engine.pnlByPeriod(orders: [], expenses: expenses, settings: [:], clients: [],
                                                currencies: [:], now: Date(timeIntervalSince1970: 1_790_000_000),
                                                machines: machines)
        let q3 = try #require(rows.first { $0.period == "2026-Q3" })
        #expect(q3.capital == 6000)
        #expect(q3.expenses == 40)
        #expect((q3.depreciation ?? 0) > 0)

        // Without the machine's depreciation the purchase is the only place
        // its cost reaches the P&L, so it stays an expense.
        let plain = try await engine.pnlByPeriod(orders: [], expenses: expenses, settings: [:], clients: [],
                                                 currencies: [:], now: Date(timeIntervalSince1970: 1_790_000_000))
        let p3 = try #require(plain.first { $0.period == "2026-Q3" })
        #expect(p3.capital == 0)
        #expect(p3.expenses == 6040)

        let reports = try QuoteSheetStatusTests.source("Reports.swift")
        #expect(reports.contains("\"pnl.capital\""))
        #expect(Shop.expenseCategories.contains("equipment"))
        #expect(shop.words.callIt("pnl.capital") == "Equipment bought (depreciated)"
                || shop.words.callIt("pnl.capital") == "معدات مشتراة (تُستهلك)")
    }
}
