import Testing
import Foundation
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// The first-run setup: when it offers itself, and that what it writes is what
/// the screens that normally write those things would have written.
@MainActor
struct ShopSetupTests {

    // MARK: - When it opens by itself

    @Test("offered for an empty real book, and for a Mac with no book at all")
    func offeredWhenNew() {
        #expect(ShopSetup.offers(isReal: true, canWrite: true, machines: 0, orders: 0, aRealBookExists: true))
        #expect(ShopSetup.offers(isReal: false, canWrite: false, machines: 5, orders: 42, aRealBookExists: false),
                "no book on this Mac: the sample is showing, and the setup is how a book is started")
    }

    @Test("never for a book with data, a book another app holds, or the sample beside a real book")
    func notOfferedOtherwise() {
        #expect(!ShopSetup.offers(isReal: true, canWrite: true, machines: 1, orders: 0, aRealBookExists: true))
        #expect(!ShopSetup.offers(isReal: true, canWrite: true, machines: 0, orders: 1, aRealBookExists: true))
        #expect(!ShopSetup.offers(isReal: true, canWrite: false, machines: 0, orders: 0, aRealBookExists: true),
                "a book the other app holds cannot take the answers")
        #expect(!ShopSetup.offers(isReal: false, canWrite: false, machines: 5, orders: 42, aRealBookExists: true),
                "the sample opened on purpose, with the shop's own book on this Mac")
    }

    @Test("the sample shop never offers it, whatever the sample holds")
    func sampleNeverOffers() async {
        let shop = Shop()
        await shop.load(.sample)
        #expect(!ShopSetup.offers(isReal: shop.source.isReal, canWrite: shop.canWrite,
                                  machines: shop.machines.count, orders: shop.orders.count,
                                  aRealBookExists: true))
        #expect(!shop.canWrite)
    }

    @Test("dismissal is remembered per book, and a missing book has its own key")
    func dismissalKeys() {
        #expect(Shop.setupKey(for: nil) == "setup.dismissed.no-book")
        // `khayt` and `Khayt` are one folder on a default Mac, so one answer.
        #expect(Shop.setupKey(for: .development) == Shop.setupKey(for: .shipped))
    }

    // MARK: - Skipping writes nothing

    @Test("an empty setup writes nothing at all")
    func skippingWritesNothing() async throws {
        let engine = try KhaytEngine()
        let before: [String: JSONValue] = ["settings": .object(["currency": .string("SAR")]),
                                           "machines": .array([])]
        var root = before
        let setup = ShopSetup()
        #expect(!setup.writesAnything(currentCurrency: "SAR", currentlyChargesVat: false, currentVatRate: 15))
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: "Shop rates")
        #expect(root == before)
    }

    @Test("answers that repeat what the book already says write nothing")
    func unchangedAnswersWriteNothing() async throws {
        let engine = try KhaytEngine()
        let before: [String: JSONValue] = ["settings": .object([
            "currency": .string("SAR"), "enableVat": .bool(true), "vatRate": .number(15)])]
        var root = before
        var setup = ShopSetup()
        setup.currency = "SAR"
        setup.chargesVat = true
        setup.vatRate = 15
        // A printer step visited and left blank, and a filament with no price.
        setup.printer = ShopSetup.Printer()
        setup.filament = ShopSetup.Filament()
        #expect(!setup.writesAnything(currentCurrency: "SAR", currentlyChargesVat: true, currentVatRate: 15))
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: "Shop rates")
        #expect(root == before)
    }

    // MARK: - The same record the Machine sheet writes

    @Test("the printer is the record the Machine sheet would write, catalogue power included")
    func sameMachineAsTheSheet() async throws {
        let engine = try KhaytEngine()
        let catalogue = try await engine.printerCatalog()
        let model = try #require(catalogue.first { ($0.powerDraw ?? 0) > 0 && $0.nozzleMaterial != nil },
                                 "the catalogue lists no model with a power draw and a nozzle")
        let bought = try #require(Self.day(2026, 3, 1))

        var setup = ShopSetup()
        setup.printer = ShopSetup.Printer(
            catalogId: model.id, name: "Bench one",
            powerDraw: model.powerDraw ?? 0, nozzleDiameter: model.nozzleDiameter ?? 0.4,
            nozzleMaterial: model.nozzleMaterial ?? "brass",
            price: 3200, bought: bought, lifeHours: 5000)
        var viaSetup: [String: JSONValue] = [:]
        try await ShopSetup.apply(setup, to: &viaSetup, engine: engine, presetName: "Shop rates",
                                  machineId: "MACH-TEST")

        // What the Machine sheet sends for a new printer with this model
        // picked and the same fields typed: its `Form` as a new machine opens,
        // the model applied by its own `picked`, through its own `input()`,
        // saved through the same `writeMachine` with nothing opened.
        var form = MachineSheet.Form()
        form.loadedRows = LoadedRow.rows(for: nil)
        form.name = "Bench one"
        form = MachineSheet.picked(model, into: form)
        form.depPrice = 3200
        form.depBought = bought
        form.depLife = 5000
        var viaSheet: [String: JSONValue] = [:]
        try await Shop.writeMachine(into: &viaSheet, input: form.input(), id: nil, catalogId: model.id,
                                    opened: nil, engine: engine, newId: "MACH-TEST")

        let a = try #require(Self.onlyMachine(viaSetup))
        let b = try #require(Self.onlyMachine(viaSheet))
        #expect(a == b, "the setup and the Machine sheet wrote different machines")

        // And the record carries what the costing reads — not merely "the same
        // as the sheet", which would pass if both lost it.
        #expect(Shop.plainNumber(a["powerDraw"]) == model.powerDraw,
                "the catalogue's power draw was not kept")
        guard case .object(let dep)? = a["depreciation"] else {
            Issue.record("no depreciation block written"); return
        }
        #expect(Shop.plainNumber(dep["price"]) == 3200)
        #expect(Shop.plainNumber(dep["life"]) == 5000)
        #expect(dep["lifeUnit"] == .string("hours"))
        #expect(dep["purchaseDate"] == .string("2026-03-01"))
        guard case .object(let nozzle)? = a["nozzle"] else {
            Issue.record("no nozzle block"); return
        }
        #expect(nozzle["material"] == .string(model.nozzleMaterial ?? ""),
                "the catalogue's nozzle material was overwritten")
    }

    @Test("a printer with no name and no model is not written")
    func unnamedPrinterIsSkipped() async throws {
        let engine = try KhaytEngine()
        var setup = ShopSetup()
        setup.printer = ShopSetup.Printer(price: 2000)
        var root: [String: JSONValue] = [:]
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: "Shop rates")
        #expect(root["machines"] == nil)
    }

    // MARK: - The other answers, through their own writers

    @Test("currency and VAT go through the Settings rule")
    func settingsThroughTheRule() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object(["currency": .string("SAR")])]
        var setup = ShopSetup()
        setup.currency = "USD"
        setup.chargesVat = true
        setup.vatRate = 5
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: "Shop rates")
        let settings = Shop.settings(root)
        #expect(settings["currency"] == .string("USD"))
        #expect(settings["enableVat"] == .bool(true))
        #expect(Shop.plainNumber(settings["vatRate"]) == 5)
    }

    @Test("the electricity tariff becomes one preset, replaced rather than duplicated")
    func electricityPreset() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = [:]
        var setup = ShopSetup()
        setup.electricity = 0.25
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: "Shop rates")
        setup.electricity = 0.3
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: "Shop rates")
        let presets = Shop.rows(root, "printers").compactMap(Shop.Preset.from)
        #expect(presets.count == 1)
        #expect(presets.first?.name == "Shop rates")
        #expect(presets.first?.rates["elecRate"] == 0.3)
        // The other six are Khayt's openers, not zeros.
        let openers = try await engine.printRates()
        #expect(presets.first?.rates["laborRate"] == openers["laborRate"])
        #expect((presets.first?.rates["failureRate"] ?? 0) > 0)
    }

    @Test("re-running the setup changes only the tariff on a preset the shop customised")
    func setupKeepsCustomisedPreset() async throws {
        let engine = try KhaytEngine()
        let was: [String: JSONValue] = [
            "id": .string("PRNTR-OWN"), "name": .string("Shop rates"),
            "wearRate": .string("0.5"), "powerDraw": .number(200), "elecRate": .number(0.1),
            "laborRate": .number(120), "failureRate": .number(25), "prepTime": .number(0.3),
            "postTime": .number(0.2), "slicerProfile": .string("fine"),
        ]
        var root: [String: JSONValue] = ["printers": .array([.object(was)])]
        var setup = ShopSetup()
        setup.electricity = 0.3
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: "Shop rates")
        let rows = Shop.rows(root, "printers")
        #expect(rows.count == 1)
        guard case .object(let now)? = rows.first else { return }
        #expect(now["elecRate"] == .number(0.3))
        var others = now
        others.removeValue(forKey: "elecRate")
        others.removeValue(forKey: Shop.setupPresetMarker)
        var before = was
        before.removeValue(forKey: "elecRate")
        #expect(others == before, "the shop's own rates were reset to Khayt's openers")
    }

    @Test("the setup run in English then Arabic keeps one preset")
    func setupPresetAcrossLanguages() async throws {
        let engine = try KhaytEngine()
        let names = Words.own["mac.setup_preset_name"] ?? [:]
        let en = try #require(names["en"]), ar = try #require(names["ar"])
        #expect(ShopSetup.presetNames.contains(en) && ShopSetup.presetNames.contains(ar))

        var root: [String: JSONValue] = [:]
        var setup = ShopSetup()
        setup.electricity = 0.25
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: en)
        setup.electricity = 0.3
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: ar)
        var presets = Shop.rows(root, "printers").compactMap(Shop.Preset.from)
        #expect(presets.count == 1, "two presets: \(presets.map(\.name))")
        #expect(presets.first?.name == en, "the preset was renamed")
        #expect(presets.first?.rates["elecRate"] == 0.3)

        // A preset made before the marker existed is found by its Arabic name.
        var legacy: [String: JSONValue] = [
            "printers": .array([.object(["id": .string("PRNTR-AR"), "name": .string(ar),
                                         "elecRate": .number(0.1), "laborRate": .number(70)])])]
        try await ShopSetup.apply(setup, to: &legacy, engine: engine, presetName: en)
        presets = Shop.rows(legacy, "printers").compactMap(Shop.Preset.from)
        #expect(presets.map(\.id) == ["PRNTR-AR"])
        #expect(presets.first?.rates["laborRate"] == 70)
        #expect(presets.first?.rates["elecRate"] == 0.3)
    }

    @Test("the filament becomes the first spool, through the spool rule")
    func filamentSpool() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = [:]
        var setup = ShopSetup()
        setup.filament = ShopSetup.Filament(material: "PETG", cost: 90, weight: 1000)
        try await ShopSetup.apply(setup, to: &root, engine: engine, presetName: "Shop rates",
                                  spoolId: "INV-TEST", today: "2026-10-01")
        let shelf = Shop.rows(root, "inventory")
        #expect(shelf.count == 1)
        guard case .object(let spool)? = shelf.first else { return }
        #expect(spool["id"] == .string("INV-TEST"))
        #expect(spool["material"] == .string("PETG"))
        #expect(Shop.plainNumber(spool["cost"]) == 90)
        #expect(Shop.plainNumber(spool["weight"]) == 1000)
    }

    // MARK: - Starting a book

    @Test("a new book is started only where there is none")
    func startEmptyBook() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Khayt/khayt-store.json")

        try Shop.startEmptyBook(at: url)
        #expect(try Data(contentsOf: url) == Data("{}".utf8))

        // Never over a book that is there…
        try Data(#"{"machines":[{"id":"M1"}]}"#.utf8).write(to: url)
        #expect(throws: (any Error).self) { try Shop.startEmptyBook(at: url) }
        #expect(try Data(contentsOf: url) == Data(#"{"machines":[{"id":"M1"}]}"#.utf8))

        // …nor over the rollback an interrupted save leaves, which the reader
        // puts back on open.
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("prev"))
        #expect(throws: (any Error).self) { try Shop.startEmptyBook(at: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - It fits a laptop

    @Test("every step fits a 13-inch laptop, buttons included")
    func fitsALaptop() async {
        let shop = Shop()
        await shop.load(.sample)
        var measured: [(String, CGFloat)] = []
        SheetsFitALaptopTests.onALaptop {
            for step in ShopSetupSheet.Step.allCases {
                measured.append(("\(step)", SheetsFitALaptopTests.height(
                    of: ShopSetupSheet(shop: shop, step: step, prefill: Self.filledIn),
                    width: SheetMetrics.outerWidth(ShopSetupSheet.width))))
            }
        }
        for (name, height) in measured {
            #expect(height <= SheetsFitALaptopTests.ceiling,
                    "the \(name) step is \(Int(height))pt, taller than a laptop's \(Int(SheetsFitALaptopTests.ceiling))pt")
        }
    }

    // MARK: - Helpers

    /// A setup with every step answered, for the pictures and the fit check.
    static var filledIn: ShopSetup {
        var s = ShopSetup()
        s.currency = "SAR"
        s.electricity = 0.18
        s.chargesVat = true
        s.vatRate = 15
        s.printer = ShopSetup.Printer(name: "Bambu Lab X1 Carbon", powerDraw: 350, price: 5999,
                                      bought: Self.day(2026, 2, 14),
                                      lifeHours: 5000)
        s.filament = ShopSetup.Filament(material: "PLA", cost: 89, weight: 1000)
        return s
    }

    /// A purchase date for a fixture — a fact about a printer, not a clock,
    /// and built from parts so it cannot be read as one (`SampleClockTests`).
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        Calendar.book.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
    }

    static func onlyMachine(_ root: [String: JSONValue]) -> [String: JSONValue]? {
        let floor = Shop.rows(root, "machines")
        guard floor.count == 1, case .object(let m) = floor[0] else { return nil }
        return m
    }
}

/// The setup's four steps, photographed — light and dark, in whatever language
/// `KHAYT_LANG` asks for. Nothing is written without `KHAYT_SNAPSHOT_DIR`.
extension SnapshotTests {
    @Test("the first-run setup renders, every step")
    func setupSteps() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.readCatalog()
        let lang = ProcessInfo.processInfo.environment["KHAYT_LANG"] ?? "en"
        let size = CGSize(width: SheetMetrics.outerWidth(ShopSetupSheet.width), height: 480)
        for step in ShopSetupSheet.Step.allCases {
            let sheet = ShopSetupSheet(shop: shop, step: step, prefill: ShopSetupTests.filledIn)
            try render(sheet.background(Khayt.surface), "90-setup-\(step.rawValue + 1)-\(step)-\(lang)", size: size)
            try renderDark(sheet.background(Khayt.surface), "90-setup-\(step.rawValue + 1)-\(step)-\(lang)-dark",
                           size: size)
        }
    }
}
