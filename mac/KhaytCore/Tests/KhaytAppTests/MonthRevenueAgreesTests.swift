import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "One month, two revenue figures on the Mac" (Oct 2026 review): the goal
/// tile reads the KPIs, the dashboard's month figure reads the P&L, and the
/// P&L reads a job in a currency the shop does not know in its customer's
/// currency while the KPIs took the code at face value.
@MainActor
struct MonthRevenueAgreesTests {

    @Test("the KPIs and the P&L read a job in an unknown currency the same way")
    func unknownCurrencyAgrees() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let today = DateRange.localDay(now)
        let settings: [String: JSONValue] = [
            "currency": .string("SAR"),
            "exchangeRates": .object(["USD": .number(3.75)]),
        ]
        let clients: [JSONValue] = [.object(["id": .string("c1"), "name": .string("Ada"), "currency": .string("USD")])]
        let orders: [JSONValue] = [
            .object(["id": .string("o1"), "clientId": .string("c1"), "currency": .string("XYZ"),
                     "price": .number(100), "status": .string("completed"), "date": .string(today)]),
            .object(["id": .string("o2"), "price": .number(50), "status": .string("completed"),
                     "date": .string(today)]),
        ]
        let currencies: [String: JSONValue] = ["SAR": .object(["symbol": .string("SAR")]),
                                               "USD": .object(["symbol": .string("$")])]
        let kpis = try await engine.kpis(orders: orders, clients: clients, settings: settings, range: "month",
                                         language: "en", currencies: currencies)
        let rows = try await engine.pnlByPeriod(orders: orders, expenses: [], settings: settings, clients: clients,
                                                currencies: currencies, now: now, granularity: "month")
        let month = try #require(rows.first { $0.period == DateRange.localMonth(now) })
        #expect(month.revenue == 425, "100 USD at 3.75, plus 50")
        #expect(kpis.revenue == month.revenue, "goal \(kpis.revenue) vs the month's revenue \(month.revenue)")
    }

    @Test("both callers hand the KPIs the shop's currencies")
    func wired() throws {
        let shop = try LockRound3Tests.source("Shop.swift")
        #expect(shop.components(separatedBy: "currencies: Invoice.currencyTable(self))").count - 1 >= 2)
    }
}
