import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Edit Job prices what it ADDS the way New Job does (beta.40 full review,
/// money area): a part added for a customer with a price agreement takes the
/// agreed price, in the job's currency; and a costed part added to a job
/// priced wholly from agreed prices takes the shop's markup, not its bare cost.
@MainActor
struct EditJobAgreedPricesTests {

    static let agreed: JSONValue = .object(["id": .string("P1"), "name": .string("Widget"), "qty": .number(1),
                                            "agreedPrice": .number(100)])
    static let uncosted: JSONValue = .object(["id": .string("P0"), "name": .string("u"), "printWeight": .number(10),
                                              "qty": .number(1)])
    static let costed50: JSONValue = .object(["name": .string("b"), "qty": .number(1), "baseCost": .number(50),
                                              "unitCost": .number(50)])

    static func job(_ parts: [JSONValue], price: Double, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string("J1"), "status": .string("pending"), "price": .number(price),
                                      "paidAmount": .number(0), "parts": .array(parts)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func price(_ order: JSONValue) -> Double? {
        if case .object(let o) = order, case .number(let p)? = o["price"] { return p }
        return nil
    }

    @Test("a markup is passed only for a job priced wholly from agreed prices")
    func markupOnlyForAllAgreed() {
        let settings: [String: JSONValue] = ["defaultMargin": .number(40)]
        #expect(Shop.markupForAddedParts(Self.job([Self.agreed], price: 100), settings: settings) == 40)
        #expect(Shop.markupForAddedParts(Self.job([Self.agreed], price: 100), settings: [:]) == 30, "the app's default")
        // Anything not agreed: none, so #2523's rule keeps a price nothing explains.
        #expect(Shop.markupForAddedParts(Self.job([Self.agreed, Self.uncosted], price: 300), settings: settings) == nil)
        #expect(Shop.markupForAddedParts(Self.job([Self.uncosted], price: 200), settings: settings) == nil)
        #expect(Shop.markupForAddedParts(Self.job([], price: 0), settings: settings) == nil)
    }

    @Test("a costed part added to an all-agreed job is marked up; an unexplained price still stays")
    func throughTheSave() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let words = Shop.jobSaveRefusalWords(shop.words)
        func saved(_ order: JSONValue, parts: [JSONValue]) async throws -> JSONValue {
            var save = Shop.JobSave()
            save.parts = parts
            return try await Shop.jobSaved(order, save, clients: [], settings: ["defaultMargin": .number(30)],
                                           engine: engine, refusals: words, now: Date(timeIntervalSince1970: 1_800_000_000))
        }
        // 100 agreed + 50 at the shop's 30%: 165 (it was 150, the bare cost).
        #expect(Self.price(try await saved(Self.job([Self.agreed], price: 100), parts: [Self.agreed, Self.costed50])) == 165)
        // #2523 untouched: 200 that no part explains stays 200.
        #expect(Self.price(try await saved(Self.job([Self.uncosted], price: 200), parts: [Self.uncosted, Self.costed50])) == 200)
        // The single-part editor's path makes the same call.
        let one = try await Shop.jobWithParts(of: Self.job([Self.agreed, Self.costed50], price: 100),
                                              on: Self.job([Self.agreed], price: 100), keepPrice: false,
                                              settings: ["defaultMargin": .number(30)], engine: engine,
                                              refusals: Shop.partsRefusalWords(shop.words))
        #expect(Self.price(one.order) == 165)
    }

    @Test("an agreed price is held in the job's currency")
    func agreedInJobCurrency() {
        #expect(Shop.inJobCurrency(100, fxRate: 1) == 100)
        #expect(Shop.inJobCurrency(100, fxRate: 3.75) == 26.67, "100 SAR in USD at 3.75")
        #expect(Shop.inJobCurrency(100, fxRate: 0) == 100, "no rate on file: as it is")
    }

    @Test("Edit Job hands the customer on the sheet to the parts it adds")
    func wired() {
        let sheet = MenuCoverageTests.source("JobSheet.swift")
        #expect(sheet.contains("shop.partsForSave(subject.id, drafts: parts,\n                                                 clientId: form.customerId.isEmpty ? nil : form.customerId)"))
        let save = MenuCoverageTests.source("Shop+JobSheet.swift")
        #expect(save.contains("let agreements = await agreedPrices(for: added.map(\\.name), clientId: clientId)"))
        #expect(save.contains("fresh.agreedPrice = Self.inJobCurrency(agreed, fxRate: fx)"))
        #expect(save.contains("marginPct: Self.markupForAddedParts(order, settings: settings)"))
        #expect(MenuCoverageTests.source("Shop+Money.swift").contains("marginPct: markupForAddedParts(order, settings: settings)"))
    }
}
