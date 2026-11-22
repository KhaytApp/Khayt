import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Points a customer has earned.
///
/// ── WHY THIS SUITE IS MOSTLY ABOUT WHAT IS *NOT* COUNTED ──────────────────
///
/// The sum is not a total of prices, and every exclusion in it was a real
/// over-award: a voided order, a personal print, an order refunded by a credit
/// note, the tax the shop merely collects, and prices in different currencies
/// added together. Between them they made a customer's balance four times the
/// real figure — and points are a liability the shop honours in money.
///
/// So these drive the shared rule through the bundle rather than restating what
/// it ought to return.
@MainActor
struct LoyaltyTests {

    static let settings: [String: JSONValue] = [
        "loyaltyEnabled": .bool(true),
        "loyaltyPointsPerUnit": .number(1),
        "enableVat": .bool(true),
        "vatRate": .number(15),
    ]

    static func order(_ id: String, client: String, price: Double,
                      status: String = "completed", voided: Bool = false) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id), "clientId": .string(client), "status": .string(status),
            "price": .number(price), "date": .string("2026-09-01"),
        ]
        if voided { row["voidedAt"] = .string("2026-09-02") }
        return .object(row)
    }

    // MARK: - What has been earned

    @Test("points are earned on what the shop keeps, not on the tax it collects")
    func earnedIsExVat() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.loyalty(
            orders: [Self.order("A", client: "C1", price: 115),
                     Self.order("B", client: "C1", price: 230)],
            ledger: [], clientId: "C1", settings: Self.settings, clients: [])
        // 100 + 200 ex-VAT at 15%.
        #expect(out.earned == 300)
        #expect(out.available == 300)
        #expect(out.redeemed == 0)
    }

    @Test("a voided order is not a sale and earns nothing")
    func voidedEarnsNothing() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.loyalty(
            orders: [Self.order("A", client: "C1", price: 115),
                     Self.order("B", client: "C1", price: 1150, voided: true)],
            ledger: [], clientId: "C1", settings: Self.settings, clients: [])
        #expect(out.earned == 100, "the voided order added 1,000 points to a balance the shop owes")
    }

    @Test("work still on the bench has not earned anything yet")
    func unfinishedEarnsNothing() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.loyalty(
            orders: [Self.order("A", client: "C1", price: 115, status: "pending")],
            ledger: [], clientId: "C1", settings: Self.settings, clients: [])
        #expect(out.earned == 0)
    }

    @Test("a delivered job counts — it is past completed, not instead of it")
    func deliveredCounts() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.loyalty(
            orders: [Self.order("A", client: "C1", price: 115, status: "delivered")],
            ledger: [], clientId: "C1", settings: Self.settings, clients: [])
        #expect(out.earned == 100)
    }

    @Test("nothing at all unless the shop turned the programme on")
    func offByDefault() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.loyalty(
            orders: [Self.order("A", client: "C1", price: 115)],
            ledger: [], clientId: "C1", settings: ["loyaltyEnabled": .bool(false)], clients: [])
        #expect(out.earned == 0)
        #expect(out.available == 0)
    }

    // MARK: - Tiers

    @Test("the tier's multiplier is applied, and the tier is named")
    func tierMultiplies() async throws {
        // The multiplier is an INPUT to the balance, so an app that could not
        // work out the tier would under-count every customer rather than fail.
        let engine = try KhaytEngine()
        var settings = Self.settings
        settings["loyaltyTiers"] = .array([
            .object(["name": .string("Silver"), "minOrders": .number(1),
                     "pointsMultiplier": .number(1)]),
            .object(["name": .string("Gold"), "minOrders": .number(2),
                     "pointsMultiplier": .number(2)]),
        ])
        let out = try await engine.loyalty(
            orders: [Self.order("A", client: "C1", price: 115),
                     Self.order("B", client: "C1", price: 115)],
            ledger: [], clientId: "C1", settings: settings, clients: [])
        #expect(out.tier == "Gold", "the highest bar a customer clears, not the first that matches")
        #expect(out.multiplier == 2)
        #expect(out.earned == 400, "200 ex-VAT at double")
    }

    // MARK: - What is left to spend

    @Test("what has been spent comes off, and a balance never goes negative")
    func availableIsClamped() async throws {
        // Correcting the over-award LOWERS what somebody has earned, so a
        // customer who was told they had a balance can find they have none.
        // That is a clamp, not an error.
        let engine = try KhaytEngine()
        let ledger: [JSONValue] = [
            .object(["clientId": .string("C1"), "type": .string("redeem"), "points": .number(250)]),
        ]
        let out = try await engine.loyalty(
            orders: [Self.order("A", client: "C1", price: 115)],
            ledger: ledger, clientId: "C1", settings: Self.settings, clients: [])
        #expect(out.earned == 100)
        #expect(out.redeemed == 250)
        #expect(out.available == 0)
    }

    @Test("another customer's redemptions are not this one's")
    func ledgerIsPerCustomer() async throws {
        let engine = try KhaytEngine()
        let ledger: [JSONValue] = [
            .object(["clientId": .string("C2"), "type": .string("redeem"), "points": .number(50)]),
            .object(["clientId": .string("C1"), "type": .string("earn"), "points": .number(999)]),
        ]
        let out = try await engine.loyalty(
            orders: [Self.order("A", client: "C1", price: 115)],
            ledger: ledger, clientId: "C1", settings: Self.settings, clients: [])
        #expect(out.redeemed == 0, "only this customer's REDEEM rows count")
        #expect(out.available == 100)
    }

    // MARK: - Turning points into credit

    @Test("a redemption is a gift card and a ledger row, together")
    func redemptionIsTwoRecords() async throws {
        // A card written without its row is the same points spent again next
        // month; a row written without its card is a customer told their
        // balance is gone with nothing to show for it.
        let engine = try KhaytEngine()
        let made = try await engine.redeemLoyalty(
            clientId: "C1", clientName: "Acme", points: 250, rate: 0.01,
            code: "LOY1", cardId: "GC1", entryId: "L1", now: "2026-09-19T00:00:00.000Z")
        #expect(made.ok)
        guard case .object(let card)? = made.card, case .object(let entry)? = made.entry else {
            Issue.record("a redemption came back without both records"); return
        }
        #expect(card["balance"] == .number(2.5))
        #expect(card["initialBalance"] == .number(2.5))
        #expect(card["issuedTo"] == .string("C1"))
        #expect(card["source"] == .string("loyalty"), "the shop should see it was earned, not sold")
        #expect(entry["type"] == .string("redeem"))
        #expect(entry["points"] == .number(250))
        #expect(entry["giftCardCode"] == card["code"], "the row must name the card it issued")
    }

    @Test("nothing to redeem issues nothing")
    func noPointsNoCard() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.redeemLoyalty(
            clientId: "C1", clientName: "Acme", points: 0, rate: 0.01,
            code: "LOY1", cardId: "GC1", entryId: "L1", now: "2026-09-19T00:00:00.000Z")
        #expect(!made.ok)
        #expect(made.reason == "no_points")
        #expect(made.card == nil)
    }

    @Test("points worth less than a whole unit of currency issue nothing")
    func subUnitCreditIsRefused() async throws {
        // A gift card for 0.00 is a card the customer cannot spend and the
        // shop has to explain.
        let engine = try KhaytEngine()
        let made = try await engine.redeemLoyalty(
            clientId: "C1", clientName: "Acme", points: 0, rate: 0.01,
            code: "LOY1", cardId: "GC1", entryId: "L1", now: "2026-09-19T00:00:00.000Z")
        #expect(!made.ok)
    }

    // MARK: - Wiring

    @Test("the app actually shows it")
    func theAppReachesTheRule() throws {
        // The fault this closes is a bundled rule with no caller: `loyalty` was
        // the ONE module in the Mac's bundle that nothing in Swift or in any
        // other module named.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let table = try String(contentsOf: sources.appending(path: "CustomersTable.swift"),
                               encoding: .utf8)
        #expect(table.contains("loyaltySection(person)"), "the customer pane never draws it")
        #expect(table.contains("shop.redeemPoints(person.id)"), "nothing can be redeemed")
    }
}
