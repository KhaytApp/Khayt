import Foundation
import KhaytCore

/// What a new shop told the first-run setup, and how it reaches the book.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// A shop that has just installed Khayt opens a book with nothing in it, and
/// every figure the app is built around — what a print cost, what the machine
/// wears, what the electricity came to, what to quote — is worked out from
/// things nobody has typed yet. So the screens that should sell the app say
/// nothing, and the person who came to see what it does leaves having seen an
/// empty window.
///
/// The setup asks for the handful of facts those figures start from: the
/// currency and VAT, the electricity tariff, one printer with what it cost and
/// how long it should last, and what a spool costs. Every one is optional and
/// nothing blocks — a shop that skips all of it is exactly where it was.
///
/// ── NO WRITE OF ITS OWN ───────────────────────────────────────────────────
///
/// Every answer goes through the seam the screen that normally writes it uses:
///
/// | answer                | seam                    | the screen it belongs to |
/// |-----------------------|-------------------------|--------------------------|
/// | currency, VAT         | `Shop.applySettings`    | Settings → Business      |
/// | a printer, its value  | `Shop.writeMachine`     | the Machine sheet        |
/// | electricity per kWh   | `Shop.writePreset`      | Calculator → Save preset |
/// | a spool and its price | `Shop.writeNewSpool`    | the Spool sheet          |
///
/// and the machine's input is the sheet's own `MachineSheet.Form`, as a new
/// machine opens it, through the `input()` the sheet's Save uses. `ShopSetupTests` holds the machine the
/// setup writes to the one the sheet writes.
///
/// ── WHERE THE ELECTRICITY GOES, AND WHY THERE ─────────────────────────────
///
/// Neither app has a shop-wide tariff. `lib/print-rates.js` takes `elecRate`
/// from Khayt's opening figures (0.18) or from a calculator preset, and the
/// preset is the only place a shop has ever been able to write its own down.
/// So the tariff is saved as a preset carrying Khayt's openers for the other
/// six figures — the Calculator and the online quote offer it by name. The
/// step says so rather than implying every job is now costed at it.
@MainActor
struct ShopSetup: Equatable {

    // ── Step 1: the shop ─────────────────────────────────────────────────
    /// Nil leaves the book's currency as it is.
    var currency: String?
    /// Per kWh, in the shop's currency. Nil or zero writes no preset.
    var electricity: Double?
    /// Nil leaves VAT as it is; set means the shop answered the question.
    var chargesVat: Bool?
    var vatRate: Double = 15

    // ── Step 2: the printer ──────────────────────────────────────────────
    struct Printer: Equatable {
        var catalogId: String?
        var name = ""
        /// Watts while printing. Zero when the catalogue does not know and
        /// the shop did not say — the rule stores that as no figure at all.
        var powerDraw: Double = 0
        var nozzleDiameter: Double = 0.4
        var nozzleMaterial = "brass"
        /// The Value tab. A price of zero is no depreciation, which is what
        /// the rule makes of it too.
        var price: Double = 0
        var bought: Date?
        /// Print hours. 5,000 is a conservative life for a hobby-class
        /// machine run as a small business — the Value tab's own hint.
        var lifeHours: Double = 5000
    }
    var printer: Printer?

    // ── Step 3: the filament ─────────────────────────────────────────────
    struct Filament: Equatable {
        var material = "PLA"
        /// What one spool cost, in the shop's currency.
        var cost: Double = 0
        /// Grams on a full spool.
        var weight: Double = 1000
    }
    var filament: Filament?

    nonisolated static let defaultLifeHours: Double = 5000

    // MARK: - What would be written

    /// The machine's name as it will be written: what was typed, else the
    /// model's. Empty means no machine.
    var printerName: String {
        (printer?.name ?? "").trimmingCharacters(in: .whitespaces)
    }

