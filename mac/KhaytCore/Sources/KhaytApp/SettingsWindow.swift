import SwiftUI
import AppKit
import KhaytCore

/// The panes of the Settings window, in the order Khayt's own page has them.
enum SettingsPane: String, CaseIterable, Identifiable {
    case business, invoice, payments, operations, slicers, preferences
    var id: String { rawValue }
}

/// The shop's own settings — ⌘, — in six panes.
///
/// Each pane is its own draft with its own Save. A pane saves ONLY the keys it
/// shows, and `lib/settings-edit.js` keeps everything else as it finds it: the
/// Business pane saving a phone number does not touch the WIP limits, and the
/// rule that says so is the same rule the Electron page saves through, proven
/// against it field for field.
///
/// Explicit Save rather than save-on-keystroke, because each save is an atomic
/// swap of the shop's whole book: a book rewritten on every character typed
/// into an address is a book rewritten a hundred times to change one line.
struct SettingsWindow: View {
    @Bindable var shop: Shop

    var body: some View {
        TabView(selection: $shop.settingsPane) {
            BusinessPane(shop: shop)
                .tabItem { Label(shop.words.callIt("set.nav_biz"), systemImage: "building.2") }
                .tag(SettingsPane.business)
            InvoicePane(shop: shop)
                .tabItem { Label(shop.words.callIt("set.nav_invoice"), systemImage: "doc.text") }
                .tag(SettingsPane.invoice)
            PaymentsPane(shop: shop)
                .tabItem { Label(shop.words.callIt("set.nav_payments"), systemImage: "creditcard") }
                .tag(SettingsPane.payments)
            OperationsPane(shop: shop)
                .tabItem { Label(shop.words.callIt("set.nav_ops"), systemImage: "gearshape.2") }
                .tag(SettingsPane.operations)
            SlicersPane(shop: shop)
                .tabItem { Label(shop.words.callIt("mac.nav_slicers"), systemImage: "cube.transparent") }
                .tag(SettingsPane.slicers)
            PreferencesPane(shop: shop)
                .tabItem { Label(shop.words.callIt("mac.preferences"), systemImage: "slider.horizontal.3") }
                .tag(SettingsPane.preferences)
        }
        .frame(width: 600, height: 640)
    }
}

// MARK: - Reading a draft out of the settings

/// The settings as a pane reads them: a string, a number, a flag, each with
/// the default the Electron page shows for an empty field.
@MainActor
struct SettingsReader {
    let settings: [String: JSONValue]
    func text(_ key: String, _ fallback: String = "") -> String {
        Shop.plainString(settings[key]).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
    func number(_ key: String, _ fallback: Double) -> Double {
        Shop.plainNumber(settings[key]) ?? fallback
    }
    /// A flag whose absence means ON — Khayt reads `settings.x !== false`.
    func onUnlessOff(_ key: String) -> Bool { Shop.plainBool(settings[key]) ?? true }
    func flag(_ key: String) -> Bool { Shop.plainBool(settings[key]) ?? false }
    func object(_ key: String) -> [String: JSONValue] {
        if case .object(let o)? = settings[key] { return o }
        return [:]
    }
}

// MARK: - The bar under every pane

/// Save and Revert, and what the last save said.
struct SaveBar: View {
    let shop: Shop
    let dirty: Bool
    let save: () -> Void
    let revert: () -> Void

