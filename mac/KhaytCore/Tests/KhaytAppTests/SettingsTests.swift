import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Settings window writes through `lib/settings-edit.js`, the same rule the
/// Electron page saves through. The RULE is tested where it lives, against the
/// original literal, over thousands of cases. What is tested here is that this
/// app hands it the right form: that every field on every pane reaches the
/// record under the key the rule knows, that a pane saves only what it shows,
/// and that the two small tables spelled out in Swift still match the module.
@MainActor
struct SettingsTests {

    static func sample() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        try #require(shop.engine != nil, "the shared rules did not start")
        return shop
    }

    static func engine(_ shop: Shop) throws -> KhaytEngine { try #require(shop.engine) }

    static func string(_ v: JSONValue?) -> String? { Shop.plainString(v) }
    static func number(_ v: JSONValue?) -> Double? { Shop.plainNumber(v) }
    static func object(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    // MARK: - Every field on every pane reaches the record

    /// Read → change every field → save → read back must return the change.
    /// A form key the rule does not know would leave the stored value in place
    /// and this is the test that notices, for every field rather than a sample.

    @Test("the Business pane round-trips every field")
    func business() async throws {
        let shop = try await Self.sample()
        var draft = BusinessPane.Draft.read(shop.settingsDict, shop: shop)
        draft.phone = "+966 55 000 0001"; draft.email = "shop@example.com"
        draft.vat = "310000000000003"; draft.cr = "1010101010"
        for key in draft.content.keys { draft.content[key] = "edited " + key }
        let out = try await Self.engine(shop).applySettings(shop.settingsDict, form: draft.form(), year: 2026)
        #expect(BusinessPane.Draft.read(out, shop: shop) == draft)
        #expect(Self.string(out["bizEn"]) == "edited bizEn", "the shop's text lands under the store's own key")
    }

    @Test("the Invoice pane round-trips every field")
    func invoice() async throws {
        let shop = try await Self.sample()
        var draft = InvoicePane.Draft.read(shop.settingsDict, shop: shop)
        draft.currency = "EUR"; draft.enableVat = true; draft.vatRate = 19; draft.taxMode = "exclusive"
        draft.enableZatca = false; draft.invPrefix = "FAC"; draft.quotePrefix = "DEV"
        draft.invTemplate = "minimal"; draft.invoiceBilingual = "both"; draft.invoiceSecondLang = "fr"
        draft.invAccent = "#123456"
        for key in draft.content.keys { draft.content[key] = "edited " + key }
        let out = try await Self.engine(shop).applySettings(shop.settingsDict, form: draft.form(), year: 2026)
        #expect(InvoicePane.Draft.read(out, shop: shop) == draft)
        // And the profile the invoice is computed from agrees with the legacy
        // fields — the rule's whole reason for rebuilding `tax`.
        let tax = Self.object(out["tax"])
        #expect(Self.string(tax["mode"]) == "exclusive")
        if case .array(let rates)? = tax["rates"], let first = rates.first {
            #expect(Self.number(Self.object(first)["percent"]) == 19)
        } else {
            Issue.record("the rebuilt profile has no rate")
        }
    }

    @Test("the Payments pane round-trips every field")
    func payments() async throws {
        let shop = try await Self.sample()
        var draft = PaymentsPane.Draft.read(shop.settingsDict, shop: shop)
        draft.bankName = "Al Rajhi"; draft.accountHolder = "Tuwaiq Additive"
        draft.iban = "SA0380000000608010167519"
        draft.accepted = ["mada", "cash"]; draft.paymentInstructions = "Pay at the counter."
        let out = try await Self.engine(shop).applySettings(shop.settingsDict, form: draft.form(), year: 2026)
        #expect(PaymentsPane.Draft.read(out, shop: shop) == draft)
        // Stored in Khayt's own order, not the set's.
        if case .array(let list)? = out["acceptedPayments"] {
            #expect(list.compactMap(Self.string) == ["cash", "mada"])
        }
    }

    @Test("an IBAN typed in groups of four is stored without the spaces")
    func iban() async throws {
        let shop = try await Self.sample()
        var draft = PaymentsPane.Draft.read(shop.settingsDict, shop: shop)
        draft.iban = "SA03 8000 0000 6080 1016 7519"
        let out = try await Self.engine(shop).applySettings(shop.settingsDict, form: draft.form(), year: 2026)
        #expect(Self.string(out["iban"]) == "SA0380000000608010167519")
    }

    @Test("the Operations pane round-trips every field")
    func operations() async throws {
        let shop = try await Self.sample()
        var draft = OperationsPane.Draft.read(shop.settingsDict, shop: shop)
        draft.minMarginPct = 12; draft.quoteValidityDays = 14; draft.minOrderAmount = 50
        draft.rushFeeEnabled = true; draft.rushFeePct = 30; draft.defaultPackagingCost = 4.5
        for day in OperationsPane.Draft.days { draft.hours[day] = 6 }
        draft.dailyHours = 10; draft.workingDaysPerWeek = 6; draft.finishingDays = 2
        draft.dispatchDays = 3; draft.safetyDays = 4; draft.publishToCloud = true
        draft.wip = ["pending": 5, "printing": 2, "post": 0, "qc": 1]
        draft.wipEnforceHardLimit = true
        draft.qcEnabled = true; draft.qcRequireInspector = true; draft.qcRequirePhotoOnFail = true
        draft.qcWarrantyDays = 45
        draft.monthlyGoal = 9000
        draft.budgets = ["filament": 1500, "electricity": 500, "maintenance": 300,
                         "tools": 250, "shipping": 200, "other": 300]
        draft.payReminderEnabled = true; draft.payReminderGrace = 7
        draft.quoteFollowUpEnabled = true; draft.quoteFollowUpWindow = 5
        let out = try await Self.engine(shop).applySettings(shop.settingsDict, form: draft.form(), year: 2026)
        #expect(OperationsPane.Draft.read(out, shop: shop) == draft)
        // A WIP limit of zero is no limit, and is not stored as a zero.
        #expect(Self.object(out["wipLimits"])["post"] == nil)
    }

    /// A budget the Spending screen draws a bar against.
    ///
    /// That screen has read `expBudgets` since it was built, and until now
    /// nothing in this app could write one — so every shop looked at a bar
    /// measured against zero. The two ends are checked together here, because
    /// a settings field that saves to a key the report does not read is the
    /// same amount of nothing.
    @Test("a budget set in Operations is the budget the Spending screen reads")
    func budgetsReachTheReport() async throws {
        let shop = try await Self.sample()
        var draft = OperationsPane.Draft.read(shop.settingsDict, shop: shop)
        draft.budgets["filament"] = 1500
        draft.budgets["electricity"] = 400
        let out = try await Self.engine(shop).applySettings(shop.settingsDict, form: draft.form(), year: 2026)

        let stored = Self.object(out["expBudgets"])
        #expect(Self.number(stored["filament"]) == 1500)
        #expect(Self.number(stored["electricity"]) == 400)

        // And the report agrees, through the module that draws the bar.
        let rows = try await Self.engine(shop).budgetProgress(
            ["filament": 2130, "electricity": 100], budgets: stored)
        let filament = try #require(rows.first { $0.category == "filament" })
        #expect(filament.budget == 1500)
        #expect(filament.over, "2,130 spent against 1,500 is over")
        let electricity = try #require(rows.first { $0.category == "electricity" })
        #expect(!electricity.over)
    }

    /// THE TRAP in `settings-edit.js`: when the form carries `budgets` at all,
    /// it REBUILDS `expBudgets` from its own category list rather than merging.
    /// A pane that sent only the categories a shop had touched would silently
    /// zero the rest, so the form sends all six every time.
    @Test("saving one budget does not zero the other five")
    func budgetsAreNotPartial() async throws {
        let shop = try await Self.sample()
        var first = OperationsPane.Draft.read(shop.settingsDict, shop: shop)
        for category in Shop.expenseCategories { first.budgets[category] = 100 }
        let once = try await Self.engine(shop).applySettings(
            shop.settingsDict, form: first.form(), year: 2026)

        var second = OperationsPane.Draft.read(once, shop: shop)
        second.budgets["filament"] = 999
        let twice = try await Self.engine(shop).applySettings(once, form: second.form(), year: 2026)

        let stored = Self.object(twice["expBudgets"])
        #expect(Self.number(stored["filament"]) == 999)
        for category in Shop.expenseCategories where category != "filament" {
            #expect(Self.number(stored[category]) == 100,
                    "\(category) was zeroed by a save that never mentioned it")
        }
    }

    @Test("the Preferences pane round-trips every field")
    func preferences() async throws {
        let shop = try await Self.sample()
        var draft = PreferencesPane.Draft.read(shop.settingsDict, shop: shop)
        draft.lang = "ar"; draft.useHijri = false; draft.useArabicNumerals = true
        draft.autoDeduct = false; draft.lowStock = 350
        let out = try await Self.engine(shop).applySettings(shop.settingsDict, form: draft.form(), year: 2026)
        #expect(PreferencesPane.Draft.read(out, shop: shop) == draft)
    }

    // MARK: - A pane saves only what it shows

    @Test("saving the Business pane leaves the other panes' settings alone")
    func onlyItsOwn() async throws {
        let shop = try await Self.sample()
        let engine = try Self.engine(shop)
        var settings = shop.settingsDict
        settings["wipLimits"] = .object(["pending": .number(3)])
        settings["lowStockThreshold"] = .number(50)
        settings["enableVat"] = .bool(true)
        settings["cloud"] = .object(["token": .string("T")])
        var draft = BusinessPane.Draft.read(settings, shop: shop)
        draft.phone = "055"
        let out = try await engine.applySettings(settings, form: draft.form(), year: 2026)
        #expect(Self.string(out["phone"]) == "055")
        #expect(Self.object(out["wipLimits"]) == ["pending": .number(3)], "the WIP limits it never showed are kept")
        #expect(Self.number(out["lowStockThreshold"]) == 50)
        #expect(Self.string(Self.object(out["cloud"])["token"]) == "T", "the cloud keyset survives — it was lost this way once")
        #expect(out["tax"] == settings["tax"], "the tax profile is not rebuilt by a pane that does not show it")
    }

    // MARK: - Choosing a country

    @Test("a country chosen for tax rules lands name, label, convention and rate together")
    func country() async throws {
        let shop = try await Self.sample()
        let engine = try Self.engine(shop)
        var root: [String: JSONValue] = ["settings": .object(shop.settingsDict)]
        var draft = InvoicePane.Draft.read(shop.settingsDict, shop: shop)
        draft.taxCountry = "IN"
        // What the pane fills in when a country is picked, before the save.
        let preset = try #require(shop.taxPresets["IN"])
        draft.taxMode = preset.mode.rawValue
        draft.enableVat = !preset.rates.isEmpty
        draft.vatRate = preset.rates.first?.percent ?? 0
        try await Shop.applySettings(to: &root, form: draft.form(), country: draft.taxCountry, engine: engine)
        let tax = Self.object(Self.object(root["settings"])["tax"])
        #expect(Self.string(tax["country"]) == "IN")
        #expect(Self.string(tax["name"]) == "GST")
        #expect(Self.string(tax["registration"]) == "GSTIN", "the registration number is called what India calls it")
        #expect(Self.string(tax["mode"]) == "exclusive")
        if case .array(let rates)? = tax["rates"] { #expect(rates.count == 2, "CGST and SGST, both") }
        else { Issue.record("no rates") }
    }

    @Test("saving with the country unchanged does not re-apply its preset over a hand-set rate")
    func countryUnchanged() async throws {
        let shop = try await Self.sample()
        let engine = try Self.engine(shop)
        var settings = shop.settingsDict
        settings = try await engine.chooseTaxCountry(settings, code: "SA")
        var root: [String: JSONValue] = ["settings": .object(settings)]
        var draft = InvoicePane.Draft.read(settings, shop: shop)
        draft.vatRate = 5   // a shop on a special rate
        try await Shop.applySettings(to: &root, form: draft.form(), country: draft.taxCountry, engine: engine)
        let tax = Self.object(Self.object(root["settings"])["tax"])
        if case .array(let rates)? = tax["rates"], let first = rates.first {
            #expect(Self.number(Self.object(first)["percent"]) == 5, "the preset's 15% must not overwrite the shop's 5%")
        } else { Issue.record("no rates") }
    }

    // MARK: - On disk

    @Test("the write reaches the file, and the rest of the book with it")
    func onDisk() async throws {
        let shop = try await Self.sample()
        let engine = try Self.engine(shop)
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        let book: [String: JSONValue] = [
            "printLog": .array([.object(["id": .string("J1"), "project": .string("Bracket")])]),
            "settings": .object(["phone": .string("050"), "wipLimits": .object(["qc": .number(2)])]),
        ]
        try JSONEncoder().encode(book).write(to: url)

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            try await Shop.applySettings(to: &root, form: ["phone": .string(" 055 ")], country: nil, engine: engine)
        }
        let back = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        let settings = Self.object(back["settings"])
        #expect(Self.string(settings["phone"]) == "055", "trimmed, and on disk")
        #expect(Self.object(settings["wipLimits"]) == ["qc": .number(2)])
        #expect(settings["firstRunDone"] == .bool(true))
        if case .array(let jobs)? = back["printLog"] { #expect(jobs.count == 1, "the jobs are untouched") }
        else { Issue.record("the jobs were lost") }
    }

    @Test("the sample shop's settings cannot be saved, and it says so")
    func sampleRefused() async throws {
        let shop = try await Self.sample()
        await shop.saveSettings(["phone": .string("055")])
        #expect(shop.settingsProblem == shop.words.callIt("mac.settings_sample"))
        #expect(shop.settingsNote == nil)
    }

    // MARK: - The shop's name

    @Test("the shop's name is the one its documents print, not a field nothing writes")
    func shopName() async throws {
        let shop = try await Self.sample()
        let engine = try Self.engine(shop)
        // What this Mac's own book actually holds: bizEn and bizAr, no shopName.
        let book: [String: JSONValue] = ["bizEn": .string("Athar Tuwaiq"), "bizAr": .string("اثر طويق")]
        #expect(await Shop.shopName(from: book, engine: engine, language: "en") == "Athar Tuwaiq")
        #expect(await Shop.shopName(from: book, engine: engine, language: "ar") == "اثر طويق")
        // A shop that writes only Arabic is shown its Arabic name on an English
        // Mac, not a blank and not the stale English one.
        let arabicOnly: [String: JSONValue] = ["bizAr": .string("اثر طويق"), "contentLangs": .array([.string("ar")])]
        #expect(await Shop.shopName(from: arabicOnly, engine: engine, language: "en") == "اثر طويق")
        #expect(await Shop.shopName(from: [:], engine: engine, language: "en") == nil)
        // And the sample is written the way Khayt writes a shop.
        #expect(shop.shopName == "Tuwaiq Additive")
    }

    // MARK: - The two tables spelled out in Swift

    @Test("the content field keys match lib/content-languages.js for every base and language")
    func fieldKeys() async throws {
        let shop = try await Self.sample()
        let engine = try Self.engine(shop)
        for base in ["biz", "tagline", "addr", "footer", "invTerms"] {
            for (code, _) in shop.writableLanguages {
                #expect(try await engine.fieldKey(base, language: code) == Shop.contentKey(base, code),
                        "\(base)/\(code)")
            }
        }
    }

    @Test("the language names match lib/content-languages.js")
    func languageNames() async throws {
        let shop = try await Self.sample()
        let engine = try Self.engine(shop)
        for (code, name) in shop.writableLanguages {
            #expect(try await engine.languageName(code) == name, "\(code)")
        }
    }

    @Test("a pane's fields are built from the languages the shop writes in")
    func contentFields() async throws {
        let shop = try await Self.sample()
        let fields = shop.contentFields(["biz"])
        #expect(fields.map(\.language) == shop.contentLanguages)
        #expect(fields.allSatisfy { $0.label.contains(" · ") }, "labelled with the language's own name")
    }

    /// No pane may head two sections with the same words.
    ///
    /// The Preferences pane printed "App Preferences" twice, two rows apart —
    /// the language picker under one and the Mac-local menu bar toggle under
    /// the other, with nothing to say which of them follows the book to the
    /// shop's other devices. Two sections with one name read as one section
    /// with a gap in it.
    ///
    /// It survived because the settings window had never been photographed:
    /// the snapshot runner looks for it among `NSApp.windows` and an orphaned
    /// Khayt holding the status bar made it give up. Source, not a picture,
    /// because the picture is not something CI can take.
    @Test("no settings pane heads two sections with the same words")
    func sectionHeadingsAreDistinct() throws {
        let src = try Self.settingsSource()
        // Sliced per pane, because two PANES may of course share a heading —
        // it is two sections within one that read as a mistake.
        for pane in ["BusinessPane", "InvoicePane", "PaymentsPane",
                     "OperationsPane", "SlicersPane", "PreferencesPane"] {
            guard let at = src.range(of: "struct \(pane): View") else {
                Issue.record(Comment(rawValue: "\(pane) is gone — this guard is stale"))
                continue
            }
            let rest = src[at.upperBound...]
            let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
            let body = rest[..<end]

            var seen: [String: Int] = [:]
            var from = body.startIndex
            while let open = body.range(of: "Section(shop.words.callIt(\"", range: from..<body.endIndex) {
                guard let close = body.range(of: "\")", range: open.upperBound..<body.endIndex) else { break }
                seen[String(body[open.upperBound..<close.lowerBound]), default: 0] += 1
                from = close.upperBound
            }
            for (key, n) in seen where n > 1 {
                Issue.record(Comment(rawValue:
                    "\(pane) heads \(n) sections with \(key) — give each its own words"))
            }
        }
    }

    static func settingsSource() throws -> String {
        // Walked up from this file rather than taken from Bundle.module: under
        // the test runner that bundle is the runner's, not the app's.
        var dir = URL(fileURLWithPath: #filePath)
        // SettingsTests.swift -> KhaytAppTests -> Tests -> KhaytCore
        for _ in 0..<3 { dir = dir.deletingLastPathComponent() }
        let url = dir.appending(path: "Sources/KhaytApp/SettingsWindow.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
