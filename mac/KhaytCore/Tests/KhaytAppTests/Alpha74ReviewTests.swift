import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The 4.0.0-alpha.74 pre-release review: a job taken from a catalogue product
/// priced with the overhead line the product's own price never carries, a
/// typed price recorded as carrying overhead, and the calculator's Make
/// buttons off on the sample shop with a hover that did not say why.
///
/// The invoice-number findings are in `MacReviewFixesTests`, beside the tests
/// they changed; Paid in full in `JobFromModelTests`; the hours field in
/// `OverheadTests`.
@MainActor
struct Alpha74ReviewTests {

    private static func overheadOn(_ shop: Shop) async throws {
        let engine = try #require(shop.engine)
        var s = shop.settingsDict
        s["fixedCosts"] = .array([.object(["id": .string("a"), "name": .string("Rent"),
                                           "amount": .number(2100)])])
        s["overheadPerHour"] = .object(["enabled": .bool(true), "monthlyHours": .number(500)])
        shop.overhead = try await engine.overhead(settings: .object(s), machines: [], orders: [],
                                                  today: "2026-10-15")
    }

    private static func bracket() -> NewJobSheet.Draft {
        var d = NewJobSheet.Draft()
        d.name = "Bracket"; d.grams = "40"; d.hours = "3"; d.qty = 2; d.cost = 20
        return d
    }

    private static let tokens = (tracking: [UInt8](repeating: 1, count: 16),
                                 quoteApproval: [UInt8](repeating: 2, count: 16))

    // MARK: - S4. A product has one price

    @Test("a job taken from a product carries no overhead: preview and record (S4)")
    func productJobHasNoOverhead() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        try await Self.overheadOn(shop)
        #expect(shop.overheadPerHour == 4.2)
        let engine = try #require(shop.engine)
        let parts = [Self.bracket()]

        // The preview's hours: none from a product, 3 h × 2 by hand.
        let fromProduct = await shop.overheadHours(of: parts, productId: "PROD-1")
        let byHand = await shop.overheadHours(of: parts)
        #expect(fromProduct == 0)
        #expect(byHand == 6)

        // The record, even though the sheet hands it the shop's rate.
        let product = JobFromProductTests.product([:])
        let input = shop.newJobInput(parts: parts, project: "Dallah stand", clientId: nil, margin: 50,
                                     discountPct: 0, shippingCost: 0, deposit: 0, rush: false,
                                     asQuote: false, fromProduct: product,
                                     overheadPerHour: shop.overheadPerHour)
        let out = try await engine.newOrder(input, orders: [], settings: [:], now: Date(), tokens: Self.tokens)
        guard case .object(let order) = out.order else { Issue.record("no record"); return }
        #expect(order["overheadCost"] == nil)
        #expect(order["price"] == .number(60), "40 of parts + 50%, as the catalogue prices it")
    }

    // MARK: - N1. A typed price

    @Test("a typed price records no overhead (N1)")
    func typedPriceHasNoOverheadCost() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        try await Self.overheadOn(shop)
        let engine = try #require(shop.engine)
        var input = shop.newJobInput(parts: [Self.bracket()], project: "Brackets", clientId: nil,
                                     margin: 50, discountPct: 0, shippingCost: 0, deposit: 0,
                                     rush: false, asQuote: false, overheadPerHour: shop.overheadPerHour)
        input["priceOverride"] = .number(99)
        let out = try await engine.newOrder(input, orders: [], settings: [:], now: Date(), tokens: Self.tokens)
        guard case .object(let order) = out.order else { Issue.record("no record"); return }
        #expect(order["price"] == .number(99))
        #expect(order["overheadCost"] == nil)
    }

    // MARK: - N7. Why Make quote is off

    @Test("on the sample shop, Make quote's hover says the sample cannot be changed (N7)")
    func makeHelpSaysWhy() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        #expect(!shop.canMoveJobs)
        let said = Calculator.makeHelp(shop)
        #expect(said == shop.words.callIt("mac.move_sample"))
        #expect(said != shop.words.callIt("mac.make_quote_help"))
    }

    // MARK: - S3b. The words

    @Test("'Invoice number not issued yet' is said in both languages")
    func notIssuedWords() async throws {
        let engine = try KhaytEngine()
        let en = Words()
        await en.load("en", engine: engine)
        let ar = Words()
        await ar.load("ar", engine: engine)
        #expect(en.callIt("mac.invoice_not_issued") == "Invoice number not issued yet")
        #expect(ar.callIt("mac.invoice_not_issued") == "لم يُصدَر رقم الفاتورة بعد")
    }
}