    var body: some View {
        HStack {
            if let problem = shop.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Khayt.attention).font(.callout).lineLimit(2)
            } else if let note = shop.settingsNote, !dirty {
                Text(note).foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            Button(shop.words.callIt("mac.revert"), action: revert).disabled(!dirty)
            Button(shop.words.callIt("common.save"), action: save)
                .keyboardShortcut("s")
                .disabled(!dirty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// A labelled row inside a grouped Form.
private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
    LabeledContent(label) { content() }
}

// MARK: - Business

struct BusinessPane: View {
    let shop: Shop

    struct Draft: Equatable {
        /// The shop's own text, keyed by store field (`bizEn`, `addr_fr`…).
        var content: [String: String] = [:]
        var phone = "", email = "", vat = "", cr = ""

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            var d = Draft(phone: r.text("phone"), email: r.text("email"), vat: r.text("vat"), cr: r.text("cr"))
            for field in shop.contentFields(["biz", "tagline", "addr"]) { d.content[field.key] = r.text(field.key) }
            return d
        }
        func form() -> [String: JSONValue] {
            ["content": .object(content.mapValues(JSONValue.string)),
             "phone": .string(phone), "email": .string(email), "vat": .string(vat), "cr": .string(cr)]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("set.biz_identity")) {
                    ForEach(shop.contentFields(["biz", "tagline", "addr"]), id: \.key) { field in
                        row(field.label) {
                            TextField("", text: binding(field.key))
                                .environment(\.layoutDirection, field.language == "ar" ? .rightToLeft : .leftToRight)
                        }
                    }
                }
                Section(shop.words.callIt("set.biz_contact")) {
                    row(shop.words.callIt("set.phone")) { TextField("", text: $draft.phone) }
                    row(shop.words.callIt("set.email")) { TextField("", text: $draft.email) }
                }
                Section(shop.words.callIt("set.biz_tax")) {
                    // The registration number is called what the shop's tax
                    // rules call it — GSTIN, USt-IdNr., VAT No. — not always "VAT".
                    row(shop.taxProfile?.registration ?? shop.words.callIt("set.vat")) { TextField("", text: $draft.vat) }
                    row(shop.words.callIt("set.cr")) { TextField("", text: $draft.cr) }
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft.content[key] ?? "" }, set: { draft.content[key] = $0 })
    }
}

// MARK: - Invoice & tax

struct InvoicePane: View {
    let shop: Shop

