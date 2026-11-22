import Foundation
import Testing
@testable import KhaytCore

/// The five reports #1718 left counting tax as revenue: forecast, customer mix,
/// client value, cost trends and client sources.
///
/// Each asked `orderNetRevenueBase` — what the customer was CHARGED — so on a
/// 15% VAT-inclusive shop a job charged 115 read as 115 of revenue where the
/// P&L says 100. They ask `orderEarnedBase` now, which is mode-aware: on a shop
/// that adds tax on top, the price typed IS the net figure and is unchanged.
/// Cash flow is not here on purpose — the tax is cash the shop holds.
@Suite struct ReportsNetOfTaxTests {

    static let vat15 = MoneyTaxFixesTests.vat15
    static let salesTax = MoneyTaxFixesTests.salesTax

    static let client: JSONValue = .object([
        "id": .string("c1"), "name": .string("Sara"), "source": .string("instagram"),
    ])

    /// One finished August job for `c1`.
    static func job(price: Double) -> JSONValue {
        .object([
            "id": .string("j1"), "status": .string("completed"), "clientId": .string("c1"),
            "date": .string("2026-08-15"), "completedAt": .string("2026-08-15T10:00:00Z"),
            "price": .number(price), "paidAmount": .number(price),
            "parts": .array([.object(["printTime": .number(2), "qty": .number(1)])]),
        ])
    }

    /// Mid-September, local time: August is the last whole month.
    static let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 15; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    /// (settings, price typed, what the shop earned)
    static let cases: [([String: JSONValue], Double, Double)] = [
        (vat15, 115, 100),      // the 15 inside is VAT, not revenue
        (salesTax, 100, 100),   // the 8.25 on top was never in the price
    ]

    @Test("forecast: the months behind the projection are net of tax")
    func forecast() async throws {
        let engine = try KhaytEngine()
        for (settings, price, earned) in Self.cases {
            let outlook = try await engine.revenueOutlook(
                orders: [Self.job(price: price)], clients: [Self.client], settings: settings,
                now: Self.now.timeIntervalSince1970 * 1000)
            #expect(outlook.history.map(\.revenue).reduce(0, +) == earned)
        }
    }

    @Test("customer mix: a new customer's revenue is net of tax")
    func customerMix() async throws {
        let engine = try KhaytEngine()
        for (settings, price, earned) in Self.cases {
            let mix = try await engine.customerMix(orders: [Self.job(price: price)],
                                                   from: "2026-08-01", to: "2026-08-31",
                                                   settings: settings, clients: [Self.client])
            #expect(mix.totals.revenue == earned)
            #expect(mix.fresh.revenue == earned)
        }
    }

    @Test("client value: lifetime value is net of tax")
    func clientValue() async throws {
        let engine = try KhaytEngine()
        for (settings, price, earned) in Self.cases {
            let report = try await engine.clientValue(
                clients: [Self.client], orders: [Self.job(price: price)], now: Self.now,
                quietDays: 90, limit: 10, settings: settings, language: "en")
            #expect(try #require(report.rows.first).value == earned)
            #expect(report.totals.earned == earned)
        }
    }

    @Test("cost trends: a month's revenue is net of tax")
    func costTrends() async throws {
        let engine = try KhaytEngine()
        for (settings, price, earned) in Self.cases {
            let trends = try await engine.costTrends(
                orders: [Self.job(price: price)], spools: [], settings: settings,
                clients: [Self.client], now: Self.now)
            #expect(trends.months.map(\.revenue).reduce(0, +) == earned)
        }
    }

    @Test("client sources: a source's revenue is net of tax")
    func clientSources() async throws {
        let engine = try KhaytEngine()
        for (settings, price, earned) in Self.cases {
            let sources = try await engine.clientSources(
                clients: [Self.client], orders: [Self.job(price: price)], settings: settings)
            #expect(sources.totalRevenue == earned)
        }
    }
}
