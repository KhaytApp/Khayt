import Foundation
import Testing
@testable import KhaytCore

/// The catalogue ranked by profit per printer hour, through the engine.
///
/// `test/profit-per-hour.test.js` pins the rule. What matters here is that it
/// survives the trip into JavaScriptCore with its neighbours reached through
/// the bundle: the price rule, the specs, product-profit for the actual side,
/// business-scope, and storefront-catalog deciding what the web store lists.
@Suite struct ProfitPerHourTests {

    static func product(_ id: String, _ name: String, base: Double?, cost: Double?,
                        hours: Double?, hidden: Bool = false) -> JSONValue {
        var p: [String: JSONValue] = ["id": .string(id), "nameEn": .string(name)]
        if let base { p["basePrice"] = .number(base) }
        if let cost { p["baseCost"] = .number(cost) }
        if let hours {
            p["parts"] = .array([.object(["printTime": .number(hours), "qty": .number(1)])])
        }
        if hidden { p["storefrontHidden"] = .bool(true) }
        return .object(p)
    }

    static let products: [JSONValue] = [
        product("slow", "Slow bust", base: 100, cost: 60, hours: 20),
        product("quick", "Quick keyring", base: 100, cost: 60, hours: 2),
        product("mid", "Mid vase", base: 90, cost: 40, hours: 5),
        product("nohours", "Bought-in stand", base: 50, cost: 10, hours: nil),
        product("noprice", "New thing", base: nil, cost: nil, hours: 3),
    ]

    static func job(_ id: String, _ product: String, price: Double, hours: Double,
                    nonBusiness: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "status": .string("completed"), "productId": .string(product),
            "date": .string("2026-09-01"), "price": .number(price),
            "parts": .array([.object([
                "id": .string("pt" + id), "material": .string("PLA"), "qty": .number(1),
                "printWeight": .number(100), "printTime": .number(hours),
                "spoolWeight": .number(1000), "spoolCost": .number(100),
            ])]),
        ]
        if nonBusiness { o["nonBusiness"] = .bool(true) }
        return .object(o)
    }

    static func run(_ products: [JSONValue] = products,
                    orders: [JSONValue] = []) async throws -> KhaytEngine.ProfitPerHour {
        try await KhaytEngine().profitPerHour(
            products: products, orders: orders, expenses: [], inventory: [], consumables: [],
            settings: [:], clients: [], language: "en")
    }

    @Test("ranks by profit per machine hour, not per sale")
    func ranked() async throws {
        let r = try await Self.run()
        #expect(r.rows.prefix(3).map(\.productId) == ["quick", "mid", "slow"])
        #expect(r.row("quick")?.perHour == 20)
        #expect(r.row("slow")?.perHour == 2)
        #expect(r.row("slow")?.profit == r.row("quick")?.profit, "the same profit per sale")
        #expect(r.totals.best == "quick")
    }

    @Test("no hours and no price have no rate, sit last, and say why")
    func missing() async throws {
        let r = try await Self.run()
        #expect(r.row("nohours")?.perHour == nil)
        #expect(r.row("nohours")?.missing == "hours")
        #expect(r.row("noprice")?.perHour == nil)
        #expect(r.row("noprice")?.profit == nil)
        #expect(r.row("noprice")?.missing == "price")
        #expect(Set(r.rows.suffix(2).map(\.productId)) == ["nohours", "noprice"])
        #expect(r.totals.noHours == 1 && r.totals.noPrice == 1)
    }

    @Test("a product far under the shop's average per hour is flagged, with a price")
    func underpriced() async throws {
        let r = try await Self.run()
        let slow = try #require(r.row("slow"))
        #expect(slow.underpriced)
        #expect(try #require(slow.suggestedPrice) > 100)
        #expect(r.row("quick")?.underpriced == false)
    }

    @Test("actual figures come from business jobs only")
    func actual() async throws {
        let r = try await Self.run(orders: [
            Self.job("1", "quick", price: 100, hours: 2),
            Self.job("2", "quick", price: 0, hours: 2, nonBusiness: true),
        ])
        let actual = try #require(r.row("quick")?.actual)
        #expect(actual.jobs == 1)
        #expect(actual.hours == 2)
        #expect(actual.perHour != nil)
        #expect(r.row("mid")?.actual == nil, "never made")
    }

    @Test("web store hints read only what the store lists")
    func storeHints() async throws {
        var products = Self.products
        products[1] = Self.product("quick", "Quick keyring", base: 100, cost: 60, hours: 2, hidden: true)
        let r = try await Self.run(products)
        #expect(!r.storeBest.contains { $0.productId == "quick" }, "hidden from the store")
        #expect(r.storeBest.first?.productId == "mid")
        #expect(r.storeUnderpriced.map(\.productId) == ["slow"])
    }
}
