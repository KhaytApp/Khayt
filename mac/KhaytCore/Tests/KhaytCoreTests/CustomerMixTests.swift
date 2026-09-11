import Foundation
import Testing
@testable import KhaytCore

/// Growing, or serving the same people — through the engine.
///
/// `test/customer-mix.test.js` pins the rules. What matters here is that the
/// corrections survive: identity is the ORDER not the day, and a customer who
/// came back is one person.
@Suite struct CustomerMixTests {

    static func job(_ id: String, _ client: String, _ date: String,
                    price: Double, status: String = "completed",
                    voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "clientId": .string(client), "date": .string(date),
            "price": .number(price), "status": .string(status),
        ]
        if voided { o["voidedAt"] = .string(date) }
        return .object(o)
    }

    static func run(_ engine: KhaytEngine, _ orders: [JSONValue],
                    from: String = "", to: String = "") async throws -> KhaytEngine.CustomerMix {
        try await engine.customerMix(orders: orders, from: from, to: to,
                                     settings: [:], clients: [])
    }

    /// THE CORRECTION. The rule this replaces compared DATES, so a customer
    /// whose first two jobs landed on one day counted as new twice.
    @Test("a new customer's second job on the same day is a returning sale")
    func sameDayIsNotTwoNewCustomers() async throws {
        let engine = try KhaytEngine()
        let mix = try await Self.run(engine, [
            Self.job("a", "c1", "2026-09-01", price: 1000),
            Self.job("b", "c1", "2026-09-01", price: 500),
        ])
        #expect(mix.fresh.jobs == 1)
        #expect(mix.fresh.revenue == 1000)
        #expect(mix.returning.revenue == 500)
    }

    /// Being new and then coming back is the best thing that can happen, and is
    /// one person.
    @Test("one customer who came back is one customer, not two")
    func returningIsNotASecondPerson() async throws {
        let engine = try KhaytEngine()
        let mix = try await Self.run(engine, [
            Self.job("a", "c1", "2026-09-01", price: 1000),
            Self.job("b", "c1", "2026-09-05", price: 500),
            Self.job("c", "c2", "2026-09-02", price: 300),
        ])
        #expect(mix.fresh.clients == 2)
        #expect(mix.returning.clients == 1)
        #expect(mix.totals.clients == 2)
    }

    @Test("delivered counts; voided does not")
    func onlyRealFinishedWork() async throws {
        let engine = try KhaytEngine()
        let mix = try await Self.run(engine, [
            Self.job("a", "c1", "2026-09-01", price: 100, status: "delivered"),
            Self.job("b", "c2", "2026-09-01", price: 900, voided: true),
            Self.job("c", "c3", "2026-09-01", price: 900, status: "printing"),
        ])
        #expect(mix.totals.jobs == 1)
        #expect(mix.totals.revenue == 100)
    }

    /// History decides who is new, so it must not be pre-filtered.
    @Test("a customer who first bought before the window is returning inside it")
    func historyDecides() async throws {
        let engine = try KhaytEngine()
        let mix = try await Self.run(engine, [
            Self.job("a", "c1", "2024-01-01", price: 5000),
            Self.job("b", "c1", "2026-09-01", price: 1000),
        ], from: "2026-09-01")
        #expect(mix.fresh.jobs == 0)
        #expect(mix.returning.revenue == 1000)
        #expect(mix.totals.revenue == 1000)
    }

    /// 0% would read as "none of your money came from new customers", a claim
    /// about a shop that simply has no finished work.
    @Test("no finished work is no split, not a split of nought")
    func nothingIsNotZero() async throws {
        let engine = try KhaytEngine()
        let mix = try await Self.run(engine, [])
        #expect(mix.fresh.shareOfRevenue == nil)
        #expect(mix.totals.firstOrderValue == nil)
    }

    /// A screen can only have been reviewed against data that reaches it.
    @Test("the sample shop reaches both halves")
    func theSampleReachesBoth() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root, case .array(let orders)? = book["printLog"] else {
            Issue.record("could not read the sample shop"); return
        }
        let engine = try KhaytEngine()
        let mix = try await Self.run(engine, orders)
        #expect(mix.fresh.jobs > 0, "no new customer, so half the card is undrawn")
        #expect(mix.returning.jobs > 0, "nobody came back, so the other half is undrawn")
    }
}