    var writesPrinter: Bool { printer != nil && !printerName.isEmpty }
    var writesFilament: Bool {
        guard let f = filament else { return false }
        return f.cost > 0 && !f.material.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var writesElectricity: Bool { (electricity ?? 0) > 0 }

    /// The Settings form, carrying ONLY what the shop answered. Nil when it
    /// answered nothing on that step, so no settings save runs at all.
    func settingsForm(currentCurrency: String, currentlyChargesVat: Bool,
                      currentVatRate: Double) -> [String: JSONValue]? {
        var form: [String: JSONValue] = [:]
        if let currency, currency != currentCurrency { form["currency"] = .string(currency) }
        if let chargesVat, chargesVat != currentlyChargesVat
            || (chargesVat && vatRate != currentVatRate) {
            form["enableVat"] = .bool(chargesVat)
            form["vatRate"] = .number(max(0, vatRate))
        }
        return form.isEmpty ? nil : form
    }

    /// The machine exactly as the Machine sheet would send it for a new
    /// printer with these fields filled and everything else left alone: the
    /// sheet's own `Form`, as a new machine opens it, through the sheet's own
    /// `input()`.
    var machineForm: MachineSheet.Form? {
        guard let p = printer, writesPrinter else { return nil }
        var f = MachineSheet.Form()
        f.name = printerName
        f.powerDraw = p.powerDraw
        f.nozzleDiameter = p.nozzleDiameter
        f.nozzleMaterial = p.nozzleMaterial
        f.depPrice = max(0, p.price)
        f.depBought = p.bought
        f.depLife = max(0, p.lifeHours)
        f.loadedRows = LoadedRow.rows(for: nil)
        return f
    }

    var machineInput: [String: JSONValue]? { machineForm?.input() }

    /// The spool, as the Spool sheet's Add sends one.
    var spoolInput: [String: JSONValue]? {
        guard let f = filament, writesFilament else { return nil }
        return [
            "material": .string(f.material.trimmingCharacters(in: .whitespaces)),
            "color": .string("#888888"),
            "cost": .number(f.cost),
            "weight": .number(max(1, f.weight)),
        ]
    }


    /// Would Finish write anything at all?
    func writesAnything(currentCurrency: String, currentlyChargesVat: Bool,
                        currentVatRate: Double) -> Bool {
        writesPrinter || writesFilament || writesElectricity
            || settingsForm(currentCurrency: currentCurrency, currentlyChargesVat: currentlyChargesVat,
                            currentVatRate: currentVatRate) != nil
    }

    // MARK: - The write

    /// Everything, against the book as it is on disk, in one pass — so a
    /// setup lands whole or not at all. The seam the tests use.
    ///
    /// Settings FIRST: the machine's nozzle threshold and the rules after it
    /// read the settings, and they should read the ones the shop just chose.
    static func apply(_ setup: ShopSetup, to root: inout [String: JSONValue],
                      engine: KhaytEngine, presetName: String,
                      machineId: String = Shop.uid("MACH"), spoolId: String = Shop.uid("INV"),
                      today: String = Shop.today()) async throws {
        let held = Shop.settings(root)
        let rates = Self.settingsReading(held)
        if let form = setup.settingsForm(currentCurrency: rates.currency,
                                         currentlyChargesVat: rates.chargesVat,
                                         currentVatRate: rates.vatRate) {
            try await Shop.applySettings(to: &root, form: form, country: nil, engine: engine)
        }
        if let input = setup.machineInput {
            // A NEW machine: nothing was opened, so `opened` is nil — the
            // same as the Machine sheet's Add.
            try await Shop.writeMachine(into: &root, input: input, id: nil,
                                        catalogId: setup.printer?.catalogId, opened: nil,
                                        engine: engine, newId: machineId)
        }
        if setup.writesElectricity, let tariff = setup.electricity {
            Shop.writeSetupPreset(into: &root, name: presetName, aliases: Self.presetNames,
                                  tariff: tariff, openers: try? await engine.printRates())
        }
        if let input = setup.spoolInput {
            _ = try await Shop.writeNewSpool(into: &root, input: input, engine: engine,
                                             newId: spoolId, today: today)
        }
    }

    /// Every name the setup's preset has gone by, in every language this app
    /// speaks. The name is localised, so a shop that ran the setup in English
    /// and again in Arabic must still find the ONE preset it made.
    static var presetNames: [String] {
        Words.own["mac.setup_preset_name"].map { Array($0.values) } ?? []
    }

    /// The three settings step 1 compares against, as the book holds them.
    static func settingsReading(_ settings: [String: JSONValue])
        -> (currency: String, chargesVat: Bool, vatRate: Double) {
        let currency: String
        if case .string(let c)? = settings["currency"], !c.isEmpty { currency = c } else { currency = "SAR" }
        let vat: Bool
        if case .bool(let b)? = settings["enableVat"] { vat = b } else { vat = false }
        let rate = Shop.plainNumber(settings["vatRate"]) ?? 15
        return (currency, vat, rate)
    }

    // MARK: - When to offer it

    /// Should the setup open by itself?
    ///
    /// Two cases, and only two:
    ///
    /// - **A real book with nothing in it** — no machine and no job. Whatever
    ///   else is on the shelf, a book with neither has never costed anything.
    ///   It must also be one this app may write; a book the other app holds
    ///   cannot take the answers.
    /// - **No book on this Mac at all.** The app opens on the sample then, and
    ///   the setup is how a shop starts its own.
    ///
    /// Never for the sample while a real book exists, never for a book with
    /// data, and never once the shop has closed it — see `Shop.setupDismissed`.
    static func offers(isReal: Bool, canWrite: Bool, machines: Int, orders: Int,
                       aRealBookExists: Bool) -> Bool {
        if isReal { return canWrite && machines == 0 && orders == 0 }
        return !aRealBookExists
    }
}
