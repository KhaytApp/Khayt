import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A catalogue price survives this app.
///
/// ── WHAT WENT WRONG ON A REAL BOOK ────────────────────────────────────────
///
/// A shop's portrait product: one part, 140.91 g of PLA+ off a 75-riyal kilo,
/// 5.25 h of printing, labour at 90 an hour for 0.1 h of prep and 0.1 h of
/// post, 150 W at 0.18 a kWh, wear at 0.75 an hour, a 10 % failure rate. The
/// other app costed it at 35.91, put 30 % on for 46.69, rounded up to 5 for a
/// catalogue price of 50.
///
/// Opened and saved in THIS app, the part came back with five fields — the
/// rates were not on the sheet, so the sheet did not write them — and the
/// product re-priced itself to 13.74: material only, plus margin, unrounded.
/// A job taken from it opened at 15 for the same reason. The shop had set a
/// price and watched it change with no way to set it back, because the sheet
/// had no price controls either. These tests hold all three seams to the
/// figures above.
@MainActor
struct CataloguePriceFidelityTests {

    /// The portrait's part, as the book held it before the save that broke it.
    static let portraitPart: [String: JSONValue] = [
        "name": .string(""), "filamentId": .string("seed-1"), "material": .string("PLA+ 2.0"),
        "spoolCost": .number(75), "spoolWeight": .number(1000),
        "printWeight": .number(140.91), "printTime": .number(5.25),
        "laborRate": .number(90), "prepTime": .number(0.1), "postTime": .number(0.1),
        "elecRate": .number(0.18), "powerDraw": .number(150), "wearRate": .number(0.75),
        "failureRate": .number(10), "printFileId": .string("PF-JFducR3aa"),
        "fileRef": .string("KING-Abdulaziz-ART-200mm-U1_PLA_4h32m.gcode"), "setupId": .null,
    ]
    static let shelf: [JSONValue] = [.object(["id": .string("seed-1"), "cost": .number(75),
                                               "material": .string("PLA+ 2.0"), "weight": .number(1000)])]
    static let spool: Spool = try! JSONDecoder().decode(
        Spool.self, from: Data(#"{"id":"seed-1","material":"PLA+ 2.0","cost":75,"weight":1000}"#.utf8))

    // MARK: - The product sheet keeps what it does not edit

    @Test("a part opened and saved on the product sheet keeps every field the sheet does not show")
    func partKeepsItsRates() throws {
        let row = try #require(ProductSheet.PartRow.from(.object(Self.portraitPart)))
        #expect(row.grams == "140.91" && row.hours == "5.25" && row.spoolId == "seed-1")
        guard case .object(let saved) = row.record(spools: [Self.spool]) else { Issue.record("not an object"); return }
        for key in ["laborRate", "prepTime", "postTime", "elecRate", "powerDraw", "wearRate", "failureRate",
                    "fileRef", "printFileId"] {
            #expect(saved[key] == Self.portraitPart[key], Comment(rawValue: "\(key) was dropped by the save"))
        }
        #expect(saved["printWeight"] == .number(140.91))
        #expect(saved["spoolCost"] == .number(75))
    }

    @Test("what the sheet edits wins over what was there, and a removed filament goes")
    func editsWin() throws {
        var row = try #require(ProductSheet.PartRow.from(.object(Self.portraitPart)))
        row.grams = "150"; row.qty = 2; row.name = "Portrait"
        guard case .object(let saved) = row.record(spools: [Self.spool]) else { Issue.record("not an object"); return }
        #expect(saved["printWeight"] == .number(150))
        #expect(saved["qty"] == .number(2))
        #expect(saved["name"] == .string("Portrait"))
        #expect(saved["laborRate"] == .number(90))
        row.spoolId = nil
        guard case .object(let bare) = row.record(spools: [Self.spool]) else { Issue.record("not an object"); return }
        #expect(bare["filamentId"] == nil && bare["spoolCost"] == nil, "the filament the shop removed is still on the part")
        #expect(bare["laborRate"] == .number(90))
    }

    // MARK: - A part made here is costed at more than its filament

    @Test("a new part carries the shared rates, so a Mac-made product is not priced on material alone")
    func newPartCarriesRates() async throws {
        let engine = try KhaytEngine()
        let defaults = try await engine.printRateDefaults()
        #expect(defaults["laborRate"] == 90 && defaults["failureRate"] == 10 && defaults["wearRate"] == 0.75)

        var row = ProductSheet.PartRow()
        row.grams = "140.91"; row.hours = "5.25"
        row.rates = defaults.mapValues { Money.fieldValue($0) }
        guard case .object(let made) = row.record(spools: [Self.spool]) else { Issue.record("no object"); return }
        for key in ProductSheet.PartRow.rateKeys {
            #expect(made[key] != nil, Comment(rawValue: "\(key) is missing from a part made on the Mac"))
        }
        // And it prices to more than its filament: 10.57 is material alone.
        let product = Product.from(["id": .string("P"), "nameEn": .string("P"),
                                    "defaultMargin": .number(30)], keys: [])
        let priced = try await engine.productPricingFields(
            .object(Shop.pricingInput(for: product, parts: [.object(made)])),
            inventory: Self.shelf, settings: [:], consumables: [])
        guard case .number(let cost)? = priced["baseCost"] else { Issue.record("no cost"); return }
        #expect(cost > 20, Comment(rawValue: "a part with the standard rates costed \(cost) — material alone is 10.57"))
    }

    @Test("a blank rate is absent, not zero, and an existing part keeps what it has")
    func blankIsNotZero() throws {
        var row = ProductSheet.PartRow()
        row.grams = "10"; row.rates = ["laborRate": "", "prepTime": "  ", "wearRate": "0.75"]
        guard case .object(let made) = row.record(spools: []) else { Issue.record("no object"); return }
        #expect(made["laborRate"] == nil, "a cleared rate became a zero")
        #expect(made["prepTime"] == nil)
        #expect(made["wearRate"] == .number(0.75))
        // Read back from a part that has them, they survive a save untouched.
        let existing = try #require(ProductSheet.PartRow.from(.object(Self.portraitPart)))
        #expect(existing.hasRates)
        #expect(existing.rates["laborRate"] == "90" && existing.rates["prepTime"] == "0.1")
        guard case .object(let again) = existing.record(spools: [Self.spool]) else { Issue.record("no object"); return }
        #expect(again["laborRate"] == .number(90) && again["prepTime"] == .number(0.1))
        // A part with none of them says so.
        var bare = Self.portraitPart
        for key in ProductSheet.PartRow.rateKeys { bare.removeValue(forKey: key) }
        let stripped = try #require(ProductSheet.PartRow.from(.object(bare)))
        #expect(!stripped.hasRates, "a part with no rates claimed to have some")
    }

    // MARK: - The product is priced with its own rounding and typed price

    @Test("the save prices the product with its rounding: the portrait comes to 50, not 46.69")
    func roundedOnSave() async throws {
        let engine = try KhaytEngine()
        let product = Product.from([
            "id": .string("P1"), "nameEn": .string("Portrait"), "defaultMargin": .number(30),
            "priceRound": .object(["step": .number(5), "mode": .string("up")]), "priceOverride": .null,
        ], keys: [])
        let input = Shop.pricingInput(for: product, parts: [.object(Self.portraitPart)])
        #expect(input["priceRound"] != nil, "the rounding never reached the rule")
        let priced = try await engine.productPricingFields(.object(input), inventory: Self.shelf, settings: [:], consumables: [])
        #expect(priced["baseCost"] == .number(35.91), Comment(rawValue: "\(priced)"))
        #expect(priced["basePrice"] == .number(46.69), Comment(rawValue: "\(priced)"))
        #expect(priced["price"] == .number(50), Comment(rawValue: "\(priced)"))
    }

    @Test("a typed price wins, and a material-only part still rounds")
    func overrideAndThinPart() async throws {
        let engine = try KhaytEngine()
        let typed = Product.from([
            "id": .string("P2"), "nameEn": .string("Portrait"), "defaultMargin": .number(30),
            "priceRound": .object(["step": .number(5), "mode": .string("up")]), "priceOverride": .number(42),
        ], keys: [])
        let a = try await engine.productPricingFields(.object(Shop.pricingInput(for: typed, parts: [.object(Self.portraitPart)])),
                                                      inventory: Self.shelf, settings: [:], consumables: [])
        #expect(a["price"] == .number(42))
        // The five-field part the old save wrote: 10.57 → 13.74 → rounded up to 15, not 13.74.
        var thin = Self.portraitPart
        for key in ["laborRate", "prepTime", "postTime", "elecRate", "powerDraw", "wearRate", "failureRate"] {
            thin.removeValue(forKey: key)
        }
        let rounded = Product.from([
            "id": .string("P3"), "nameEn": .string("Portrait"), "defaultMargin": .number(30),
            "priceRound": .object(["step": .number(5), "mode": .string("up")]),
        ], keys: [])
        let b = try await engine.productPricingFields(.object(Shop.pricingInput(for: rounded, parts: [.object(thin)])),
                                                      inventory: Self.shelf, settings: [:], consumables: [])
        #expect(b["baseCost"] == .number(10.57))
        #expect(b["price"] == .number(15), Comment(rawValue: "\(b)"))
    }

    // MARK: - A job from the product is costed at the product's rates

    @Test("a job taken from the product costs its part at 35.91, the catalogue's figure")
    func jobCostsAtProductRates() async throws {
        let engine = try KhaytEngine()
        let draft = try #require(NewJobSheet.Draft.from(.object(Self.portraitPart)))
        #expect(draft.raw["laborRate"] == .number(90), "the draft forgot the part it came from")
        let input = Shop.costInput(spool: Self.spool, grams: Double(draft.grams) ?? 0, hours: Double(draft.hours) ?? 0,
                                   qty: draft.qty, extra: draft.raw)
        let costed = try await engine.costPart(input, inventory: Self.shelf, settings: [:])
        #expect(abs(costed.cost - 35.91) < 0.005, Comment(rawValue: "cost \(costed.cost)"))
        #expect(costed.rates.laborRate == 90 && costed.rates.failureRate == 10)
        // Without the record, the same measurements are costed at the machine's
        // DEFAULT rates — a different figure from the catalogue's, which is the bug.
        let bare = Shop.costInput(spool: Self.spool, grams: 140.91, hours: 5.25, qty: 1)
        let thin = try await engine.costPart(bare, inventory: Self.shelf, settings: [:])
        #expect(abs(thin.cost - 35.91) > 1, Comment(rawValue: "cost \(thin.cost) — the defaults happen to match the product"))
    }

    @Test("the measured fields override the record, so a changed weight prices this job")
    func measurementsWin() throws {
        guard case .object(let part) = Shop.costInput(spool: Self.spool, grams: 200, hours: 6, qty: 3,
                                                       extra: Self.portraitPart) else { Issue.record("no object"); return }
        #expect(part["printWeight"] == .number(200) && part["printTime"] == .number(6) && part["qty"] == .number(3))
        #expect(part["wearRate"] == .number(0.75))
    }
}

/// What the shop floor says a percentage was measured by.
///
/// The caption existed to make one distinction — layers against file position
/// on a Moonraker printer — and quietly made a claim about every other
/// protocol as well, because `lib/sdcp.js` sets `progressSource` too.
@MainActor
struct ProgressCaptionTests {

    @Test("only the adapter that chooses between signals is captioned")
    func onlyMoonraker() {
        #expect(PrinterWatch.progressCaption(type: "moonraker", source: "m73") == "mac.by_printer")
        #expect(PrinterWatch.progressCaption(type: "moonraker", source: "layers") == "mac.by_layers")
        #expect(PrinterWatch.progressCaption(type: "moonraker", source: "bytes") == "mac.by_bytes")
        // A resin printer's own words, which are not about a file at all.
        for source in ["time", "none", "layers"] {
            #expect(PrinterWatch.progressCaption(type: "sdcp", source: source) == nil,
                    Comment(rawValue: "sdcp/\(source) was captioned"))
        }
        for type in ["octoprint", "prusalink", "bambu", "duet", "repetier"] {
            #expect(PrinterWatch.progressCaption(type: type, source: "layers") == nil,
                    Comment(rawValue: "\(type) was captioned"))
        }
        #expect(PrinterWatch.progressCaption(type: "moonraker", source: nil) == nil)
        // A signal this app has not been taught is not described at all.
        #expect(PrinterWatch.progressCaption(type: "moonraker", source: "whatever") == nil)
    }

    @Test("every source the Moonraker rule can emit has a caption")
    func everySourceIsNamed() async throws {
        // The producer's own vocabulary, so a new signal cannot be added on
        // one side and read as nothing on the other.
        let engine = try KhaytEngine()
        for (source, layers, bytes, display) in [
            ("m73", true, 0.5, 0.7), ("layers", true, 0.5, 0.5), ("bytes", false, 0.5, 0.5),
        ] as [(String, Bool, Double, Double)] {
            var stats: [String: JSONValue] = [:]
            if layers { stats["info"] = .object(["current_layer": .number(5), "total_layer": .number(10)]) }
            let got = try await engine.moonrakerProgressSource(
                printStats: .object(stats),
                virtualSdcard: .object(["progress": .number(bytes)]),
                displayStatus: .object(["progress": .number(display)]))
            #expect(got == source, Comment(rawValue: "expected \(source), got \(got)"))
            #expect(PrinterWatch.progressCaption(type: "moonraker", source: got) != nil,
                    Comment(rawValue: "the rule emits \(got) and the screen has no word for it"))
        }
    }
}
