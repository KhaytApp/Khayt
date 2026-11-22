import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Filament bought is stock: out of expenses and net, reported beside them.
@MainActor
struct FilamentIsStockTests {
    @Test("a filament purchase reaches the Mac's P&L as inventory, not as an expense")
    func stockNotExpense() async throws {
        let shop = Shop()
        await shop.load(.sample, asOf: try #require(SampleBook.anchor))
        let engine = try #require(shop.engine)
        let expenses: [JSONValue] = [
            .object(["id": .string("E1"), "date": .string("2026-09-10"), "category": .string("filament"),
                     "amount": .number(90)]),
            .object(["id": .string("E2"), "date": .string("2026-09-10"), "category": .string("rent"),
                     "amount": .number(40)]),
        ]
        let rows = try await engine.pnlByPeriod(orders: [], expenses: expenses, settings: [:], clients: [],
                                                currencies: [:], now: Date(timeIntervalSince1970: 1_790_000_000))
        let q3 = try #require(rows.first { $0.period == "2026-Q3" })
        #expect(q3.inventory == 90)
        #expect(q3.expenses == 40)
        let reports = try QuoteSheetStatusTests.source("Reports.swift")
        #expect(reports.contains("\"pnl.inventory\""))
    }
}
