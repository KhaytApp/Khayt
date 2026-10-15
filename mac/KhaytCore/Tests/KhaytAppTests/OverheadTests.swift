import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Overhead per print hour: the shop's fixed costs spread over the hours it
/// prints, as an opt-in cost line (`lib/overhead-rate.js`).
///
/// The RULE is tested where it lives (test/overhead-rate.test.js). What is
/// tested here is that this app CALLS it: that opening a book resolves the
/// rate, that the calculator's and the job sheet's preview charge it, that
/// the job is saved at the price the preview showed, and that a shop that has
/// not turned it on sees every price exactly as before.
@MainActor
struct OverheadTests {

    /// The sample book's settings with the line turned on at a known figure.
    private static func turnedOn(_ settings: [String: JSONValue], hours: Double = 500) -> JSONValue {
        var s = settings
        s["fixedCosts"] = .array([
            .object(["id": .string("a"), "name": .string("Rent"), "amount": .number(1500)]),
            .object(["id": .string("b"), "name": .string("Internet"), "amount": .number(300)]),
            .object(["id": .string("c"), "name": .string("Software"), "amount": .number(300)]),
            .object(["id": .string("d"), "name": .string("Staff salaries"), "amount": .number(4000)]),
        ])
        s["overheadPerHour"] = .object(["enabled": .bool(true), "monthlyHours": .number(hours)])
        return .object(s)
    }

    @Test("opening a book resolves the rate, and a book that never turned it on is charged nothing")
    func offByDefault() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        // Resolved at all: deleting the call in `load` leaves this nil.
        let resolved = try #require(shop.overhead)
        #expect(resolved.enabled == false)
        #expect(shop.overheadPerHour == 0)