    struct Draft: Equatable {
        var currency = "SAR"
        var taxCountry = ""
        var enableVat = false
        var vatRate = 15.0
        var taxMode = "inclusive"
        var enableZatca = false
        var invPrefix = "INV", quotePrefix = "QUO"
        var invTemplate = "classic"
        var invoiceBilingual = "auto", invoiceSecondLang = "ar"
        var invAccent = "#5E2E14"
        var content: [String: String] = [:]

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            var d = Draft(
                currency: r.text("currency", "SAR"),
                taxCountry: Shop.taxCountry(settings),
                enableVat: r.flag("enableVat"),
                vatRate: r.number("vatRate", 15),
                taxMode: Shop.taxMode(settings),
                enableZatca: r.onUnlessOff("enableZatca"),
                invPrefix: r.text("invPrefix", "INV"), quotePrefix: r.text("quotePrefix", "QUO"),
                invTemplate: r.text("invTemplate", "classic"),
                invoiceBilingual: r.text("invoiceBilingual", "auto"),
                invoiceSecondLang: r.text("invoiceSecondLang", "ar"),
                invAccent: r.text("invAccentColor", "#5E2E14"))
            for field in shop.contentFields(["footer", "invTerms"]) { d.content[field.key] = r.text(field.key) }
            return d
        }
        func form() -> [String: JSONValue] {
            ["currency": .string(currency), "taxCountry": .string(taxCountry),
             "enableVat": .bool(enableVat), "vatRate": .number(vatRate), "taxMode": .string(taxMode),
             "enableZatca": .bool(enableZatca),
             "invPrefix": .string(invPrefix), "quotePrefix": .string(quotePrefix),
             "invTemplate": .string(invTemplate), "invoiceBilingual": .string(invoiceBilingual),
             "invoiceSecondLang": .string(invoiceSecondLang), "invAccent": .string(invAccent),
             "content": .object(content.mapValues(JSONValue.string))]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var example = ""

    private var countries: [(code: String, name: String)] {
        shop.taxPresets.keys.map { code in
            (code, Locale.current.localizedString(forRegionCode: code) ?? code)
        }.sorted { $0.name < $1.name }
    }
    private var currencies: [(code: String, label: String)] {
        shop.currencies.map { ($0.key, $0.value.label) }.sorted { $0.label < $1.label }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("set.worldwide_section")) {
                    row(shop.words.callIt("set.currency")) {
                        Picker("", selection: $draft.currency) {
                            ForEach(currencies, id: \.code) { Text($0.label).tag($0.code) }
                        }.labelsHidden()
                    }
                    row(shop.words.callIt("set.tax_country")) {
                        Picker("", selection: $draft.taxCountry) {
                            Text(shop.words.callIt("set.tax_country_custom")).tag("")
                            ForEach(countries, id: \.code) { Text($0.name).tag($0.code) }
                        }.labelsHidden()
                    }
                    Toggle(shop.words.callIt("set.enable_vat"), isOn: $draft.enableVat)
                    row(shop.words.callIt("set.vat_rate")) {
                        TextField("", value: $draft.vatRate, format: .number.precision(.fractionLength(0...3)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            .disabled(!draft.enableVat)
                    }
                    row(shop.words.callIt("set.tax_mode")) {
                        Picker("", selection: $draft.taxMode) {
                            Text(shop.words.callIt("set.tax_mode_inclusive")).tag("inclusive")
                            Text(shop.words.callIt("set.tax_mode_exclusive")).tag("exclusive")
                        }.labelsHidden()
                    }
                    // The arithmetic on a round number, because inclusive and
                    // exclusive both look plausible and differ by the tax on
                    // every order.
                    Text(example).font(.callout).foregroundStyle(.secondary)
                    Toggle(shop.words.callIt("set.enable_zatca"), isOn: $draft.enableZatca)
                }
                Section(shop.words.callIt("set.invoice_section")) {
                    row(shop.words.callIt("set.invoice_prefix")) { TextField("", text: $draft.invPrefix).frame(width: 120) }
                    row(shop.words.callIt("set.quote_prefix")) { TextField("", text: $draft.quotePrefix).frame(width: 120) }
                    row(shop.words.callIt("set.inv_template")) {
                        Picker("", selection: $draft.invTemplate) {
                            Text(shop.words.callIt("set.inv_tmpl_classic")).tag("classic")
                            Text(shop.words.callIt("set.inv_tmpl_modern")).tag("modern")
                            Text(shop.words.callIt("set.inv_tmpl_minimal")).tag("minimal")
                        }.labelsHidden()
                    }
                    row(shop.words.callIt("set.inv_bilingual")) {
                        Picker("", selection: $draft.invoiceBilingual) {
                            Text(shop.words.callIt("set.inv_bilingual_auto")).tag("auto")
                            Text(shop.words.callIt("set.inv_bilingual_single")).tag("single")
                            Text(shop.words.callIt("set.inv_bilingual_both")).tag("both")
                        }.labelsHidden()
                    }
                    if draft.enableZatca {
                        Text(shop.words.callIt("set.inv_bilingual_zatca")).font(.callout).foregroundStyle(.secondary)
                    } else if draft.invoiceBilingual != "single" {
                        row(shop.words.callIt("set.inv_second_lang")) {
                            Picker("", selection: $draft.invoiceSecondLang) {
                                ForEach(shop.writableLanguages, id: \.code) { Text($0.name).tag($0.code) }
                            }.labelsHidden()
                        }
                    }
                    row(shop.words.callIt("set.inv_accent")) {
                        ColorPicker("", selection: accent, supportsOpacity: false).labelsHidden()
                    }
                    ForEach(shop.contentFields(["footer"]), id: \.key) { field in
                        row(field.label) {
                            TextField("", text: binding(field.key))
                                .environment(\.layoutDirection, field.language == "ar" ? .rightToLeft : .leftToRight)
                        }
                    }
                    ForEach(shop.contentFields(["invTerms"]), id: \.key) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label).foregroundStyle(.secondary)
                            TextEditor(text: binding(field.key)).frame(height: 60).font(.body)
                                .environment(\.layoutDirection, field.language == "ar" ? .rightToLeft : .leftToRight)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form(), country: draft.taxCountry); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
        .task(id: draft) { await explain() }
        .onChange(of: draft.taxCountry) { _, code in chose(code) }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft.content[key] ?? "" }, set: { draft.content[key] = $0 })
    }

    /// A country choice fills the rate and the convention in, the way Khayt's
    /// picker does — the shop can still change them before saving.
    ///
    /// Only a choice a PERSON made: `onChange` also fires when `reset` seeds the
    /// draft from the book, and applying the preset then marked every freshly
    /// opened pane as edited.
    private func chose(_ code: String) {
        guard !code.isEmpty, code != original.taxCountry,
              let preset = shop.taxPresets[code] else { return }
        draft.taxMode = preset.mode.rawValue
        draft.enableVat = !preset.rates.isEmpty
        if let first = preset.rates.first { draft.vatRate = first.percent }
    }

    /// "A price of 100 is invoiced as 100.00 — 86.96 plus 13.04 tax."
    private func explain() async {
        guard draft.enableVat, draft.vatRate > 0, let engine = shop.engine,
              let mode = TaxProfile.Mode(rawValue: draft.taxMode) else {
            example = shop.words.callIt("mac.tax_none"); return
        }
        let profile = TaxProfile(name: shop.taxProfile?.name ?? "VAT", mode: mode,
                                 registration: shop.taxProfile?.registration ?? "VAT No.",
                                 rates: [.init(id: "vat", label: "VAT", percent: draft.vatRate)])
        guard let split = try? await engine.computeTax(100, profile: profile) else { example = ""; return }
        example = shop.words.callIt("set.tax_mode_example", [
            "total": .string(Money.figure(split.subtotal + split.taxTotal)),
            "subtotal": .string(Money.figure(split.subtotal)),
            "tax": .string(Money.figure(split.taxTotal)),
        ])
    }

