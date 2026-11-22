import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A currency per customer, as the desktop keeps it (`currency` on the client,
/// "" for the shop's own). The shared `orderCurrency` reads it; this app reads
/// it leniently, writes it back, and never replaces a code it does not list.
@MainActor
struct CustomerCurrencyTests {

    @Test("a stored currency is read as a string; anything else is the shop's own")
    func reads() throws {
        let usd = try #require(Client.decoding(["id": .string("C1"), "currency": .string("USD")]))
        #expect(usd.currency == "USD")
        #expect(usd.record["currency"] == .string("USD"))
        for bad: JSONValue in [.string(""), .string("  "), .number(3), .null, .bool(true), .array([])] {
            let c = try #require(Client.decoding(["id": .string("C2"), "currency": bad]))
            #expect(c.currency == "", "\(bad) is the shop's currency")
        }
        let none = try #require(Client.decoding(["id": .string("C3")]))
        #expect(none.currency == "")
        #expect(none.inCurrency("EUR").currency == "EUR")
        #expect(none.inCurrency("EUR").inCurrency("").currency == "")
    }

    @Test("every other edit keeps the currency")
    func editsKeepIt() throws {
        let c = try #require(Client.decoding(["id": .string("C1")])).inCurrency("EUR")
        #expect(c.marketed(false).currency == "EUR")
        #expect(c.with(\.phone, "0500").currency == "EUR")
        #expect(c.onTerms(30).currency == "EUR")
        #expect(c.limited(to: 10).currency == "EUR")
        #expect(c.replacing(priceList: []).currency == "EUR")
        #expect(c.replacing(recurring: nil).currency == "EUR")
        #expect(c.optedIntoWhatsApp(true, how: "asked", at: Date()).currency == "EUR")
        #expect(c.optedIntoWhatsAppOffers(true, how: "asked", at: Date()).currency == "EUR")
    }

    @Test("a code this app does not list survives a round trip and a save")
    func unknownCodeSurvives() throws {
        let had: [String: JSONValue] = ["id": .string("C1"), "nameEn": .string("Acme"), "currency": .string("XYZ")]
        let c = try #require(Client.decoding(had))
        #expect(c.currency == "XYZ")
        #expect(Client.decoding(c.record)?.currency == "XYZ")
        #expect(Shop.customerRecord(saving: c, over: had, opened: c)["currency"] == .string("XYZ"))
        // Editing something else still carries it.
        #expect(Shop.customerRecord(saving: c.with(\.phone, "0500"), over: had, opened: c)["currency"] == .string("XYZ"))
        // Choosing the shop's own writes "".
        #expect(Shop.customerRecord(saving: c.inCurrency(""), over: had, opened: c)["currency"] == .string(""))
    }

    @Test("an untouched save leaves the stored currency exactly as it was, whatever its shape")
    func untouchedSave() throws {
        let bare: [String: JSONValue] = ["id": .string("C1"), "nameEn": .string("Acme")]
        let b = try #require(Client.decoding(bare))
        #expect(Shop.customerRecord(saving: b, over: bare, opened: b)["currency"] == nil)
        let odd: [String: JSONValue] = ["id": .string("C1"), "nameEn": .string("Acme"), "currency": .number(7)]
        let o = try #require(Client.decoding(odd))
        #expect(Shop.customerRecord(saving: o, over: odd, opened: o)["currency"] == .number(7))
        let padded: [String: JSONValue] = ["id": .string("C1"), "nameEn": .string("Acme"), "currency": .string(" eur ")]
        let p = try #require(Client.decoding(padded))
        #expect(Shop.customerRecord(saving: p, over: padded, opened: p)["currency"] == .string(" eur "))
        #expect(Shop.customerRecord(saving: p.inCurrency("USD"), over: padded, opened: p)["currency"] == .string("USD"))
    }

    // MARK: - Converted when saved (#2148), and back for a copy

    private static let tokens = (tracking: [UInt8](repeating: 1, count: 16),
                                 quoteApproval: [UInt8](repeating: 2, count: 16))

    @Test("a job for a euro customer is saved in euros at the shop's rate")
    func newOrderConvertsThroughClients() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        var d = NewJobSheet.Draft()
        d.name = "Bracket"; d.grams = "40"; d.hours = "3"; d.qty = 1; d.cost = 20
        let input = shop.newJobInput(parts: [d], project: "Brackets", clientId: "C-EUR", margin: 0,
                                     discountPct: 0, shippingCost: 40, deposit: 0, rush: false,
                                     asQuote: false)
        let settings: [String: JSONValue] = ["currency": .string("SAR"),
                                             "exchangeRates": .object(["EUR": .number(4)])]
        let clients: [JSONValue] = [.object(["id": .string("C-EUR"), "currency": .string("EUR")])]
        let out = try await engine.newOrder(input, orders: [], settings: settings, now: Date(),
                                            tokens: Self.tokens, clients: clients)
        guard case .object(let order) = out.order else { Issue.record("no record"); return }
        #expect(order["currency"] == .string("EUR"))
        #expect(order["shippingCost"] == .number(10), "40 SAR of shipping at 4 SAR to the euro")

        // Without the customers handed over, nothing says euros.
        let plain = try await engine.newOrder(input, orders: [], settings: settings, now: Date(),
                                              tokens: Self.tokens)
        guard case .object(let p) = plain.order else { Issue.record("no record"); return }
        #expect(p["shippingCost"] == .number(40))
    }

    @Test("a euro job comes back in the shop's currency for a copy, and a riyal job untouched")
    func inShopCurrencyForACopy() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let settings: [String: JSONValue] = ["currency": .string("SAR"),
                                             "exchangeRates": .object(["EUR": .number(4)])]
        let eur = try await engine.inShopCurrency(
            .object(["currency": .string("EUR"), "shippingCost": .number(10)]), settings: settings)
        #expect(eur["fx"] == .number(4))
        #expect(eur["shippingCost"] == .number(40))
        let sar = try await engine.inShopCurrency(.object(["shippingCost": .number(10)]), settings: settings)
        #expect(sar["fx"] == .number(1))
        #expect(sar["shippingCost"] == .number(10))
    }
}
