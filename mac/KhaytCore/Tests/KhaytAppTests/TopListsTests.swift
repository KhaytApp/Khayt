import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Who the shop's best customers are, and what it is asked for most.
///
/// The rollups are `lib/top-lists.js`'s and are pinned against the renderer's
/// originals in `test/top-lists.test.js`. What is worth testing HERE is the
/// filter this app puts in front of them — which orders fall in the period,
/// which count as trade, which are voided — because that is the part the Mac
/// asks for, and a Mac that ranked a shop's customers over a different set of
/// orders would disagree with Khayt on the one screen nobody checks twice.
@MainActor
struct TopListsTests {

    /// A day, `n` days before the fixed now these tests use.
    static let now = Date(timeIntervalSince1970: 1_788_566_400)  // 2026-09-05, checked
    static func day(_ back: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -back, to: now)!
        return Shop.today(d)
    }

    static func job(_ id: String, client: String, product: String, price: Double,
                    status: String = "completed", daysAgo: Int = 1,
                    voided: Bool = false, nonBusiness: Bool = false) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id), "clientId": .string(client), "productId": .string(product),
            "status": .string(status), "price": .number(price), "paidAmount": .number(price),
            "date": .string(day(daysAgo)),
        ]
        if voided { row["voidedAt"] = .string(day(daysAgo)) }
        if nonBusiness { row["nonBusiness"] = .bool(true) }
        return .object(row)
    }

    static let clients: [JSONValue] = [
        .object(["id": .string("C-1"), "nameEn": .string("Aisha")]),
        .object(["id": .string("C-2"), "nameEn": .string("Omar")]),
    ]
    static let products: [JSONValue] = [
        .object(["id": .string("P-1"), "nameEn": .string("Lid")]),
        .object(["id": .string("P-2"), "nameEn": .string("Bracket")]),
    ]

    static func lists(_ orders: [JSONValue], period: String = "month") async throws -> KhaytEngine.TopLists {
        try await KhaytEngine().topLists(
            orders: orders, products: products, clients: clients,
            settings: ["currency": .string("SAR")], currencies: [:],
            language: "en", period: period, now: now)
    }

    @Test("a delivered job is finished work: it counts, and so does its money")
    func deliveredCounts() async throws {
        // `delivered` is past `completed`. The filter here asked for
        // `completed` only, so a customer whose jobs had reached them read as
        // "1×" — or not at all — on a screen beside one counting all of them.
        let out = try await Self.lists([
            Self.job("O-1", client: "C-1", product: "P-1", price: 100),
            Self.job("O-2", client: "C-1", product: "P-1", price: 200, status: "delivered"),
            Self.job("O-3", client: "C-2", product: "P-2", price: 900, status: "delivered"),
        ])
        let aisha = try #require(out.clients.first { $0.name == "Aisha" })
        #expect(aisha.count == 2)
        #expect(aisha.revenue > 250)
        #expect(out.clients.first?.name == "Omar", "a customer whose only job was delivered is still a customer")
    }

    @Test("customers are ranked by what they actually paid")
    func clientsByRevenue() async throws {
        let out = try await Self.lists([
            Self.job("O-1", client: "C-1", product: "P-1", price: 100),
            Self.job("O-2", client: "C-2", product: "P-2", price: 900),
            Self.job("O-3", client: "C-1", product: "P-1", price: 100),
        ])
        #expect(out.clients.map(\.name) == ["Omar", "Aisha"])
        #expect(out.clients.map(\.revenue) == [900, 200])
        #expect(out.clients.map(\.count) == [1, 2])
    }

    @Test("products are ranked by how often they are asked for, not by revenue")
    func productsByCount() async throws {
        // A part quoted twenty times and made twice is a fact about the shop
        // worth seeing, and a list sorted by revenue would hide it.
        let out = try await Self.lists([
            Self.job("O-1", client: "C-1", product: "P-1", price: 10, status: "quote"),
            Self.job("O-2", client: "C-1", product: "P-1", price: 10, status: "quote"),
            Self.job("O-3", client: "C-1", product: "P-1", price: 10),
            Self.job("O-4", client: "C-2", product: "P-2", price: 5000),
        ])
        #expect(out.products.map(\.name) == ["Lid", "Bracket"])
        #expect(out.products.map(\.count) == [3, 1])
        // Counted three times, earned once: the two quotes brought in nothing.
        #expect(out.products[0].revenue == 10)
    }

    @Test("a voided job earns nothing and is still asked for")
    func voidedCountsButDoesNotEarn() async throws {
        let out = try await Self.lists([
            Self.job("O-1", client: "C-1", product: "P-1", price: 500, voided: true),
        ])
        #expect(out.clients.isEmpty, "a voided job made this customer the shop's best")
        #expect(out.products.map(\.count) == [1])
        #expect(out.products[0].revenue == 0)
    }

    @Test("a job the shop marked as not trade is not revenue")
    func nonBusinessIsNotRevenue() async throws {
        let out = try await Self.lists([
            Self.job("O-1", client: "C-1", product: "P-1", price: 400, nonBusiness: true),
            Self.job("O-2", client: "C-2", product: "P-2", price: 100),
        ])
        #expect(out.clients.map(\.name) == ["Omar"])
    }

    @Test("the period is the one the shop picked")
    func honoursThePeriod() async throws {
        let orders = [
            Self.job("O-1", client: "C-1", product: "P-1", price: 100, daysAgo: 2),
            Self.job("O-2", client: "C-2", product: "P-2", price: 900, daysAgo: 400),
        ]
        let month = try await Self.lists(orders, period: "month")
        #expect(month.clients.map(\.name) == ["Aisha"], "a job from last year was counted in this month")
        let all = try await Self.lists(orders, period: "all")
        #expect(all.clients.map(\.name) == ["Omar", "Aisha"])
    }

    @Test("a deleted customer's orders still count, under their id")
    func missingRecordsKeepTheirRow() async throws {
        // A shop that deletes a customer still earned the money. Dropping the
        // row would quietly change last quarter's totals.
        let out = try await Self.lists([Self.job("O-1", client: "C-GONE", product: "P-1", price: 300)])
        #expect(out.clients.map(\.name) == ["C-GONE"])
        #expect(out.clients.map(\.revenue) == [300])
    }

    @Test("an empty book is two empty lists")
    func emptyBook() async throws {
        let out = try await Self.lists([])
        #expect(out.clients.isEmpty)
        #expect(out.products.isEmpty)
    }
}