    /// The accent as a colour, and back to the hex the document is styled with.
    private var accent: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: draft.invAccent) ?? NSColor(red: 0.37, green: 0.18, blue: 0.08, alpha: 1)) },
            set: { draft.invAccent = NSColor($0).hexString ?? draft.invAccent })
    }
}

// MARK: - Payments

struct PaymentsPane: View {
    let shop: Shop

    struct Draft: Equatable {
        var bankName = "", accountHolder = "", iban = ""
        var accepted: Set<String> = []
        var paymentInstructions = ""

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            var accepted: Set<String> = []
            if case .array(let list)? = settings["acceptedPayments"] {
                accepted = Set(list.compactMap(Shop.plainString))
            }
            return Draft(bankName: r.text("bankName"), accountHolder: r.text("accountHolder"), iban: r.text("iban"),
                         accepted: accepted, paymentInstructions: r.text("paymentInstructions"))
        }
        @MainActor func form() -> [String: JSONValue] {
            ["bankName": .string(bankName), "accountHolder": .string(accountHolder), "iban": .string(iban),
             // In Khayt's own order, not the set's: the invoice lists them.
             "acceptedPayments": .array(Shop.paymentMethods.filter(accepted.contains).map(JSONValue.string)),
             "paymentInstructions": .string(paymentInstructions)]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("set.bank_section")) {
                    row(shop.words.callIt("set.bank_name")) { TextField("", text: $draft.bankName) }
                    row(shop.words.callIt("set.account_holder")) { TextField("", text: $draft.accountHolder) }
                    row(shop.words.callIt("set.iban")) {
                        TextField(shop.words.callIt("set.iban_ph"), text: $draft.iban).font(.body.monospaced())
                    }
                }
                Section(shop.words.callIt("set.accepted")) {
                    ForEach(Shop.paymentMethods, id: \.self) { method in
                        Toggle(shop.words.callIt("pay.method." + method), isOn: Binding(
                            get: { draft.accepted.contains(method) },
                            set: { if $0 { draft.accepted.insert(method) } else { draft.accepted.remove(method) } }))
                    }
                }
                Section(shop.words.callIt("set.payment_instructions")) {
                    TextEditor(text: $draft.paymentInstructions).frame(height: 70).font(.body)
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
}

// MARK: - Operations

struct OperationsPane: View {
    let shop: Shop

    struct Draft: Equatable {
        var minMarginPct = 0.0, quoteValidityDays = 7.0, minOrderAmount = 0.0
        var rushFeeEnabled = false, rushFeePct = 25.0, defaultPackagingCost = 0.0
        var hours: [String: Double] = [:]
        var dailyHours = 8.0, workingDaysPerWeek = 5.0, finishingDays = 1.0, dispatchDays = 1.0, safetyDays = 1.0
        var publishToCloud = false
        var wip: [String: Double] = [:]
        var wipEnforceHardLimit = false
        var qcEnabled = false, qcRequireInspector = false, qcRequirePhotoOnFail = false, qcWarrantyDays = 30.0
        var monthlyGoal = 0.0
        /// A monthly ceiling per expense category. The Spending screen has
        /// drawn a bar against these since it was built and there was nowhere
        /// to set one, so every shop read a budget of zero.
        var budgets: [String: Double] = [:]
        var payReminderEnabled = false, payReminderGrace = 3.0
        var quoteFollowUpEnabled = false, quoteFollowUpWindow = 2.0