        let plain = try #require(await shop.previewQuote(baseCost: 100, margin: 30, discountPct: 0,
                                                          shippingCost: 0, rush: false))
        let withHours = try #require(await shop.previewQuote(baseCost: 100, margin: 30, discountPct: 0,
                                                              shippingCost: 0, rush: false,
                                                              overheadHours: 12))
        #expect(withHours.total == plain.total, "off means the price is the price it always was")
        #expect((withHours.overhead ?? 0) == 0)

        let input = shop.newJobInput(parts: [], project: "x", clientId: nil, margin: 30, discountPct: 0,
                                     shippingCost: 0, deposit: 0, rush: false, asQuote: false,
                                     overheadPerHour: shop.overheadPerHour)
        #expect(input["overheadPerHour"] == nil, "nothing new travels to the record while it is off")
    }

    @Test("ON: the rate is the rule's, pay left out, and the explanation says where it comes from")
    func resolvesTheRule() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let settings = Self.turnedOn(shop.settingsDict)
        let o = try await engine.overhead(settings: settings, machines: shop.machineRows,
                                          orders: [], today: "2026-10-15")
        #expect(o.enabled)
        #expect(o.rate == 4.2)
        #expect(o.perHour == 4.2)
        #expect(o.monthlyCost == 2100)
        #expect(o.source == "shop")
        let leftNames = o.left.map(\.name)
        #expect(leftNames == ["Staff salaries"])

        let said = FixedCostsSettings.explanation(o, words: shop.words, currency: "SAR")
        let rateText = Money.text(4.2, "SAR")
        let costText = Money.text(2100, "SAR")
        #expect(said.contains(rateText))
        #expect(said.contains(costText))
        #expect(said.contains("500"))
        #expect(!said.contains("set.overhead"), "a key that resolves nowhere shows as itself")

        // Too few hours: no rate, and a reason rather than an absurd figure.
        let few = try await engine.overhead(settings: Self.turnedOn(shop.settingsDict, hours: 5),
                                            machines: [], orders: [], today: "2026-10-15")
        #expect(few.rate == nil && few.perHour == 0 && few.reason == "few_hours")
        let fewSaid = FixedCostsSettings.explanation(few, words: shop.words, currency: "SAR")
        #expect(!fewSaid.isEmpty && !fewSaid.contains("set.overhead"))
    }

    @Test("ON: the job sheet's preview is the price the job is saved at, overhead included")
    func previewIsTheSavedPrice() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        shop.overhead = try await engine.overhead(settings: Self.turnedOn(shop.settingsDict),
                                                  machines: [], orders: [], today: "2026-10-15")
        #expect(shop.overheadPerHour == 4.2)

        var printed = NewJobSheet.Draft()
        printed.name = "Bracket"; printed.grams = "40"; printed.hours = "3"; printed.qty = 2
        printed.cost = 20
        var agreed = NewJobSheet.Draft()
        agreed.name = "Lid"; agreed.grams = "10"; agreed.hours = "1"; agreed.qty = 1
        agreed.cost = 5; agreed.agreedPrice = 30
        let parts = [printed, agreed]

        // The agreed part carries no overhead: 3 h × 2 pieces only.
        let hours = await shop.overheadHours(of: parts)
        #expect(hours == 6)

        let preview = try #require(await shop.previewQuote(baseCost: 40, margin: 50, discountPct: 0,
                                                            shippingCost: 0, rush: false,
                                                            agreedAmount: 30, overheadHours: hours))
        let overhead = try #require(preview.overhead)
        #expect(abs(overhead - 25.2) < 0.0001)
        let expected = (40 + 25.2) * 1.5 + 30
        #expect(abs(preview.total - expected) < 0.005)

        let input = shop.newJobInput(parts: parts, project: "Brackets", clientId: nil, margin: 50,
                                     discountPct: 0, shippingCost: 0, deposit: 0, rush: false,
                                     asQuote: false, overheadPerHour: shop.overheadPerHour)
        #expect(input["overheadPerHour"] == .number(4.2))
        let out = try await engine.newOrder(input, orders: [], settings: [:], now: Date(),
                                            tokens: (tracking: Array(repeating: 1, count: 16),
                                                     quoteApproval: Array(repeating: 2, count: 16)))
        guard case .object(let order) = out.order, case .number(let price)? = order["price"] else {
            Issue.record("no price on the record"); return
        }
        #expect(abs(price - preview.total) < 0.005, "the sheet showed what the job is saved at")
        #expect(order["overheadCost"] == .number(25.2))
    }

    @Test("ON: the calculator's own recompute charges every piece's hours")
    func calculatorCharges() async throws {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let model = CalculatorModel()
        model.hours = "2"
        model.qty = 3
        await model.recompute(shop)
        let off = try #require(model.quoted)
        #expect((off.overhead ?? 0) == 0)

        shop.overhead = try await engine.overhead(settings: Self.turnedOn(shop.settingsDict),
                                                  machines: [], orders: [], today: "2026-10-15")
        await model.recompute(shop)
        let on = try #require(model.quoted)
        let overhead = try #require(on.overhead)
        #expect(abs(overhead - 2 * 3 * 4.2) < 0.0001)
        #expect(on.total > off.total)
    }

    @Test("the settings form reads and writes the stored shape")
    func form() {
        let none = FixedCostsSettings.OverheadForm.read([:])
        #expect(none == FixedCostsSettings.OverheadForm())
        let stored: [String: JSONValue] = [
            "overheadPerHour": .object(["enabled": .bool(true), "monthlyHours": .number(320)]),
        ]
        let read = FixedCostsSettings.OverheadForm.read(stored)
        #expect(read.enabled && read.monthlyHours == 320)
        #expect(read.value == stored["overheadPerHour"])
    }

    @Test("a public quote is priced from a book that carries the machines")
    func pricingBookHasMachines() {
        let root: [String: JSONValue] = ["machines": .array([.object(["id": .string("m1")])])]
        let book = Shop.pricingBook(from: root)
        #expect(book["machines"] == root["machines"])
    }

    /// A book whose public pricing is on: a flat spool, one preset, a machine
    /// with a daily target, and the fixed costs — with or without the line.
    private static func lanRoot(overheadOn: Bool) -> [String: JSONValue] {
        var settings: [String: JSONValue] = [
            "currency": .string("SAR"),
            "fixedCosts": .array([.object(["id": .string("r"), "name": .string("Rent"),
                                           "amount": .number(2100)])]),
            "lanApi": .object(["intakeQuote": .object([
                "enabled": .bool(true), "presetId": .string("P1"),
                "spoolCost": .number(90), "spoolWeight": .number(1000), "marginPct": .number(40),
            ])]),
        ]
        if overheadOn {
            settings["overheadPerHour"] = .object(["enabled": .bool(true), "monthlyHours": .number(500)])
        }
        return [
            "settings": .object(settings),
            "printers": .array([.object(["id": .string("P1"), "wearRate": .number(0.75)])]),
            "inventory": .array([]), "printLog": .array([]),
            "machines": .array([.object(["id": .string("m1"), "targetHoursPerDay": .number(8)])]),
        ]
    }

    @Test("the Mac's price on its Wi-Fi server (the estimate) carries the overhead only when it is on")
    func lanEstimateCarriesIt() async throws {
        // The Mac's LAN server has no `/api/quote`: the only price it hands out
        // is the estimate (`/api/intake/estimate`), which runs `publicQuote` over
        // `pricingBook` — exactly as `LanServer` does with `host.pricing()`.
        let engine = try KhaytEngine()
        let sliced: JSONValue = .object(["exact": .bool(true), "source": .string("slicer"),
                                         "printTimeMins": .number(180), "filamentGrams": .number(40)])
        let offBook = Shop.pricingBook(from: Self.lanRoot(overheadOn: false))
        let onBook = Shop.pricingBook(from: Self.lanRoot(overheadOn: true))
        let off = try await engine.publicQuote(intake: sliced, store: .object(offBook), qty: 2)
        let on = try await engine.publicQuote(intake: sliced, store: .object(onBook), qty: 2)
        guard case .object(let o) = off, case .number(let offPrice)? = o["price"],
              case .object(let n) = on, case .number(let onPrice)? = n["price"] else {
            Issue.record("no price: \(off) / \(on)"); return
        }
        // 3 h × 2 pieces × 4.20 an hour, marked up 40%.
        let expected = ((offPrice + 25.2 * 1.4) * 100).rounded() / 100
        #expect(abs(onPrice - expected) < 0.011)
    }

    @Test("a part with a fixed price tier at its quantity carries no overhead hours")
    func tieredPartHasNoHours() async throws {
        let engine = try KhaytEngine()
        let tiers: JSONValue = .array([.object(["minQty": .number(2), "pricePerUnit": .number(30)])])
        let tiered: JSONValue = .object(["printTime": .number(3), "qty": .number(2), "priceTiers": tiers])
        let plain: JSONValue = .object(["printTime": .number(1), "qty": .number(1)])
        let notReached: JSONValue = .object(["printTime": .number(3), "qty": .number(1), "priceTiers": tiers])
        let both = try await engine.overheadHours([tiered, plain])
        let below = try await engine.overheadHours([notReached])
        #expect(both == 1)
        #expect(below == 3)
    }
}
