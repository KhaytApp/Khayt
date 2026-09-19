import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Who a message would reach, and what it would say to each of them.
///
/// ── THE ASSERTION THAT MATTERS ────────────────────────────────────────────
///
/// A customer who opted out of marketing is never in the list, whatever the
/// segment says. That is the rule's decision and this app must never be able
/// to override it — so it is checked through the bridge, against a shop that
/// matches the segment in every other way.
///
/// The second is `{{name}}`: `lib/campaigns.js` carries a comment about a
/// campaign that went out reading "Hi ," to a whole client list, because the
/// name was picked as English-or-Arabic and the shop wrote neither. A shop
/// writing German is the case that proves this app did not reintroduce it.
@MainActor
struct CampaignTests {

    static func client(_ id: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "nameEn": .string("Layla Design Studio"),
            "email": .string("\(id)@example.com"), "phone": .string("+966500000001"),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func order(_ clientId: String, price: Double, date: String) -> JSONValue {
        .object(["id": .string("O-" + clientId + date), "clientId": .string(clientId),
                 "status": .string("completed"), "price": .number(price),
                 "date": .string(date)])
    }

    @Test("a customer who opted out is never reached, however the segment is drawn")
    func optOutWins() async throws {
        let engine = try KhaytEngine()
        let opted = Self.client("C1", ["marketingOptOut": .bool(true)])
        let ordinary = Self.client("C2")
        let orders = [Self.order("C1", price: 900, date: "2026-01-01"),
                      Self.order("C2", price: 900, date: "2026-01-01")]

        // The widest segment there is: no criteria at all.
        let all = try await engine.campaignRecipients(
            clients: [opted, ordinary], orders: orders, criteria: [:],
            channel: "email", tiers: [:], now: Date())
        #expect(all.count == 1, "a customer who opted out of marketing was on the list")

        // And a segment written specifically to include them does not.
        let aimed = try await engine.campaignRecipients(
            clients: [opted], orders: orders, criteria: ["minSpend": .number(0)],
            channel: "email", tiers: [:], now: Date())
        #expect(aimed.isEmpty)
    }

    @Test("a customer with no address on that channel is left out")
    func unreachable() async throws {
        let engine = try KhaytEngine()
        let noEmail = Self.client("C3", ["email": .string("")])
        let byEmail = try await engine.campaignRecipients(
            clients: [noEmail], orders: [], criteria: [:], channel: "email",
            tiers: [:], now: Date())
        #expect(byEmail.isEmpty, "a customer with no email was on an email campaign")

        // The same customer IS reachable on WhatsApp, which reads the phone.
        let byPhone = try await engine.campaignRecipients(
            clients: [noEmail], orders: [], criteria: [:], channel: "whatsapp",
            tiers: [:], now: Date())
        #expect(byPhone.count == 1)
    }

    @Test("the segment narrows by what was spent and by how long ago")
    func narrowing() async throws {
        let engine = try KhaytEngine()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-19T00:00:00Z"))
        let big = Self.client("C4")
        let small = Self.client("C5")
        let orders = [Self.order("C4", price: 900, date: "2026-09-18"),
                      Self.order("C5", price: 40, date: "2026-01-01")]

        let spenders = try await engine.campaignRecipients(
            clients: [big, small], orders: orders, criteria: ["minSpend": .number(100)],
            channel: "email", tiers: [:], now: now)
        #expect(spenders.count == 1)
        #expect(spenders.first?.stats.totalSpend == 900)

        // Lapsed: nothing bought for at least 90 days.
        let lapsed = try await engine.campaignRecipients(
            clients: [big, small], orders: orders, criteria: ["noOrderDays": .number(90)],
            channel: "email", tiers: [:], now: now)
        #expect(lapsed.count == 1)
        #expect(lapsed.first?.stats.lastOrderDate == "2026-01-01")
    }

    @Test("an empty box is no filter at all, not a filter of zero")
    func emptyIsNotZero() {
        // The rule reads `!= null`, so a zero is a real filter — "spent at
        // least nothing", which is everybody, and a different list from the one
        // a shop that cleared the field meant.
        var segment = Shop.Segment()
        #expect(segment.criteria["minSpend"] == nil)
        segment.minSpend = 0
        #expect(segment.criteria["minSpend"] == .number(0))
        segment.tag = "   "
        #expect(segment.criteria["tag"] == nil, "a box of spaces became a tag filter")
    }

    // MARK: - What it would say

    @Test("the greeting fills in for a shop that writes neither English nor Arabic")
    func theGreetingIsNotEnglishOrArabic() async throws {
        // `lib/campaigns.js` carries the comment about a campaign that went out
        // reading "Hi ," to a whole client list. This is the case that proves
        // the Mac did not reintroduce it.
        let engine = try KhaytEngine()
        let recipient = JSONValue.object([
            "client": .object(["id": .string("C6"), "name_de": .string("Muster Werkstatt")]),
            "stats": .object(["completedCount": .number(3), "totalSpend": .number(450),
                              "lastOrderDate": .string("2026-08-01")]),
        ])
        let filled = try await engine.fillCampaignTemplate(
            "Hallo {{name}}, {{orders}} Aufträge, {{spend}}.",
            recipient: recipient, spend: "450.00",
            settings: .object(["contentLangs": .array([.string("de")])]))
        #expect(filled.contains("Muster Werkstatt"), "the greeting went out empty")
        #expect(filled.contains("3"))
        #expect(filled.contains("450.00"))
    }

    @Test("the sheet shows who and what before anything is sent, and sends nothing")
    func previewOnly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let sheet = try String(contentsOf: sources.appending(path: "CampaignSheet.swift"),
                               encoding: .utf8)
        #expect(sheet.contains("mac.campaign_reach"), "the count is never shown")
        #expect(sheet.contains("campaignPreview"), "the message is never filled in")
        // Sending is the next step and is deliberately not here. A sheet that
        // could send would be a sheet that can send by accident.
        #expect(!sheet.contains("EmailClient"), "this sheet can send mail")
        #expect(sheet.contains("mac.campaign_no_send"), "the shop is not told sending is elsewhere")

        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"),
                                encoding: .utf8)
        #expect(window.contains("CampaignSheet(shop: shop)"), "the sheet is never presented")
    }
}
