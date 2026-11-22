import Foundation
import Testing
@testable import KhaytCore

/// Which customers are worth keeping, through the engine.
///
/// `test/client-value.test.js` pins the rules. What matters here is that the
/// Mac app asks them with the same money underneath — and that the correction
/// survives the trip: a quote is not lifetime value.
@Suite struct ClientValueTests {

    static let now = Date(timeIntervalSince1970: 1_789_084_800)   // 2026-09-11

    static let clients: [JSONValue] = [
        .object(["id": .string("c1"), "name": .string("Najd Architects")]),
        .object(["id": .string("c2"), "name": .string("Asker Dental")]),
        .object(["id": .string("c3"), "name": .string("Only Ever Asks")]),
    ]

    static func order(_ client: String, _ status: String, _ day: String,
                      _ price: Double, voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(client + day), "clientId": .string(client),
            "status": .string(status), "date": .string(day), "price": .number(price),
        ]
        if voided { o["voidedAt"] = .string(day) }
        return .object(o)
    }

    static func run(_ engine: KhaytEngine, _ orders: [JSONValue],
                    limit: Int = 10) async throws -> KhaytEngine.ClientValue {
        try await engine.clientValue(clients: clients, orders: orders, now: now,
                                     quietDays: 90, limit: limit,
                                     settings: [:], language: "en")
    }

    /// The correction. The table this replaces counted every order carrying the
    /// client's id — so a customer who asked for ten quotes and bought nothing
    /// topped "lifetime value", the one place that must not reward asking.
    @Test("a quote is not lifetime value, however large")
    func aQuoteIsNotValue() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.order("c3", "quote", "2026-09-01", 90000),
            Self.order("c1", "completed", "2026-09-01", 500),
        ])
        #expect(report.rows.first?.clientId == "c1")
        #expect(report.rows.contains { $0.clientId == "c3" } == false)
        #expect(report.totals.earned == 500)
    }

    @Test("voided work and work outside the trade are worth nothing")
    func voidedIsWorthNothing() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.order("c1", "completed", "2026-09-01", 800),
            Self.order("c1", "completed", "2026-09-02", 5000, voided: true),
        ])
        #expect(report.rows.first?.value == 800)
        #expect(report.rows.first?.jobs == 1)
    }

    @Test("delivered is earned, and the average is per finished job")
    func deliveredCounts() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.order("c1", "completed", "2026-09-01", 300),
            Self.order("c1", "delivered", "2026-08-01", 700),
        ])
        let row = try #require(report.rows.first)
        #expect(row.value == 1000)
        #expect(row.jobs == 2)
        #expect(row.averageJob == 500)
    }

    /// A customer that never bought anything has not gone anywhere. Calling it
    /// churn risk fills a list a shop is meant to act on with new names.
    @Test("a customer that stopped coming back is quiet; one that never started is not")
    func quietMeansStopped() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.order("c1", "completed", "2026-09-09", 100),
            Self.order("c2", "completed", "2026-01-01", 100),
            Self.order("c3", "quote", "2026-09-01", 100),
        ])
        #expect(report.rows.first { $0.clientId == "c1" }?.quiet == false)
        #expect(report.rows.first { $0.clientId == "c2" }?.quiet == true)
        #expect(report.totals.quiet == 1)
    }

    /// A shop with 60% of its revenue in one customer has a different business
    /// from one with 6%, and the table this replaces could not say which.
    @Test("the share of revenue says how badly losing the top one would hurt")
    func concentrationIsVisible() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.order("c1", "completed", "2026-09-01", 9000),
            Self.order("c2", "completed", "2026-09-01", 1000),
        ])
        #expect(report.totals.topShare == 0.9)
        #expect(report.rows.first?.shareOfRevenue == 0.9)
    }

    @Test("agreed work not yet earned is carried apart from what has been")
    func inFlightIsApart() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.order("c1", "completed", "2026-09-01", 100),
            Self.order("c1", "printing", "2026-09-05", 4000),
            Self.order("c1", "quote", "2026-09-06", 90000),
        ])
        let row = try #require(report.rows.first)
        #expect(row.value == 100)
        #expect(row.inFlight == 4000)
    }

    @Test("the totals describe the shop, not the page")
    func totalsAreNotThePage() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.order("c1", "completed", "2026-09-01", 100),
            Self.order("c2", "completed", "2026-09-01", 900),
        ], limit: 1)
        #expect(report.rows.count == 1)
        #expect(report.totals.clients == 2)
        #expect(report.totals.earned == 1000)
    }
}