        static let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        static let columns = ["pending", "printing", "post", "qc"]

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            let lead = SettingsReader(settings: r.object("leadTime"))
            let wip = r.object("wipLimits")
            let qc = SettingsReader(settings: r.object("qc"))
            let hours = r.object("workingHours")
            let budgets = r.object("expBudgets")
            let pay = SettingsReader(settings: r.object("paymentReminder"))
            let follow = SettingsReader(settings: r.object("quoteFollowUp"))
            var d = Draft(
                minMarginPct: r.number("minMarginPct", 0), quoteValidityDays: r.number("quoteValidityDays", 7),
                minOrderAmount: r.number("minOrderAmount", 0), rushFeeEnabled: r.flag("rushFeeEnabled"),
                rushFeePct: r.number("rushFeePct", 25), defaultPackagingCost: r.number("defaultPackagingCost", 0),
                dailyHours: lead.number("dailyHours", 8), workingDaysPerWeek: lead.number("workingDaysPerWeek", 5),
                finishingDays: lead.number("finishingDays", 1), dispatchDays: lead.number("dispatchDays", 1),
                safetyDays: lead.number("safetyDays", 1), publishToCloud: lead.flag("publishToCloud"),
                wipEnforceHardLimit: r.flag("wipEnforceHardLimit"),
                qcEnabled: qc.flag("enabled"), qcRequireInspector: qc.flag("requireInspector"),
                qcRequirePhotoOnFail: qc.flag("requirePhotoOnFail"), qcWarrantyDays: qc.number("warrantyDays", 30),
                monthlyGoal: r.number("monthlyGoal", 0),
                payReminderEnabled: pay.flag("enabled"), payReminderGrace: pay.number("graceDays", 3),
                quoteFollowUpEnabled: follow.flag("enabled"),
                quoteFollowUpWindow: follow.number("windowDays", 2))
            for category in Shop.expenseCategories {
                d.budgets[category] = Shop.plainNumber(budgets[category]) ?? 0
            }
            // Eight hours a day is what the working-week rule assumes when a
            // shop has never set them, so that is what the fields show.
            for day in days { d.hours[day] = Shop.plainNumber(hours[day]) ?? (hours.isEmpty ? 8 : 0) }
            for col in columns { d.wip[col] = Shop.plainNumber(wip[col]) ?? 0 }
            return d
        }
        func form() -> [String: JSONValue] {
            ["minMarginPct": .number(minMarginPct), "quoteValidityDays": .number(quoteValidityDays),
             "minOrderAmount": .number(minOrderAmount), "rushFeeEnabled": .bool(rushFeeEnabled),
             "rushFeePct": .number(rushFeePct), "defaultPackagingCost": .number(defaultPackagingCost),
             "workingHours": .object(hours.mapValues(JSONValue.number)),
             "leadTime": .object(["dailyHours": .number(dailyHours), "workingDaysPerWeek": .number(workingDaysPerWeek),
                                  "finishingDays": .number(finishingDays), "dispatchDays": .number(dispatchDays),
                                  "safetyDays": .number(safetyDays), "publishToCloud": .bool(publishToCloud)]),
             "wip": .object(wip.mapValues(JSONValue.number)),
             "wipEnforceHardLimit": .bool(wipEnforceHardLimit),
             "qc": .object(["enabled": .bool(qcEnabled), "requireInspector": .bool(qcRequireInspector),
                            "requirePhotoOnFail": .bool(qcRequirePhotoOnFail), "warrantyDays": .number(qcWarrantyDays)]),
             "monthlyGoal": .number(monthlyGoal),
             // `settings-edit` rebuilds `expBudgets` from ITS category list
             // whenever this field is present, so every category has to be in
             // here — a partial map would silently zero the ones left out.
             // `Shop.expenseCategories` is the same six.
             "budgets": .object(budgets.mapValues(JSONValue.number)),
             "paymentReminder": .object(["enabled": .bool(payReminderEnabled),
                                         "graceDays": .number(payReminderGrace)]),
             "quoteFollowUp": .object(["enabled": .bool(quoteFollowUpEnabled),
                                       "windowDays": .number(quoteFollowUpWindow)])]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("set.ops_section")) {
                    numberRow("set.min_margin", $draft.minMarginPct)
                    numberRow("set.quote_validity", $draft.quoteValidityDays)
                    numberRow("set.min_order_amount", $draft.minOrderAmount, unit: Money.mark(shop.currency))
                    Toggle(shop.words.callIt("set.rush_fee_enabled"), isOn: $draft.rushFeeEnabled)
                    numberRow("set.rush_fee_pct", $draft.rushFeePct).disabled(!draft.rushFeeEnabled)
                    numberRow("set.default_packaging_cost", $draft.defaultPackagingCost, unit: Money.mark(shop.currency))
                }
                Section {
                    HStack(spacing: 8) {
                        ForEach(Draft.days, id: \.self) { day in
                            VStack(spacing: 2) {
                                Text(shop.words.callIt("day." + day)).font(.caption).foregroundStyle(.secondary)
                                // `.labelsHidden()`, or the empty label still
                                // claims a Form's label column and shoves the
                                // field to the right of it — which is why every
                                // number sat 44 points right of the day it
                                // belongs to, in a row whose whole job is to
                                // put a figure under a weekday.
                                TextField("", value: Binding(get: { draft.hours[day] ?? 0 }, set: { draft.hours[day] = $0 }),
                                          format: .number.precision(.fractionLength(0...1)))
                                    .labelsHidden()
                                    .multilineTextAlignment(.center).frame(width: 52)
                            }
                        }
                    }
                } header: {
                    Text(shop.words.callIt("set.working_hours"))
                } footer: {
                    Text(shop.words.callIt("set.wh_hint"))
                }
                Section {
                    numberRow("set.lead_daily_hours", $draft.dailyHours)
                    numberRow("set.lead_days_week", $draft.workingDaysPerWeek)
                    numberRow("set.lead_finishing", $draft.finishingDays)
                    numberRow("set.lead_dispatch", $draft.dispatchDays)
                    numberRow("set.lead_safety", $draft.safetyDays)
                    Toggle(shop.words.callIt("set.lead_publish"), isOn: $draft.publishToCloud)
                } header: {
                    Text(shop.words.callIt("set.lead_title"))
                } footer: {
                    Text(shop.words.callIt("set.lead_safety_hint"))
                }
                Section(shop.words.callIt("set.wip_limits")) {
                    ForEach(Draft.columns, id: \.self) { col in
                        row(shop.words.callIt(Stage(rawValue: col)?.key ?? col)) {
                            TextField("", value: Binding(get: { draft.wip[col] ?? 0 }, set: { draft.wip[col] = $0 }),
                                      format: .number.precision(.fractionLength(0)))
                                .multilineTextAlignment(.trailing).frame(width: 70)
                        }
                    }
                    Toggle(shop.words.callIt("set.wip_enforce_hard"), isOn: $draft.wipEnforceHardLimit)
                }
                Section {
                    ForEach(Shop.expenseCategories, id: \.self) { category in
                        row(shop.words.callIt("exp.cat." + category)) {
                            HStack(spacing: 4) {
                                TextField("", value: Binding(get: { draft.budgets[category] ?? 0 },
                                                             set: { draft.budgets[category] = $0 }),
                                          format: .number.precision(.fractionLength(0...2)))
                                    .multilineTextAlignment(.trailing).frame(width: 90)
                                Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(shop.words.callIt("set.exp_budgets"))
                }
                Section {
                    numberRow("dash.goal_setting", $draft.monthlyGoal, unit: Money.mark(shop.currency))
                } footer: {
                    Text(shop.words.callIt("dash.goal_hint"))
                }
                Section {
                    Toggle(shop.words.callIt("set.pay_reminder_enabled"), isOn: $draft.payReminderEnabled)
                    numberRow("set.pay_reminder_grace", $draft.payReminderGrace)
                        .disabled(!draft.payReminderEnabled)
                } footer: {
                    Text(shop.words.callIt("set.pay_reminder_hint"))
                }
                Section {
                    Toggle(shop.words.callIt("set.quote_followup_enabled"), isOn: $draft.quoteFollowUpEnabled)
                    numberRow("set.quote_followup_window", $draft.quoteFollowUpWindow)
                        .disabled(!draft.quoteFollowUpEnabled)
                } footer: {
                    Text(shop.words.callIt("set.quote_followup_hint"))
                }
                Section(shop.words.callIt("set.qc_head")) {
                    Toggle(shop.words.callIt("set.qc_enabled"), isOn: $draft.qcEnabled)
                    Toggle(shop.words.callIt("set.qc_require_inspector"), isOn: $draft.qcRequireInspector).disabled(!draft.qcEnabled)
                    Toggle(shop.words.callIt("set.qc_require_photo"), isOn: $draft.qcRequirePhotoOnFail).disabled(!draft.qcEnabled)
                    numberRow("set.qc_warranty_days", $draft.qcWarrantyDays).disabled(!draft.qcEnabled)
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
    /// A number, and the unit it is in where the label does not already say.
    ///
    /// Most of these labels carry theirs — "Finishing & QC (days)", "Rush fee
    /// percentage (%)" — because they were written for a screen with no room
    /// beside the box. The two money ones do not, and "Minimum order amount"
    /// is a figure a shop has no way to read as riyals rather than a count.
    private func numberRow(_ key: String, _ value: Binding<Double>,
                           unit: String = "") -> some View {
        row(shop.words.callIt(key)) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing).frame(width: 90)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Preferences

struct PreferencesPane: View {
    let shop: Shop

    struct Draft: Equatable {
        var lang = "en"
        var useHijri = true, useArabicNumerals = false
        var autoDeduct = true, lowStock = 200.0

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            return Draft(lang: r.text("lang", "en"), useHijri: r.onUnlessOff("useHijri"),
                         useArabicNumerals: r.flag("useArabicNumerals"),
                         autoDeduct: r.onUnlessOff("autoDeduct"), lowStock: r.number("lowStockThreshold", 200))
        }
        func form() -> [String: JSONValue] {
            ["lang": .string(lang), "useHijri": .bool(useHijri), "useArabicNumerals": .bool(useArabicNumerals),
             "autoDeduct": .bool(autoDeduct), "lowStock": .number(lowStock)]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("set.prefs_section")) {
                    row(shop.words.callIt("set.language")) {
                        Picker("", selection: $draft.lang) {
                            ForEach(Words.supported, id: \.self) { code in
                                Text(shop.languageName(code)).tag(code)
                            }
                        }.labelsHidden()
                    }
                }
                Section(shop.words.callIt("set.locale_section")) {
                    Toggle(shop.words.callIt("set.use_hijri"), isOn: $draft.useHijri)
                    Toggle(shop.words.callIt("set.use_arabic_nums"), isOn: $draft.useArabicNumerals)
                }
                Section(shop.words.callIt("set.stock_section")) {
                    Toggle(shop.words.callIt("set.auto_deduct"), isOn: $draft.autoDeduct)
                    row(shop.words.callIt("set.low_stock")) {
                        TextField("", value: $draft.lowStock, format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                    }
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
}

// MARK: - The shop's text fields, per language

extension Shop {
    struct ContentField: Hashable {
        let key: String
        let base: String
        let language: String
        let label: String
    }

    /// One field per language the shop writes in, for each base — `bizEn`,
    /// `bizAr`, labelled "Business name · العربية".
    func contentFields(_ bases: [String]) -> [ContentField] {
        let labels = ["biz": "set.biz_name", "tagline": "set.tagline", "addr": "set.address",
                      "footer": "set.footer", "invTerms": "set.inv_terms"]
        var out: [ContentField] = []
        for base in bases {
            for lang in contentLanguages {
                let key = Self.contentKey(base, lang)
                out.append(ContentField(key: key, base: base, language: lang,
                                        label: words.callIt(labels[base] ?? base) + " · " + languageName(lang)))
            }
        }
        return out
    }

    /// `lib/content-languages.js`'s `fieldKey`, spelled here because the field
    /// list is built synchronously while a view draws. Pinned to the module by
    /// a test, so the two cannot drift.
    static func contentKey(_ base: String, _ lang: String) -> String {
        if lang == "en" { return base + "En" }
        if lang == "ar" { return base + "Ar" }
        return base + "_" + lang
    }

    /// A language's own name — `lib/content-languages.js`'s table, spelled
    /// here for the same reason as `contentKey` and pinned by the same test.
    func languageName(_ code: String) -> String {
        Self.languageNames[code] ?? code
    }
    static let languageNames = ["en": "English", "ar": "العربية", "de": "Deutsch", "es": "Español",
                                "fr": "Français", "tr": "Türkçe", "ja": "日本語", "zh": "中文", "pt-BR": "Português"]

    /// The languages a document can carry as its second: every one the shared
    /// module can write.
    var writableLanguages: [(code: String, name: String)] {
        ["en", "ar", "de", "es", "fr", "tr", "ja", "zh", "pt-BR"].map { ($0, languageName($0)) }
    }
}

// MARK: - Colours as hex

extension NSColor {
    /// `#RRGGBB`, or nil for anything else.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// The colour as the stylesheet writes it.
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

// MARK: - Slicers

/// The programs this shop slices with.
///
/// A list rather than a form, which is why it does not go through
/// `settings-edit.js` — see `Shop.saveSlicers`. Everything it decides is the
/// shared module's: `lib/slicers.js` reads the list, picks the default, names a
/// bundle and says whether a program may be launched at all.
///
/// **Find installed slicers** is here because the alternative is asking a shop
/// to type `/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca`
/// into a text field, which is a setup step people skip and then report as the
/// feature not working. Khayt scans for the same reason.
struct SlicersPane: View {
    let shop: Shop

    @State private var list: [KhaytEngine.Slicer] = []
    @State private var original: [KhaytEngine.Slicer] = []
    @State private var defaultId = ""
    @State private var originalDefault = ""
    @State private var scanning = false
    /// What the last scan added, said once rather than left to be noticed.
    @State private var found: Int?

    private var dirty: Bool { list != original || defaultId != originalDefault }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("slicer.settings_title")) {
                    if list.isEmpty {
                        // Not an error, and not a disabled row: a shop that has
                        // never set one up needs the sentence, not a blank.
                        Text(shop.words.callIt("mac.no_slicers"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(list) { slicer in
                        HStack(alignment: .firstTextBaseline) {
                            // The default is chosen by tapping its own row's
                            // mark rather than from a separate picker, because a
                            // picker of names is a second list of the same
                            // things a foot below the first.
                            Button {
                                defaultId = slicer.id
                            } label: {
                                Image(systemName: defaultId == slicer.id
                                      ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonStyle(.plain)
                            .help(shop.words.callIt("mac.slicer_make_default"))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(slicer.name)
                                Text(slicer.path)
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.head)
                                    .help(slicer.path)
                            }
                            Spacer(minLength: 8)
                            Button {
                                list.removeAll { $0.id == slicer.id }
                                if defaultId == slicer.id { defaultId = list.first?.id ?? "" }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help(shop.words.callIt("mac.slicer_remove"))
                        }
                    }
                }
                Section {
                    HStack {
                        Button(shop.words.callIt("mac.find_slicers")) { scan() }
                            .disabled(scanning)
                        Button(shop.words.callIt("mac.slicer_add")) { pick() }
                        if scanning { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let found {
                        Text(found == 0 ? shop.words.callIt("mac.slicers_none_found")
                             : shop.words.callIt("mac.slicers_found", ["n": .number(Double(found))]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(shop.words.callIt("mac.slicer_why"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: dirty,
                    save: { Task { await shop.saveSlicers(list, defaultId: defaultId); reset() } },
                    revert: { reset() })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() {
        list = shop.slicers
        original = list
        defaultId = shop.defaultSlicer?.id ?? list.first?.id ?? ""
        originalDefault = defaultId
        found = nil
    }

    /// Add every slicer on this Mac that is not already on the list.
    ///
    /// By PATH, not by name: two builds of OrcaSlicer, or the same one in
    /// `/Applications` and `~/Applications`, are two entries a shop may
    /// genuinely want — and matching on name would silently drop one.
    private func scan() {
        scanning = true
        found = nil
        Task {
            let installed = await shop.installedSlicers()
            let have = Set(list.map(\.path))
            var added = 0
            for slicer in installed where !have.contains(slicer.path) {
                list.append(KhaytEngine.Slicer(id: Shop.uid("SL"), name: slicer.name,
                                               path: slicer.path, args: ""))
                added += 1
            }
            if defaultId.isEmpty { defaultId = list.first?.id ?? "" }
            found = added
            scanning = false
        }
    }

    /// For the slicer the scan cannot see — a build kept somewhere else.
    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = shop.words.callIt("mac.slicer_add")
        guard panel.runModal() == .OK, let bundle = panel.url else { return }
        // The executable inside, for the same reason the scan takes it: that is
        // the shape settings.slicers[] holds, and what a slicer wants on a
        // command line. A path this app cannot resolve is not added silently.
        guard let executable = SlicerFinder.executable(in: bundle) else {
            shop.slicerProblem = shop.words.callIt("mac.slicer_no_binary",
                                                   ["name": .string(bundle.lastPathComponent)])
            return
        }
        Task {
            guard let engine = shop.engine,
                  (try? await engine.mayLaunchAsSlicer(path: executable.path)) == true else {
                // The same refusal the launcher gives, given at the moment the
                // shop chooses rather than the moment it prints.
                shop.slicerProblem = shop.words.callIt("mac.slicer_not_allowed",
                                                       ["name": .string(bundle.lastPathComponent)])
                return
            }
            guard !list.contains(where: { $0.path == executable.path }) else { return }
            let name = (try? await engine.slicerDisplayName(path: executable.path))
                ?? bundle.deletingPathExtension().lastPathComponent
            list.append(KhaytEngine.Slicer(id: Shop.uid("SL"), name: name,
                                           path: executable.path))
            if defaultId.isEmpty { defaultId = list.first?.id ?? "" }
        }
    }
}
