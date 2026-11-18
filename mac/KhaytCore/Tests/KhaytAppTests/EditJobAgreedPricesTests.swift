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

    /// Whether this build's rule exports `unexplainedShare` (electron's money
    /// PR). Without it every price counts as unexplained and no markup is
    /// passed: the safe side, #2523's rule keeps the price.
    static func ruleSays(_ engine: KhaytEngine) async -> Bool {
        (try? await engine.unexplainedShare(Self.job([Self.agreed], price: 100))) != nil
    }

    @Test("a markup only for a job whose agreed prices explain its whole price")
    func markupOnlyForAllAgreed() async throws {
        let engine = try KhaytEngine()
        let says = await Self.ruleSays(engine)
        let settings: [String: JSONValue] = ["defaultMargin": .number(40)]
        func markup(_ order: JSONValue, _ s: [String: JSONValue] = ["defaultMargin": .number(40)]) async -> Double? {
            await Shop.markupForAddedParts(order, settings: s, engine: engine)
        }
        #expect(await markup(Self.job([Self.agreed], price: 100)) == (says ? 40 : nil))
        #expect(await markup(Self.job([Self.agreed], price: 100), [:]) == (says ? 30 : nil), "the app's default")
        // Agreed 100 on a job priced 300: 200 nothing explains. No markup, ever.
        #expect(await markup(Self.job([Self.agreed], price: 300)) == nil)
        // Anything not agreed: none, so #2523's rule keeps a price nothing explains.
        #expect(await markup(Self.job([Self.agreed, Self.uncosted], price: 300)) == nil)
        #expect(await markup(Self.job([Self.uncosted], price: 200)) == nil)
        #expect(await markup(Self.job([], price: 0)) == nil)
        _ = settings
    }

    @Test("a costed part added: marked up on an explained all-agreed job; an unexplained price stays")
    func throughTheSave() async throws {
        let engine = try KhaytEngine()
        let says = await Self.ruleSays(engine)
        let shop = Shop()
        let words = Shop.jobSaveRefusalWords(shop.words)
        func saved(_ order: JSONValue, parts: [JSONValue]) async throws -> JSONValue {
            var save = Shop.JobSave()
            save.parts = parts
            return try await Shop.jobSaved(order, save, clients: [], settings: ["defaultMargin": .number(30)],
                                           engine: engine, refusals: words, now: Date(timeIntervalSince1970: 1_800_000_000))
        }
        // 100 agreed + 50 at the shop's 30%: 165 (it was 150, the bare cost).
        #expect(Self.price(try await saved(Self.job([Self.agreed], price: 100), parts: [Self.agreed, Self.costed50]))
                == (says ? 165 : 150))
        // Agreed 100 on a 300 job: the 200 nothing explains stays (#2523), not 165.
        #expect(Self.price(try await saved(Self.job([Self.agreed], price: 300), parts: [Self.agreed, Self.costed50])) == 300)
        // #2523 untouched: 200 that no part explains stays 200.
        #expect(Self.price(try await saved(Self.job([Self.uncosted], price: 200), parts: [Self.uncosted, Self.costed50])) == 200)
        // The single-part editor's path makes the same call.
        let one = try await Shop.jobWithParts(of: Self.job([Self.agreed, Self.costed50], price: 300),
                                              on: Self.job([Self.agreed], price: 300), keepPrice: false,
                                              settings: ["defaultMargin": .number(30)], engine: engine,
                                              refusals: Shop.partsRefusalWords(shop.words))
        #expect(Self.price(one.order) == 300)
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
        #expect(save.contains("marginPct: await Self.markupForAddedParts(order, settings: settings, engine: engine)"))
        #expect(MenuCoverageTests.source("Shop+Money.swift").contains("marginPct: await markupForAddedParts(order, settings: settings, engine: engine)"))
    }
}
