import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the calculator costs a part AT.
///
/// `lib/print-rates.js` resolves the seven figures in a fixed order — Khayt's
/// openers, then a saved preset over all seven, then the machine over the two
/// a printer knows about itself, and anything typed for the part over all of
/// it. `costPart` has always taken a `preset`, and this app never passed one:
/// a shop could write down its labour rate, see it listed, and still be quoted
/// at 90 an hour for ever. Reported by the shop this was built for, asking
/// where labour is adjusted.
///
/// These run the REAL rules through the engine rather than restating the
/// order, because a test that restated it would agree with the same mistake.
@MainActor
struct CalculatorRatesTests {

    /// 272g over 14.9h — the part `lib/print-rates.js` uses in its own header
    /// to show what omitting these rates costs.
    static func part(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        Shop.costInput(spool: nil, grams: 272, hours: 14.9, qty: 1, extra: extra)
    }

    static let preset: JSONValue = .object([
        "id": .string("P1"), "name": .string("Bench"),
        "laborRate": .number(150), "prepTime": .number(0.5), "postTime": .number(1),
    ])

    @Test("a saved preset changes what a part costs")
    func presetApplies() async throws {
        let engine = try KhaytEngine()
        let without = try await engine.costPart(Self.part(), inventory: [], settings: [:])
        let with = try await engine.costPart(Self.part(), inventory: [], settings: [:],
                                             machine: nil, preset: Self.preset)
        #expect(with.cost > without.cost,
                Comment(rawValue: "preset \(with.cost) should beat defaults \(without.cost)"))
        // Not a token difference: 90/h over 0.75h against 150/h over 1.5h.
        #expect(with.cost - without.cost > 100)
    }

    @Test("a figure typed for the part beats the preset")
    func typedBeatsPreset() async throws {
        let engine = try KhaytEngine()
        let onPreset = try await engine.costPart(Self.part(), inventory: [], settings: [:],
                                                 machine: nil, preset: Self.preset)
        let typed = try await engine.costPart(Self.part(["laborRate": .number(220)]),
                                              inventory: [], settings: [:],
                                              machine: nil, preset: Self.preset)
        #expect(typed.cost > onPreset.cost, "the part's own labour rate must win")
    }

    /// The resolution order, asked of the rule rather than restated.
    @Test("the machine carries its two figures and the preset carries the rest")
    func resolutionOrder() async throws {
        let engine = try KhaytEngine()
        let machine: JSONValue = .object([
            "id": .string("M1"), "powerDraw": .number(400), "wearRate": .number(9),
            // A machine has no business carrying a labour rate; if it did, it
            // must not win — only powerDraw and wearRate are a printer's own.
            "laborRate": .number(1),
        ])
        let rates = try await engine.printRates(machine: machine, preset: Self.preset)
        #expect(rates["powerDraw"] == 400, "the machine's own power draw")
        #expect(rates["wearRate"] == 9, "the machine's own wear rate")
        #expect(rates["laborRate"] == 150, "labour comes from the preset, never the machine")
        #expect(rates["elecRate"] == 0.18, "untouched by either, so Khayt's opener")
        let shop = try await engine.printRates(machine: machine, preset: Self.preset,
                                               settings: ["elecRate": .number(0.3)])
        #expect(shop["elecRate"] == 0.3, "the shop's own tariff, which neither overrides")
    }

    /// `settings.elecRate`: between Khayt's opener and a preset.
    @Test("the shop's own tariff is charged with no preset, and a preset's beats it")
    func shopTariff() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = ["elecRate": .number(0.3)]
        #expect(try await engine.printRates(settings: settings)["elecRate"] == 0.3)
        #expect(try await engine.printRateDefaults(settings: settings)["elecRate"] == 0.3)
        // Labour and the rest stay Khayt's: only the tariff is the shop's.
        #expect(try await engine.printRateDefaults(settings: settings)["laborRate"] == 90)
        // A preset that says nothing of electricity leaves the shop's standing…
        #expect(try await engine.printRates(preset: Self.preset, settings: settings)["elecRate"] == 0.3)
        // …and one that does wins.
        let own: JSONValue = .object(["id": .string("P2"), "elecRate": .number(0.12)])
        #expect(try await engine.printRates(preset: own, settings: settings)["elecRate"] == 0.12)
        // Through the costing itself, and through what the part is written down at.
        let costed = try await engine.costPart(Self.part(), inventory: [], settings: settings)
        #expect(costed.rates.elecRate == 0.3)
        let plain = try await engine.costPart(Self.part(), inventory: [], settings: [:])
        #expect(costed.cost > plain.cost)
        let viaPartCost = try await engine.partCost(Self.part(), inventory: [], settings: settings)
        #expect(abs(viaPartCost - costed.cost) < 1e-9)
        // Blank or negative is "not said": the opener stands.
        for bad: JSONValue in [.string(""), .number(-1), .null] {
            #expect(try await engine.printRates(settings: ["elecRate": bad])["elecRate"] == 0.18)
        }
    }

    @Test("with nothing saved, the rates are Khayt's own openers")
    func defaultsWhenNothingSaved() async throws {
        let engine = try KhaytEngine()
        let rates = try await engine.printRates()
        let openers = try await engine.printRateDefaults()
        #expect(rates == openers)
        #expect(rates["laborRate"] == 90, "the figure every untouched shop is quoted at")
    }

    /// The wiring itself — the half that was missing.
    ///
    /// `Shop.costedPart` gained a `presetId`; proving the parameter exists is
    /// not enough, so this asserts the screen's call site actually passes the
    /// one it is holding. Read as source because a View body cannot be asked.
    @Test("the calculator passes its chosen preset to the costing")
    func calculatorPassesThePreset() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/Calculator.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!text.isEmpty, "Calculator.swift was not read — this would pass vacuously")
        #expect(text.contains("presetId: presetId"),
                "the calculator costs its part without the preset the shop picked")
        #expect(text.contains("shop.resolvedRates("),
                "the rate fields are not seeded from the rule's own answer")
    }
}
