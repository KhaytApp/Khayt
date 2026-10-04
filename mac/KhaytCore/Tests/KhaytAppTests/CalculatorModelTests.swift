import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The calculator, driven the way the screen drives it.
///
/// A tester: "it has a base project total that doesn't seem to change no
/// matter how I adjust the costs such as labor, print time, or filament." These
/// move each of those inputs on the SAME `CalculatorModel` the screen binds to,
/// run the same `recompute` its `.task(id: model.key)` runs, and require the
/// total to move the right way — and the key to change, because a recompute
/// keyed on a value that did not change never runs.
@MainActor
struct CalculatorModelTests {

    static func shop() async -> Shop {
        let s = Shop()
        await s.load(.sample)
        return s
    }

    /// A priced part on the sample book's first spool.
    static func model(_ shop: Shop) -> CalculatorModel {
        let m = CalculatorModel(grams: "120", hours: "4")
        m.lines[0].spoolId = shop.spools.first?.id
        return m
    }

    /// Change one thing, and say what the total and the key did.
    static func moved(_ m: CalculatorModel, _ shop: Shop,
                      _ change: (CalculatorModel) -> Void) async -> (before: Double, after: Double, keyMoved: Bool) {
        await m.recompute(shop)
        let before = m.quoted?.total ?? 0
        let key = m.key
        change(m)
        await m.recompute(shop)
        return (before, m.quoted?.total ?? 0, m.key != key)
    }

    @Test("labour rate, print time, filament grams and spool price each move the total")
    func everyInputMovesTheTotal() async throws {
        let shop = await Self.shop()
        try #require(!shop.spools.isEmpty)

        let labour = await Self.moved(Self.model(shop), shop) { $0.rates["laborRate"] = "200" }
        #expect(labour.keyMoved)
        #expect(labour.after > labour.before, "labour 90 → 200 must raise it: \(labour)")

        let hours = await Self.moved(Self.model(shop), shop) { $0.hours = "9" }
        #expect(hours.keyMoved)
        #expect(hours.after > hours.before, "4h → 9h must raise it: \(hours)")

        let grams = await Self.moved(Self.model(shop), shop) { $0.lines[0].grams = "400" }
        #expect(grams.keyMoved)
        #expect(grams.after > grams.before, "120g → 400g must raise it: \(grams)")

        // The filament PRICE: a dearer spool at the same weight.
        let byPrice = shop.spools.sorted { ($0.cost ?? 0) / max(1, $0.spoolWeight ?? 1000)
                                         < ($1.cost ?? 0) / max(1, $1.spoolWeight ?? 1000) }
        let cheap = try #require(byPrice.first), dear = try #require(byPrice.last)
        let m = Self.model(shop)
        m.lines[0].spoolId = cheap.id
        let spool = await Self.moved(m, shop) { $0.lines[0].spoolId = dear.id }
        #expect(spool.after > spool.before, "a dearer spool must raise it: \(spool)")

        let margin = await Self.moved(Self.model(shop), shop) { $0.margin = 80 }
        #expect(margin.after > margin.before)

        let labourDown = await Self.moved(Self.model(shop), shop) { $0.rates["laborRate"] = "10" }
        #expect(labourDown.after < labourDown.before, "and lowering labour lowers it")
    }

    @Test("a second colour is charged at its own spool, and purge is charged too")
    func multicolour() async throws {
        let shop = await Self.shop()
        try #require(shop.spools.count >= 2)
        let one = Self.model(shop)
        await one.recompute(shop)
        let single = try #require(one.costed).cost

        let two = Self.model(shop)
        two.addFilament(spools: shop.spools)
        #expect(two.lines.count == 2)
        #expect(two.lines[1].spoolId != two.lines[0].spoolId, "the new line opens on a different spool")
        // Adding the colour split the 120 typed (alpha.59 review); this part
        // is 120 g of one colour and 60 g of the other.
        #expect(two.gramsValue == 120, "split, not added")
        two.lines[0].grams = "120"
        two.lines[1].grams = "60"
        #expect(two.isMulticolour)
        await two.recompute(shop)
        let both = try #require(two.costed).cost
        #expect(both > single)

        // The part handed to the rule is the shape the deduction draws from.
        guard case .object(let part) = CalculatorModel.costInput(
            lines: two.lines, purge: 18, hours: 4, qty: 1, spools: shop.spools,
            consumables: [], shelf: []),
              case .array(let colours)? = part["colours"] else {
            Issue.record("no colours on a two-filament part"); return
        }
        #expect(colours.count == 2)
        #expect(part["printWeight"] == .number(198), "120 + 60 + 18 purge")
        var grams = 0.0
        for case .object(let c) in colours { grams += Shop.plainNumber(c["grams"]) ?? 0 }
        #expect(abs(grams - 198) < 1e-9, "the purge is shared out over the colours, not lost")

        two.purge = "18"
        await two.recompute(shop)
        #expect(try #require(two.costed).cost > both, "purge costs filament")
    }

