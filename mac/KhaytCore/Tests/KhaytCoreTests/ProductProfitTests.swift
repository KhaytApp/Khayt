import Foundation
import Testing
@testable import KhaytCore

/// Which products actually earn, through the engine.
///
/// `test/product-profit.test.js` pins the rules. What matters here is that the
/// two corrections survive the trip: delivered work counts, and the ranking is
/// by profit rather than by revenue.
@Suite struct ProductProfitTests {

    static let products: [JSONValue] = [
        .object(["id": .string("p1"), "name": .string("Big slow thing")]),
        .object(["id": .string("p2"), "name": .string("Small quick thing")]),
    ]

    /// `calculator-cost` prices a part from the SPOOL, so the fixture carries
    /// one — a `baseCost` field would be ignored and every margin would be 100%.
    static func job(_ id: String, _ product: String?, _ status: String,
                    price: Double, cost: Double, hours: Double,
                    voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "status": .string(status),
            "date": .string("2026-09-01"), "price": .number(price),
            "parts": .array([.object([
                "id": .string("pt" + id), "material": .string("PLA"), "qty": .number(1),
                "printWeight": .number(100), "printTime": .number(hours),
                "spoolWeight": .number(1000), "spoolCost": .number(cost * 10),
                "colour": .string("#fff"),
            ])]),
        ]
        if let product { o["productId"] = .string(product) }
        if voided { o["voidedAt"] = .string("2026-09-02") }
        return .object(o)
    }

    static func run(_ engine: KhaytEngine, _ orders: [JSONValue],
                    expenses: [JSONValue] = []) async throws -> KhaytEngine.ProductProfit {
        try await engine.productProfit(orders: orders, products: products,
                                       expenses: expenses, untagged: "Untagged",
                                       settings: [:], clients: [], language: "en")
    }

    /// The row a shop opens this table to find is the big seller that earns
    /// nothing — and ranking by revenue puts it at the top looking like the
    /// best thing in the shop.
    @Test("rows are ranked by what they earn, not by what they bill")
    func rankedByProfit() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("1", "p1", "completed", price: 10000, cost: 9800, hours: 40),
            Self.job("2", "p2", "completed", price: 2000, cost: 200, hours: 4),
        ])
        #expect(report.rows.first?.productId == "p2")
        #expect(report.rows.first?.profit == 1800)
    }

    /// A print shop's constraint is the hours its printers can run.
    @Test("profit per machine hour is reported, and it reorders the answer")
    func perHourReorders() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("1", "p1", "completed", price: 5000, cost: 2000, hours: 40),
            Self.job("2", "p2", "delivered", price: 800, cost: 100, hours: 2),
            Self.job("3", "p2", "delivered", price: 800, cost: 100, hours: 2),
        ])
        #expect(report.rows.first?.productId == "p1", "p1 earns the most in total")
        #expect(report.totals.bestPerHour?.productId == "p2", "p2 earns the most per hour")
        #expect(try #require(report.rows.first?.profitPerHour)
                < #require(report.totals.bestPerHour?.profitPerHour))
    }

    /// The same mistake the quote funnel made, in a second place.
    @Test("delivered work counts, so a product does not vanish once it ships")
    func deliveredCounts() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("1", "p1", "delivered", price: 1000, cost: 400, hours: 5),
            Self.job("2", "p1", "completed", price: 1000, cost: 400, hours: 5),
        ])
        #expect(report.rows.first?.jobs == 2)
        #expect(report.rows.first?.revenue == 2000)
    }

    @Test("unfinished and voided work is not in the table")
    func onlyFinishedWork() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("1", "p1", "printing", price: 9000, cost: 10, hours: 5),
            Self.job("2", "p1", "completed", price: 9000, cost: 10, hours: 5, voided: true),
            Self.job("3", "p1", "completed", price: 100, cost: 10, hours: 1),
        ])
        #expect(report.rows.first?.jobs == 1)
        #expect(report.rows.first?.revenue == 100)
    }

    @Test("an expense booked against a job is part of that product's cost")
    func linkedExpensesCount() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine,
            [Self.job("1", "p1", "completed", price: 1000, cost: 0, hours: 5)],
            expenses: [.object(["orderId": .string("1"), "amount": .number(300)]),
                       .object(["orderId": .string("other"), "amount": .number(5000)])])
        #expect(report.rows.first?.cost == 300)
        #expect(report.rows.first?.profit == 700)
    }

    @Test("work naming no product is collected under one name, not dropped")
    func untaggedIsKept() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("1", nil, "completed", price: 500, cost: 100, hours: 2),
        ])
        #expect(report.rows.first?.name == "Untagged")
        #expect(report.rows.first?.revenue == 500)
    }

    /// A screen can only have been reviewed against data that reaches it.
    @Test("the sample shop reaches this table, with more than one product in it")
    func theSampleReachesIt() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root,
              case .array(let orders)? = book["printLog"],
              case .array(let catalogue)? = book["products"] else {
            Issue.record("could not read the sample shop"); return
        }
        let engine = try KhaytEngine()
        let report = try await engine.productProfit(
            orders: orders, products: catalogue, expenses: [], untagged: "Untagged",
            settings: [:], clients: [], language: "en")
        #expect(report.rows.count > 1, "one row is not a comparison")
        #expect(report.totals.bestPerHour != nil, "no product has recorded hours")
    }
}
