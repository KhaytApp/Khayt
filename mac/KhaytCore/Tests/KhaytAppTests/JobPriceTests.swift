import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The last word on a job's total — rounded to a step, or typed — and a
/// customer's agreed price for a part, as this app hands them to the rule.
///
/// The RULE is `lib/pricing.js` and `lib/order-new.js`, tested where it lives.
/// What is tested here is the wiring: that the sheet's choices reach the rule
/// through `previewQuote` and `newJobInput`, that a part carries its agreed
/// price and not an overwritten cost, and that the figures come back in the
/// shape the sheet reads.
@MainActor
struct JobPriceTests {

    @Test("rounding and a typed price reach the preview, and the arithmetic comes back beside them")
    func preview() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        let plain = try #require(await shop.previewQuote(baseCost: 1421.05, margin: 30, discountPct: 0,
                                                          shippingCost: 0, rush: false))
        #expect(abs(plain.total - 1847.365) < 0.01)
        #expect(plain.priceSource == "base")
        #expect(!plain.differsFromComputed)

        let up = Shop.PriceRule(step: 5, mode: "up")
        let rounded = try #require(await shop.previewQuote(baseCost: 1421.05, margin: 30, discountPct: 0,
                                                            shippingCost: 0, rush: false, rule: up))
        #expect(rounded.total == 1850)
        #expect(rounded.priceSource == "rounded")
        #expect(rounded.differsFromComputed)
        #expect(abs((rounded.computedTotal ?? 0) - 1847.365) < 0.01)

        let typed = try #require(await shop.previewQuote(baseCost: 1421.05, margin: 30, discountPct: 0,
                                                          shippingCost: 0, rush: false,
                                                          rule: Shop.PriceRule(step: 5, mode: "up", override: 1800)))
        #expect(typed.total == 1800 && typed.priceSource == "override", "typed wins over rounding")

        // What the customer agreed joins after the discount and is not marked up.
        let agreed = try #require(await shop.previewQuote(baseCost: 100, margin: 30, discountPct: 10,
                                                           shippingCost: 0, rush: false, agreedAmount: 200))
        #expect(agreed.total == 317)
        #expect(agreed.agreedAmount == 200)
    }

    @Test("a part carries its agreed price beside its cost, never instead of it")
    func partRows() {
        var draft = NewJobSheet.Draft()
        draft.name = "Wall bracket"; draft.grams = "40"; draft.hours = "2"; draft.qty = 4
        draft.cost = 3
        draft.agreedPrice = 50
        let rows = Shop.partRows([draft], spools: [], unnamed: "A part")
        guard case .object(let row)? = rows.first else { Issue.record("no row"); return }
        #expect(row["unitCost"] == .number(3))
        #expect(row["baseCost"] == .number(12))
        #expect(row["agreedPrice"] == .number(50))
        draft.agreedPrice = nil
        guard case .object(let bare)? = Shop.partRows([draft], spools: [], unnamed: "A part").first else { return }
        #expect(bare["agreedPrice"] == nil, "no agreement, no field — the rule prices at cost plus margin")
    }

    @Test("the sheet's rounding rule and typed price travel to the record's rule")
    func input() {
        let shop = Shop(source: .sample)
        let plain = shop.newJobInput(parts: [], project: "x", clientId: nil, margin: 30, discountPct: 0,
                                     shippingCost: 0, deposit: 0, rush: false, asQuote: false)
        #expect(plain["priceRound"] == nil && plain["priceOverride"] == nil,
                "a plain job asks for nothing, so the record carries nothing new")
        let rounded = shop.newJobInput(parts: [], project: "x", clientId: nil, margin: 30, discountPct: 0,
                                       shippingCost: 0, deposit: 0, rush: false, asQuote: false,
                                       rule: Shop.PriceRule(step: 5, mode: "down"))
        #expect(rounded["priceRound"] == .object(["step": .number(5), "mode": .string("down")]))
        #expect(rounded["priceOverride"] == nil)
        let typed = shop.newJobInput(parts: [], project: "x", clientId: nil, margin: 30, discountPct: 0,
                                     shippingCost: 0, deposit: 0, rush: false, asQuote: false,
                                     rule: Shop.PriceRule(override: 1800))
        #expect(typed["priceOverride"] == .number(1800))
        #expect(Shop.PriceRule().isPlain && !Shop.PriceRule(step: 1).isPlain && !Shop.PriceRule(override: 0).isPlain)
    }
}