    @Test("consumables are added to the cost, per printed piece")
    func consumables() async throws {
        let shop = await Self.shop()
        let magnet = try #require(shop.consumables.first { $0.id == "CONS-07" })
        let m = Self.model(shop)
        await m.recompute(shop)
        let bare = try #require(m.costed).cost

        m.addConsumable(shop.consumables)
        m.consumableLines[0].consumableId = magnet.id
        m.consumableLines[0].qty = 4
        await m.recompute(shop)
        let with = try #require(m.costed).cost
        // 4 × 0.35 = 1.40, plus the failure allowance on it.
        #expect(with - bare > 1.39, "\(bare) → \(with)")
        #expect(abs(m.consumablesCost(shop.consumables) - 1.4) < 1e-9)
    }

    @Test("picking a multicolour model fills a line per colour on the catalogue's figures, its time and its magnets")
    func fillFromModel() async throws {
        let shop = await Self.shop()
        let dallah = try #require(shop.files.first { $0.id == "PF-sample-dallah" })
        // The same figures the "From a model…" row reads: the catalogue's.
        let made = try #require(await shop.partFields(from: dallah, plate: nil))
        let g = try #require(Shop.plainNumber(made.part["printWeight"]))
        let h = try #require(Shop.plainNumber(made.part["printTime"]))
        let m = Self.model(shop)
        let filled = m.fill(from: dallah, plate: nil, grams: g, hours: h, shop: shop)
        #expect(filled == 3)
        #expect(abs(m.gramsValue - g) < 0.02, "the colour lines add up to the catalogue's weight")
        #expect(m.lines.map(\.grams) == ["96.4", "38.2", "11.7"])
        #expect(m.lines.allSatisfy { $0.spoolId != nil }, "each colour lands on a spool")
        #expect(abs(m.hoursValue - h) < 0.01)
        #expect(m.consumableLines.count == 1)
        #expect(m.consumableLines.first?.qty == 4)
        await m.recompute(shop)
        #expect((m.quoted?.total ?? 0) > 0)

        // A different total from the caller wins, the colours scaled to it.
        let half = Self.model(shop)
        half.fill(from: dallah, plate: nil, grams: g / 2, hours: h, shop: shop)
        #expect(abs(half.gramsValue - g / 2) < 0.02)
    }

    @Test("a model's consumables ride onto the product made from it, and into the job's cost")
    func modelToProductToJob() async throws {
        let shop = await Self.shop()
        let dallah = try #require(shop.files.first { $0.id == "PF-sample-dallah" })
        let product = try #require(await shop.productFromFile(dallah))
        guard case .array(let parts)? = product.rest["parts"], case .object(let first)? = parts.first,
              case .array(let uses)? = first["consumables"] else {
            Issue.record("the product's part carries no consumables"); return
        }
        #expect(uses.count == 1)
        // The job's part keeps them and is costed with them.
        var draft = try #require(NewJobSheet.Draft.from(.object(first)))
        draft.spoolId = shop.spools.first?.id
        let rows = Shop.partRows([draft], spools: shop.spools, unnamed: "x")
        guard case .object(let row)? = rows.first else { Issue.record("no row"); return }
        #expect(row["consumables"] != nil, "a job taken from the product draws the magnets")
        var bare = first; bare.removeValue(forKey: "consumables")
        let withThem = try #require(await shop.costedPart(.object(first)))
        let without = try #require(await shop.costedPart(.object(bare)))
        #expect(withThem.cost > without.cost)
    }
}
