import SwiftUI
import KhaytWidgetData
import AppKit
import KhaytCore

/// The panes of the Settings window, grouped as the sidebar shows them
/// (Settings review, Nov 2026, stage 2).
///
/// Stage 2 moves sections into fourteen panes one group at a time, without
/// changing what any of them does. Panes that have not been split yet keep
/// their old names until their group's turn: `slicers` and `preferences` into Printers & Slicers and Library & Files,
/// `online` and `integrations` into Online Store, Notifications and
/// Connections.
///
/// Not saved between launches (`Shop.settingsPane`), so a raw value is a name
/// in code and in snapshot file names, never something stored on disk.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case shop, pricing, invoices, production, team
    case slicers, preferences
    case cloud, online, integrations, assistant
    var id: String { rawValue }

    /// The sidebar's groups, in order. `nil` is a pane above or below every
    /// group (General, as every Mac's settings open on it).
    enum Group: String, CaseIterable, Identifiable {
        case top, shop, workshop, online
        var id: String { rawValue }
        var wordKey: String? {
            switch self {
            case .top:      nil
            case .shop:     "mac.nav_shop"
            case .workshop: "mac.set_group_workshop"
            case .online:   "mac.set_group_online"
            }
        }
    }

    var group: Group {
        switch self {
        case .general: .top
        case .shop, .pricing, .invoices, .production, .team: .shop
        case .slicers, .preferences: .workshop
        case .cloud, .online, .integrations, .assistant: .online
        }
    }

    /// The pane's name.
    var wordKey: String {
        switch self {
        case .general:      "mac.nav_general"
        case .shop:         "mac.nav_shop"
        case .pricing:      "mac.nav_pricing"
        case .invoices:     "mac.nav_invoices"
        case .production:   "mac.nav_production"
        case .team:         "mac.nav_team"
        case .integrations: "mac.nav_integrations"
        case .slicers:      "mac.nav_slicers"
        case .online:       "mac.nav_online"
        case .cloud:        "mac.nav_cloud"
        case .assistant:    "set.ai_master"
        case .preferences:  "mac.preferences"
        }
    }

    var symbol: String {
        switch self {
        case .general:      "gearshape"
        case .shop:         "building.2"
        case .pricing:      "percent"
        case .invoices:     "doc.text"
        case .production:   "gearshape.2"
        case .team:         "person.2"
        case .integrations: "shippingbox"
        case .slicers:      "cube.transparent"
        case .online:       "wifi"
        case .cloud:        "icloud"
        case .assistant:    "sparkles"
        case .preferences:  "slider.horizontal.3"
        }
    }

    static func panes(in group: Group) -> [SettingsPane] { allCases.filter { $0.group == group } }
}

/// The shop's own settings — ⌘, — in panes grouped down a sidebar.
///
/// A SIDEBAR, not toolbar tabs. Nine tabs need about 680pt in English and more
/// in Arabic, and the window is 600pt of pane: AppKit put whatever did not fit
/// behind a » chevron at the end of the toolbar, so Preferences — the last tab —
/// could not be found at all, and every pane added would have pushed another
/// one out. A list has room for any number, in any language.
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
        HStack(spacing: 0) {
            List(selection: Binding(
                get: { Optional(shop.settingsPane) },
                set: { if let pane = $0 { shop.settingsPane = pane } }
            )) {
                ForEach(SettingsPane.Group.allCases) { group in
                    if let key = group.wordKey {
                        Section(shop.words.callIt(key)) { rows(group) }
                    } else {
                        rows(group)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            Group {
                if shop.needsSignIn {
                    LockScreen(shop: shop)
                } else if !shop.lockAllows("settings", "view") {
                    NotAllowed(shop: shop)
                } else {
                    // A manager reads Settings and changes nothing: every
                    // control in the pane is disabled, and `saveSettings`
                    // refuses on its own as well.
                    pane(shop.settingsPane)
                        .disabled(!shop.lockAllows("settings", "edit"))
                }
            }
            // At least 600 and as wide as the shop makes it. A fixed 600 x 640
            // was a window nobody could widen: a long label, a larger text
            // size, or Arabic left a row cut off with no way to reach it.
            .frame(minWidth: 600, maxWidth: .infinity)
        }
        .frame(minHeight: 640, maxHeight: .infinity)
        .navigationTitle(shop.words.callIt(shop.settingsPane.wordKey))
        // Raised HERE rather than from the shop window: the list it is reached
        // from lives on the Integrations pane, and a sheet bound to the same
        // state from two windows presents itself twice.
        .shopSheet(item: $shop.editingTemplate) { TemplateSheet(shop: shop, template: $0) }
    }

    private func rows(_ group: SettingsPane.Group) -> some View {
        // S4: a pane Simple leaves out is not in the list (Team & access, AI).
        ForEach(SettingsPane.panes(in: group).filter { !Self.professionalOnly($0, shop) }) { pane in
            Label(shop.words.callIt(pane.wordKey), systemImage: pane.symbol)
                // Connector updates waiting on the shop's yes (Figma 70:234):
                // the count goes when none is left.
                .badge(pane == .integrations ? shop.connectorUpdatesWaiting : 0)
                .tag(pane)
        }
    }

    /// The Simple map row each pane is (`SIMPLE_MAP`), where Simple leaves it out.
    static func simpleKey(_ pane: SettingsPane) -> String? {
        switch pane {
        case .team: "team"
        case .assistant: "ai"
        default: nil
        }
    }

    static func professionalOnly(_ pane: SettingsPane, _ shop: Shop) -> Bool {
        simpleKey(pane).map(shop.professionalOnly) ?? false
    }

    @ViewBuilder
    private func pane(_ which: SettingsPane) -> some View {
        if Self.professionalOnly(which, shop) {
            // Chosen before the switch, or restored: say so, and offer it back.
            PartOfProfessional(shop: shop, feature: shop.words.callIt(which.wordKey))
        } else {
            paneBody(which)
        }
    }

    @ViewBuilder
    private func paneBody(_ which: SettingsPane) -> some View {
        switch which {
        case .general:      GeneralPane(shop: shop)
        case .shop:         ShopPane(shop: shop)
        case .pricing:      PricingPane(shop: shop)
        case .team:         TeamPane(shop: shop)
        case .invoices:     InvoicesPane(shop: shop)
        case .production:   ProductionPane(shop: shop)
        case .integrations: IntegrationsPane(shop: shop)
        case .slicers:      SlicersPane(shop: shop)
        case .online:       OnlinePane(shop: shop)
        case .cloud:        CloudPane(shop: shop)
        case .assistant:    AssistantPane(shop: shop)
        case .preferences:  PreferencesPane(shop: shop)
        }
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

/// A number row in a settings form, with the unit it is in where the label
/// does not already say. Most labels carry theirs — "Finishing & QC (days)",
/// "Rush fee percentage (%)" — because they were written for a screen with no
/// room beside the box. The money ones do not, and "Minimum order amount" is a
/// figure a shop has no way to read as riyals rather than a count.
@MainActor
func settingsNumberRow(_ shop: Shop, _ key: String, _ value: Binding<Double>, unit: String = "") -> some View {
    row(shop.words.callIt(key)) {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing).frame(width: 90)
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }
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
///
/// NOT file-private any more: `EmailSettings` is a pane of this window that
/// lives in its own file, and its first draft hand-rolled an
/// `HStack { Text; Spacer; control }` instead. That reads the same in source
/// and does not look the same on screen — `LabeledContent` puts the label in
/// the platform's own column, aligned with every other row in the window, and
/// an HStack aligns with nothing.
/// A field whose value is NOT the shop's language — a phone number, an email
/// address, a tax number, an IBAN, a host, a path, a key.
///
/// ── THE PHONE NUMBER WAS BEING REORDERED ON SCREEN ────────────────────────
///
/// In an Arabic window the base direction is right-to-left, and the bidi
/// algorithm applies it to the whole run. `+966 50 000 0000` came out as
/// `0000 000 50 966+`: the `+` is a NEUTRAL character so it takes the
/// paragraph's direction and lands at the far end, and the digit groups are
/// WEAK so they reorder around it. A shop reading its own telephone number in
/// its own language was shown a different number.
///
/// Nothing was wrong with the value. It is stored correctly, it exports
/// correctly, and it prints on the invoice correctly — this is the one place
/// it is displayed inside an Arabic paragraph, and it is the field somebody
/// types it into.
///
/// The email survived only by luck: every character in `hello@tuwaiq.example`
/// is strong left-to-right, so there was nothing for the algorithm to move.
/// Change one character to an Arabic one and it breaks the same way.
///
/// ── THE APP ALREADY KNEW THIS ─────────────────────────────────────────────
///
/// `Figure` isolates every money value the same way, with the same one line
/// and nearly the same comment: *"the whole value is one run with its own
/// direction … so a Latin figure inside an Arabic column stays Latin and
/// keeps its unit attached."* That reasoning was never carried to the form
/// where the shop types those values in.
///
/// ── WHICH FIELDS, AND WHY IT IS A LIST RATHER THAN A DEFAULT ──────────────
///
/// Named one at a time on purpose. The opposite — Latin by default, opt out
/// for prose — puts an Arabic business name, tagline, address or note into a
/// left-to-right run the first time somebody adds a field and forgets, and
/// that failure is silent and looks like a font problem. A machine-data field
/// that is missed here merely keeps the old behaviour.
func latinRow<Content: View>(_ label: String,
                             @ViewBuilder _ content: () -> Content) -> some View {
    row(label) {
        content()
            // ORDER MATTERS HERE, and it is the whole fix. `row` applies
            // `.leading` to whatever it is handed, and SwiftUI resolves that
            // against the direction in force WHERE THE MODIFIER SITS — so an
            // alignment set outside this environment resolves to the right in
            // an Arabic window before the direction below is ever seen. Set
            // inside it, `.leading` is the left.
            .multilineTextAlignment(.leading)
            // The value is one run in its own direction, whatever the window
            // is doing around it. The LABEL stays in the shop's language and
            // on the shop's side, because it is a word rather than a value.
            .environment(\.layoutDirection, .leftToRight)
    }
}

func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
    // INSIDE the closure, and that is the whole trick. Applied to the
    // `LabeledContent` from the outside it does nothing at all: the labelled
    // style sets its own alignment on the content it wraps, which is closer to
    // the field than anything put around the whole row, and the closer one
    // wins. Photographed both ways — the outside version left "+966 50 000
    // 0000" exactly where it was.
    LabeledContent(label) { content().multilineTextAlignment(.leading) }
        // ── A FIELD HAS TO LOOK LIKE A FIELD ──────────────────────────────
        //
        // A `TextField` inside `LabeledContent` draws with no bezel. A filled
        // one then reads as a VALUE — "Business name · English    Tuwaiq
        // Additive" looks like a row of a table — and an EMPTY one is
        // invisible: the Payments pane showed "Bank name" and "Account
        // holder" with nothing after them at all, so the whole screen read as
        // a list of facts about the shop rather than a form. Reported as
        // exactly that: the settings look like you cannot edit them.
        //
        // Set here rather than on each of the thirty-five fields, so a pane
        // added later cannot forget it. `textFieldStyle` applies only to text
        // fields; the pickers, toggles and buttons that also go through `row`
        // ignore it.
        .textFieldStyle(.roundedBorder)
        // ── AND IT HAS TO START WHERE YOU TYPE ────────────────────────────
        //
        // `LabeledContent` puts its content against the TRAILING edge, so
        // every one of these fields drew its text hard against the right of
        // the box in an English window: "Phone" ... "+966 55 123 4567" with
        // the caret at the far side of the pane from the label it belongs to.
        //
        // This was half-fixed once already, which is worse than not at all.
        // The two bilingual name fields got an explicit alignment — they
        // needed a special one, because an Arabic name in an English window
        // reads from the other edge — and the forty-three ORDINARY fields
        // were left as they were. Fixing the exceptions and missing the rule
        // is how a form ends up with two behaviours and no explanation.
        //
        // `.leading` rather than `.left`: it is the reading edge of whichever
        // direction the window is in, so an Arabic window keeps its fields on
        // the right, where they belong. Set here for the same reason the
        // bezel is — a pane added next month cannot forget it — and the
        // bilingual fields still override it, because they set theirs on the
        // field itself, closer to the leaf still.
}

// MARK: - Shop

/// Who the shop is and where and when it opens: identity, contact, logo,
/// registration, locations, opening hours, closures and pickup.
struct ShopPane: View {
    let shop: Shop

    /// Which way this WINDOW reads, which is half of where a field's text
    /// starts — see `ContentField.textAlignment(appIsRTL:)`.
    private var appIsRTL: Bool { shop.words.language == "ar" }

    struct Draft: Equatable {
        /// The shop's own text, keyed by store field (`bizEn`, `addr_fr`…).
        var content: [String: String] = [:]
        var phone = "", email = "", vat = "", cr = ""
        /// `settings.workingHours`, hours per weekday. Delivery promises and
        /// the queue's working week read it (`WorkingWeek`).
        var hours: [String: Double] = [:]
        /// `settings.holidays`, the days the shop is closed (`YYYY-MM-DD`).
        var holidays: [String] = []
        /// Pickup on the customer's order page (`portal-refresh.js`, Cloud
        /// #199): shown once either is filled in.
        var pickupHours = "", pickupMapUrl = ""

        static let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            var d = Draft(phone: r.text("phone"), email: r.text("email"), vat: r.text("vat"), cr: r.text("cr"),
                          pickupHours: r.text("pickupHours"), pickupMapUrl: r.text("pickupMapUrl"))
            // Eight hours a day is what the working-week rule assumes when a
            // shop has never set them, so that is what the fields show.
            let hours = r.object("workingHours")
            for day in days { d.hours[day] = Shop.plainNumber(hours[day]) ?? (hours.isEmpty ? 8 : 0) }
            d.holidays = WorkingWeek.holidays(settings: .object(settings))
            for field in shop.contentFields(["biz", "tagline", "addr"]) { d.content[field.key] = r.text(field.key) }
            return d
        }
        /// Blank goes as "" — `settings-edit` deletes the key for it, so a
        /// cleared field returns the shop to the default rather than to 0.
        func form() -> [String: JSONValue] {
            ["content": .object(content.mapValues(JSONValue.string)),
             "phone": .string(phone), "email": .string(email), "vat": .string(vat), "cr": .string(cr),
             "workingHours": .object(hours.mapValues(JSONValue.number)),
             "holidays": .array(holidays.map(JSONValue.string)),
             "pickupHours": .string(pickupHours), "pickupMapUrl": .string(pickupMapUrl)]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var askingLogo = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("set.biz_identity")) {
                    ForEach(shop.contentFields(["biz", "tagline", "addr"]), id: \.key) { field in
                        row(field.label) {
                            // ── EACH SCRIPT STARTS AT ITS OWN EDGE ────
                            //
                            // `LabeledContent` aligns its content TRAILING,
                            // and the layout direction below decides which
                            // side trailing IS. Together they put every value
                            // on the wrong edge: the English name hugged the
                            // right of its field and the Arabic name hugged
                            // the left, each reading as the other script's
                            // direction. Reported as exactly that.
                            //
                            // `.leading` is the reading edge of whichever
                            // direction the field is in, so English starts at
                            // the left and Arabic at the right — where a
                            // person typing either one expects the caret.
                            TextField("", text: binding(field.key))
                                .multilineTextAlignment(field.textAlignment(appIsRTL: appIsRTL))
                        }
                    }
                }
                Section(shop.words.callIt("set.biz_contact")) {
                    latinRow(shop.words.callIt("set.phone")) { LatinField(text: $draft.phone) }
                    latinRow(shop.words.callIt("set.email")) { LatinField(text: $draft.email) }
                }
                // ── THE MARK ON THE SHOP'S DOCUMENTS ──────────────────────
                //
                // Saved on the spot rather than with the bar below, and not in
                // `Draft`: `settings-edit.js` keeps `out.bizLogo = s.bizLogo
                // || ''`, so it preserves what it finds and takes none from a
                // form. A logo sent through the Save bar would be read and
                // thrown away.
                Section(shop.words.callIt("set.logo")) {
                    HStack(spacing: 12) {
                        if let mark = ShopLogo.image(from: shop.bizLogo) {
                            Image(nsImage: mark)
                                .resizable().scaledToFit()
                                .frame(width: 96, height: 48)
                                // The paper is white; a dark logo on a dark
                                // settings pane looks like nothing at all.
                                .padding(6)
                                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                        }
                        Button(shop.words.callIt("set.logo_upload")) { shop.pickLogo() }
                            .disabled(!shop.canWrite)
                        if !shop.bizLogo.isEmpty {
                            Button(shop.words.callIt("set.logo_remove") + "\u{2026}", role: .destructive) {
                                askingLogo = true
                            }
                            .disabled(!shop.canWrite)
                        }
                        Spacer()
                    }
                    Text(shop.words.callIt("mac.logo_accepts"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Asked before Remove: no undo, and the file it came from may
                // be long gone from this Mac.
                .confirmationDialog(shop.words.callIt("mac.remove_logo_q"),
                                    isPresented: $askingLogo, titleVisibility: .visible) {
                    Button(shop.words.callIt("set.logo_remove"), role: .destructive) {
                        Task { await shop.clearLogo() }
                    }
                    Button(shop.words.callIt("common.cancel"), role: .cancel) {}
                } message: {
                    Text(shop.words.callIt("mac.remove_logo_note") + " "
                         + shop.words.callIt("mac.no_undo"))
                }
                Section(shop.words.callIt("set.biz_tax")) {
                    // The registration number is called what the shop's tax
                    // rules call it — GSTIN, USt-IdNr., VAT No. — not always "VAT".
                    latinRow(shop.taxProfile?.registration ?? shop.words.callIt("set.vat")) { LatinField(text: $draft.vat) }
                    latinRow(shop.words.callIt("set.cr")) { LatinField(text: $draft.cr) }
                }
                // Where the shop works. Records, saved as they are made — not
                // part of the draft the bar below saves.
                Section { LocationsSection(shop: shop) }
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
                                          format: .number.locale(Money.digits).precision(.fractionLength(0...1)))
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
                HolidaysSection(shop: shop, holidays: $draft.holidays)

                // Where and when a customer collects — on their order page,
                // with the address the invoice already prints.
                Section {
                    row(shop.words.callIt("mac.pickup_hours")) { TextField("", text: $draft.pickupHours) }
                    latinRow(shop.words.callIt("mac.pickup_map")) {
                        LatinField(text: $draft.pickupMapUrl, placeholder: "https://", monospaced: false)
                    }
                    Text(shop.words.callIt("mac.pickup_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: { Text(shop.words.callIt("mac.pickup_title")) }

            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form(), opened: original.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft.content[key] ?? "" }, set: { draft.content[key] = $0 })
    }
}

// MARK: - Pricing & tax

/// What the shop's work costs it and what it charges: currency and tax,
/// exchange rates, running and fixed costs, quote rules, loyalty and targets
/// (Settings stage 2).
struct PricingPane: View {
    let shop: Shop

    struct Draft: Equatable {
        var currency = "SAR"
        var taxCountry = ""
        var enableVat = false
        var vatRate = 15.0
        var taxMode = "inclusive"
        /// How often the shop files its VAT return (lib/vat-periods.js):
        /// "quarterly" unless it is a monthly filer.
        var vatFilingFrequency = "quarterly"
        var enableZatca = false
        /// The shop's electricity tariff (`settings.elecRate`), per kWh. Nil
        /// is "not said" — Khayt's default applies, and the key stays absent.
        var elecRate: Double?
        var minMarginPct = 0.0, quoteValidityDays = 7.0, minOrderAmount = 0.0
        var rushFeeEnabled = false, rushFeePct = 25.0, defaultPackagingCost = 0.0
        /// The rewards programme.
        var loyaltyEnabled = false
        var loyaltyPointsPerUnit = 1.0
        var loyaltyRedeemRate = 0.01
        /// A monthly ceiling per expense category, which the Spending screen
        /// draws a bar against.
        var budgets: [String: Double] = [:]
        var monthlyGoal = 0.0

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            var d = Draft(
                currency: r.text("currency", "SAR"),
                taxCountry: Shop.taxCountry(settings),
                enableVat: r.flag("enableVat"),
                vatRate: r.number("vatRate", 15),
                taxMode: Shop.taxMode(settings),
                vatFilingFrequency: r.text("vatFilingFrequency", "quarterly") == "monthly" ? "monthly" : "quarterly",
                enableZatca: r.onUnlessOff("enableZatca"),
                // Only a figure the field can show. Junk (`"abc"`, `"inf"`,
                // `"nan"`) shows empty — and saving the pane untouched still
                // leaves it byte-identical: the form sends "" both as edited and
                // as opened, so `RoundTrip` puts the stored value back.
                elecRate: Shop.plainNumber(settings["elecRate"]).flatMap { $0.isFinite ? $0 : nil },
                minMarginPct: r.number("minMarginPct", 0), quoteValidityDays: r.number("quoteValidityDays", 7),
                minOrderAmount: r.number("minOrderAmount", 0), rushFeeEnabled: r.flag("rushFeeEnabled"),
                rushFeePct: r.number("rushFeePct", 25), defaultPackagingCost: r.number("defaultPackagingCost", 0),
                monthlyGoal: r.number("monthlyGoal", 0))
            // The rule's own defaults when the shop has set none — a point per
            // unit, a hundred points to the unit — so the pane opens showing
            // what a redemption would actually be worth rather than zero.
            if case .number(let n)? = settings["loyaltyPointsPerUnit"], n > 0 { d.loyaltyPointsPerUnit = n }
            if case .number(let n)? = settings["loyaltyRedeemRate"], n > 0 { d.loyaltyRedeemRate = n }
            if case .bool(true)? = settings["loyaltyEnabled"] { d.loyaltyEnabled = true }
            let budgets = r.object("expBudgets")
            for category in Shop.expenseCategories {
                d.budgets[category] = Shop.plainNumber(budgets[category]) ?? 0
            }
            return d
        }
        func form() -> [String: JSONValue] {
            ["currency": .string(currency), "taxCountry": .string(taxCountry),
             "enableVat": .bool(enableVat), "vatRate": .number(vatRate), "taxMode": .string(taxMode),
             "vatFilingFrequency": .string(vatFilingFrequency),
             "enableZatca": .bool(enableZatca),
             // Blank goes as "" — `settings-edit` deletes the key for it, so a
             // cleared field returns the shop to the default rather than to 0.
             "elecRate": elecRate.map { .number($0) } ?? .string(""),
             "minMarginPct": .number(minMarginPct), "quoteValidityDays": .number(quoteValidityDays),
             "minOrderAmount": .number(minOrderAmount), "rushFeeEnabled": .bool(rushFeeEnabled),
             "rushFeePct": .number(rushFeePct), "defaultPackagingCost": .number(defaultPackagingCost),
             "loyaltyEnabled": .bool(loyaltyEnabled),
             "loyaltyPointsPerUnit": .number(loyaltyPointsPerUnit),
             "loyaltyRedeemRate": .number(loyaltyRedeemRate),
             // `settings-edit` rebuilds `expBudgets` from ITS category list
             // whenever this field is present, so every category has to be in
             // here — a partial map would silently zero the ones left out.
             "budgets": .object(budgets.mapValues(JSONValue.number)),
             "monthlyGoal": .number(monthlyGoal)]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var example = ""
    /// Khayt's own tariff (`KhaytPrintRates.DEFAULTS`), for the hint — read
    /// from the rule, never restated here.
    @State private var defaultElecRate: Double?

    private var countries: [(code: String, name: String)] {
        // The SHOP's language, not this Mac's — `Locale.current` named the
        // countries in English under an Arabic window.
        let locale = shop.words.locale
        return shop.taxPresets.keys.map { code in
            (code, locale.localizedString(forRegionCode: code) ?? code)
        }.sorted { $0.name.compare($1.name, options: [.caseInsensitive], range: nil, locale: locale) == .orderedAscending }
    }
    private var currencies: [(code: String, label: String)] {
        // In the shop's language and sorted in it, like the first-run setup.
        shop.words.currencyChoices(shop.currencies.mapValues(\.label), current: draft.currency)
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
                        TextField("", value: $draft.vatRate, format: .number.locale(Money.digits).precision(.fractionLength(0...3)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            .disabled(!draft.enableVat)
                    }
                    row(shop.words.callIt("set.tax_mode")) {
                        Picker("", selection: $draft.taxMode) {
                            Text(shop.words.callIt("set.tax_mode_inclusive")).tag("inclusive")
                            Text(shop.words.callIt("set.tax_mode_exclusive")).tag("exclusive")
                        }.labelsHidden()
                        // OFF WITH THE RATE ABOVE IT. Whether a price includes
                        // tax is a question about tax, and with VAT switched
                        // off it was the one control in this block still live —
                        // a picker a shop could change, twice, and watch every
                        // figure in the app stay exactly where it was. The rate
                        // beside it has been disabled all along; this was the
                        // one that got missed.
                        .disabled(!draft.enableVat)
                    }
                    // How often the return is filed. It decides the period a
                    // reversal of a FILED return's invoice lands in — the
                    // next quarter, or the next month (lib/vat-periods.js).
                    row(shop.words.callIt("pnl.vat_filing")) {
                        Picker("", selection: $draft.vatFilingFrequency) {
                            Text(shop.words.callIt("pnl.vat_filing_quarterly")).tag("quarterly")
                            Text(shop.words.callIt("pnl.vat_filing_monthly")).tag("monthly")
                        }.labelsHidden()
                        .disabled(!draft.enableVat)
                    }
                    Text(shop.words.callIt("pnl.vat_filing_hint")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The arithmetic on a round number, because inclusive and
                    // exclusive both look plausible and differ by the tax on
                    // every order.
                    Text(example).font(.callout).foregroundStyle(.secondary)
                    // ZATCA Phase 2 e-invoicing is a Professional feature, and the
                    // other app hides it from a Simple shop.
                    if shop.has("zatca") {
                        Toggle(shop.words.callIt("set.enable_zatca"), isOn: $draft.enableZatca)
                    }
                }
                // Its own Save, like the desktop's: settings-edit keeps the
                // rates and takes none from the form above.
                Section { ExchangeRatesSection(shop: shop) }
                // ── WHAT A kWh COSTS THIS SHOP ────────────────────────────
                //
                // `settings.elecRate`, layered by `lib/print-rates.js` between
                // Khayt's default and a calculator preset — so a failed print
                // and the power-by-machine report, which have no preset, are
                // charged what the shop actually pays.
                Section(shop.words.callIt("mac.set_running_costs")) {
                    row(shop.words.callIt("mac.set_elec_rate")) {
                        HStack(spacing: 4) {
                            TextField("", value: $draft.elecRate,
                                      format: .number.locale(Money.digits).precision(.fractionLength(0...3)),
                                      prompt: defaultElecRate.map { Text(Money.fieldValue($0)) })
                                .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 90)
                            Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                        }
                    }
                    Text(shop.words.callIt("mac.set_elec_rate_hint",
                                           // With its currency, as every other money hint
                                           // in Settings is: "Khayt's 0.18" said nothing
                                           // about what 0.18 was.
                                           ["rate": .string(defaultElecRate.map { Money.text($0, shop.currency) } ?? "")]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // What the shop pays every month. Here, beside the tax
                // registration, because this is the pane about the business
                // itself rather than about a screen — and because Reports
                // sends a shop to "Settings" for it without saying which pane.
                // It saves itself: it is a LIST, and a list reverted by the
                // bar below along with the shop's name is a surprise.
                FixedCostsSettings(shop: shop)
                Section(shop.words.callIt("set.ops_section")) {
                    numberRow("set.min_margin", $draft.minMarginPct)
                    numberRow("set.quote_validity", $draft.quoteValidityDays)
                    numberRow("set.min_order_amount", $draft.minOrderAmount, unit: Money.mark(shop.currency))
                    Toggle(shop.words.callIt("set.rush_fee_enabled"), isOn: $draft.rushFeeEnabled)
                    numberRow("set.rush_fee_pct", $draft.rushFeePct).disabled(!draft.rushFeeEnabled)
                    numberRow("set.default_packaging_cost", $draft.defaultPackagingCost, unit: Money.mark(shop.currency))
                }
                Section(shop.words.callIt("set.loyalty")) {
                    Toggle(shop.words.callIt("set.loyalty_enabled"), isOn: $draft.loyaltyEnabled)
                    // The two numbers only mean anything once it is on, and a
                    // pane that asks for them anyway is asking about a
                    // programme the shop has not agreed to run.
                    if draft.loyaltyEnabled {
                        row(shop.words.callIt("mac.points_per_unit")) {
                            TextField("", value: $draft.loyaltyPointsPerUnit,
                                      format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                                .monospacedDigit()
                        }
                        row(shop.words.callIt("mac.points_worth")) {
                            TextField("", value: $draft.loyaltyRedeemRate,
                                      format: .number.locale(Money.digits).precision(.fractionLength(0...4)))
                                .monospacedDigit()
                        }
                        Text(shop.words.callIt("mac.points_explains"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // The tiers the programme climbs, with their own Save — the
                // desktop's tier editor. Only once the programme is on: a
                // tier is read by nothing while it is off.
                if draft.loyaltyEnabled {
                    Section { LoyaltyTiersSection(shop: shop) }
                }
                Section {
                    ForEach(Shop.expenseCategories, id: \.self) { category in
                        row(shop.words.callIt("exp.cat." + category)) {
                            HStack(spacing: 4) {
                                TextField("", value: Binding(get: { draft.budgets[category] ?? 0 },
                                                             set: { draft.budgets[category] = $0 }),
                                          format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
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
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form(), opened: original.form(), country: draft.taxCountry); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
        .task(id: draft) { await explain() }
        .task { defaultElecRate = await shop.printRateDefault("elecRate", settings: [:]) }
        .onChange(of: draft.taxCountry) { _, code in chose(code) }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
    /// A number, and the unit it is in where the label does not already say.
    private func numberRow(_ key: String, _ value: Binding<Double>, unit: String = "") -> some View {
        settingsNumberRow(shop, key, value, unit: unit)
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
}

// MARK: - Team & access

/// Who works at the shop and how they sign in: operators, staff sign-in and
/// PINs on this Mac, and (for the owner) the Khayt Cloud team and the devices
/// signed in to it. Every section here saves itself; there is no Save bar.
struct TeamPane: View {
    let shop: Shop

    var body: some View {
        Form {
            Section { OperatorsSection(shop: shop) }
            Section { LockSection(shop: shop) }
            TeamSettings(shop: shop)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Invoices & payments

/// What the shop's documents look like and how it is paid: documents and
/// their numbering, bank details, accepted methods, the payment link, pay
/// later, payment reminders and quote follow-up (Settings stage 2).
struct InvoicesPane: View {
    let shop: Shop

    /// Which way this WINDOW reads, which is half of where a field's text
    /// starts — see `ContentField.textAlignment(appIsRTL:)`.
    private var appIsRTL: Bool { shop.words.language == "ar" }

    struct Draft: Equatable {
        // The job-number prefix is NOT here: Invoice numbering shows it with
        // the tax-invoice prefix, as one field while they agree
        // (`NumberPrefixes`). Two fields in two panes each said "invoice prefix".
        var quotePrefix = "QUO"
        var invTemplate = "classic"
        var invoiceBilingual = "auto", invoiceSecondLang = "ar"
        var invAccent = "#5E2E14"
        var content: [String: String] = [:]
        var useHijri = true, useArabicNumerals = false
        var bankName = "", accountHolder = "", iban = ""
        var accepted: Set<String> = []
        var paymentInstructions = ""
        var payReminderEnabled = false, payReminderGrace = 3.0
        /// `auto` | `whatsapp` | `email` (`lib/payment-reminder.js reminderChannel`).
        var payReminderChannel = "auto"
        var quoteFollowUpEnabled = false, quoteFollowUpWindow = 2.0

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            let pay = SettingsReader(settings: r.object("paymentReminder"))
            let follow = SettingsReader(settings: r.object("quoteFollowUp"))
            var accepted: Set<String> = []
            if case .array(let list)? = settings["acceptedPayments"] {
                accepted = Set(list.compactMap(Shop.plainString))
            }
            var d = Draft(
                quotePrefix: r.text("quotePrefix", "QUO"),
                invTemplate: r.text("invTemplate", "classic"),
                invoiceBilingual: r.text("invoiceBilingual", "auto"),
                invoiceSecondLang: r.text("invoiceSecondLang", "ar"),
                invAccent: r.text("invAccentColor", "#5E2E14"),
                useHijri: r.onUnlessOff("useHijri"), useArabicNumerals: r.flag("useArabicNumerals"),
                bankName: r.text("bankName"), accountHolder: r.text("accountHolder"), iban: r.text("iban"),
                accepted: accepted, paymentInstructions: r.text("paymentInstructions"),
                payReminderEnabled: pay.flag("enabled"), payReminderGrace: pay.number("graceDays", 3),
                quoteFollowUpEnabled: follow.flag("enabled"),
                quoteFollowUpWindow: follow.number("windowDays", 2))
            for field in shop.contentFields(["footer", "invTerms"]) { d.content[field.key] = r.text(field.key) }
            if case .string(let channel)? = r.object("paymentReminder")["channel"],
               ["whatsapp", "email"].contains(channel) {
                d.payReminderChannel = channel
            }
            return d
        }
        @MainActor func form() -> [String: JSONValue] {
            ["quotePrefix": .string(quotePrefix),
             "invTemplate": .string(invTemplate), "invoiceBilingual": .string(invoiceBilingual),
             "invoiceSecondLang": .string(invoiceSecondLang), "invAccent": .string(invAccent),
             "content": .object(content.mapValues(JSONValue.string)),
             "useHijri": .bool(useHijri), "useArabicNumerals": .bool(useArabicNumerals),
             "bankName": .string(bankName), "accountHolder": .string(accountHolder), "iban": .string(iban),
             // In Khayt's own order, not the set's: the invoice lists them.
             "acceptedPayments": .array(Shop.paymentMethods.filter(accepted.contains).map(JSONValue.string)),
             "paymentInstructions": .string(paymentInstructions),
             "paymentReminder": .object(["enabled": .bool(payReminderEnabled),
                                         "graceDays": .number(payReminderGrace),
                                         "channel": .string(payReminderChannel)]),
             "quoteFollowUp": .object(["enabled": .bool(quoteFollowUpEnabled),
                                       "windowDays": .number(quoteFollowUpWindow)])]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()

    /// ZATCA's switch is in Pricing & Tax now; the documents section only
    /// needs to know whether it is on, as saved.
    private var zatcaOn: Bool { SettingsReader(settings: shop.settingsDict).onUnlessOff("enableZatca") }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("set.invoice_section")) {
                    latinRow(shop.words.callIt("set.quote_prefix")) { TextField("", text: $draft.quotePrefix).frame(width: 120) }
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
                    if zatcaOn {
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
                            // ── EACH SCRIPT STARTS AT ITS OWN EDGE ────
                            //
                            // `LabeledContent` aligns its content TRAILING,
                            // and the layout direction below decides which
                            // side trailing IS. Together they put every value
                            // on the wrong edge: the English name hugged the
                            // right of its field and the Arabic name hugged
                            // the left, each reading as the other script's
                            // direction. Reported as exactly that.
                            //
                            // `.leading` is the reading edge of whichever
                            // direction the field is in, so English starts at
                            // the left and Arabic at the right — where a
                            // person typing either one expects the caret.
                            TextField("", text: binding(field.key))
                                .multilineTextAlignment(field.textAlignment(appIsRTL: appIsRTL))
                        }
                    }
                    ForEach(shop.contentFields(["invTerms"]), id: \.key) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label).foregroundStyle(.secondary)
                            TextEditor(text: binding(field.key)).frame(height: 60).font(.body)
                                .multilineTextAlignment(field.textAlignment(appIsRTL: appIsRTL))
                        }
                    }
                }
                Section(shop.words.callIt("set.locale_section")) {
                    Toggle(shop.words.callIt("set.use_hijri"), isOn: $draft.useHijri)
                    Toggle(shop.words.callIt("set.use_arabic_nums"), isOn: $draft.useArabicNumerals)
                }
                // Its own Save, like the desktop's section: settings-edit keeps
                // the numbering and takes none of it from the form above.
                Section { InvoiceNumberingSection(shop: shop) }
                Section(shop.words.callIt("set.bank_section")) {
                    row(shop.words.callIt("set.bank_name")) { TextField("", text: $draft.bankName) }
                    row(shop.words.callIt("set.account_holder")) { TextField("", text: $draft.accountHolder) }
                    latinRow(shop.words.callIt("set.iban")) {
                        LatinField(text: $draft.iban,
                                   placeholder: shop.words.callIt("set.iban_ph"),
                                   monospaced: true)
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
                // The shop's payment link and pay-later providers, from Online.
                // Each saves itself, as it did there.
                PayLinkSettings(shop: shop)
                BnplSettings(shop: shop)
                Section {
                    Toggle(shop.words.callIt("set.pay_reminder_enabled"), isOn: $draft.payReminderEnabled)
                    numberRow("set.pay_reminder_grace", $draft.payReminderGrace)
                        .disabled(!draft.payReminderEnabled)
                    // How "Send reminder" goes out. Not behind the switch: the
                    // switch is Today's list, and a reminder can be sent from a
                    // job whether or not the list is shown.
                    Picker(shop.words.callIt("set.pay_reminder_channel"), selection: $draft.payReminderChannel) {
                        Text(shop.words.callIt("set.pay_reminder_channel_auto")).tag("auto")
                        Text(shop.words.callIt("set.pay_reminder_channel_whatsapp")).tag("whatsapp")
                        Text(shop.words.callIt("set.pay_reminder_channel_email")).tag("email")
                    }
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
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form(), opened: original.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft.content[key] ?? "" }, set: { draft.content[key] = $0 })
    }
    /// A number, and the unit it is in where the label does not already say.
    private func numberRow(_ key: String, _ value: Binding<Double>, unit: String = "") -> some View {
        settingsNumberRow(shop, key, value, unit: unit)
    }

    /// The accent as a colour, and back to the hex the document is styled with.
    private var accent: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: draft.invAccent) ?? NSColor(red: 0.37, green: 0.18, blue: 0.08, alpha: 1)) },
            set: { draft.invAccent = NSColor($0).hexString ?? draft.invAccent })
    }
}

// MARK: - Production

/// How work moves through the shop: delivery estimates, work-in-progress
/// limits, stock and purchase orders, quality control, post-processing and
/// custom order fields (Settings stage 2).
struct ProductionPane: View {
    let shop: Shop

    struct Draft: Equatable {
        var dailyHours = 8.0, workingDaysPerWeek = 5.0, finishingDays = 1.0, dispatchDays = 1.0, safetyDays = 1.0
        var publishToCloud = false
        var wip: [String: Double] = [:]
        var wipEnforceHardLimit = false
        var qcEnabled = false, qcRequireInspector = false, qcRequirePhotoOnFail = false, qcWarrantyDays = 30.0
        var autoDeduct = true, lowStock = 200.0
        /// Draft purchase orders for what is low, without being asked.
        /// Opt-in and drafts only — the shop still reviews them.
        var autoDraftPo = false
        /// Minutes one spool change takes — an ESTIMATE, used only to say what
        /// grouping the queue by colour saves (`lib/swap-queue.js`). Moves on
        /// to Printers & Slicers with the rest of the printing defaults.
        var swapMinutes = ProductionPane.swapMinutesDefault

        static let columns = ["pending", "printing", "post", "qc"]

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            let lead = SettingsReader(settings: r.object("leadTime"))
            let wip = r.object("wipLimits")
            let qc = SettingsReader(settings: r.object("qc"))
            var d = Draft(
                dailyHours: lead.number("dailyHours", 8), workingDaysPerWeek: lead.number("workingDaysPerWeek", 5),
                finishingDays: lead.number("finishingDays", 1), dispatchDays: lead.number("dispatchDays", 1),
                safetyDays: lead.number("safetyDays", 1), publishToCloud: lead.flag("publishToCloud"),
                wipEnforceHardLimit: r.flag("wipEnforceHardLimit"),
                qcEnabled: qc.flag("enabled"), qcRequireInspector: qc.flag("requireInspector"),
                qcRequirePhotoOnFail: qc.flag("requirePhotoOnFail"), qcWarrantyDays: qc.number("warrantyDays", 30),
                autoDeduct: r.onUnlessOff("autoDeduct"), lowStock: r.number("lowStockThreshold", 200),
                autoDraftPo: r.flag("autoDraftPo"),
                swapMinutes: r.number("swapMinutes", ProductionPane.swapMinutesDefault))
            for col in columns { d.wip[col] = Shop.plainNumber(wip[col]) ?? 0 }
            return d
        }
        func form() -> [String: JSONValue] {
            ["leadTime": .object(["dailyHours": .number(dailyHours), "workingDaysPerWeek": .number(workingDaysPerWeek),
                                  "finishingDays": .number(finishingDays), "dispatchDays": .number(dispatchDays),
                                  "safetyDays": .number(safetyDays), "publishToCloud": .bool(publishToCloud)]),
             "wip": .object(wip.mapValues(JSONValue.number)),
             "wipEnforceHardLimit": .bool(wipEnforceHardLimit),
             "qc": .object(["enabled": .bool(qcEnabled), "requireInspector": .bool(qcRequireInspector),
                            "requirePhotoOnFail": .bool(qcRequirePhotoOnFail), "warrantyDays": .number(qcWarrantyDays)]),
             "autoDeduct": .bool(autoDeduct), "lowStock": .number(lowStock),
             "autoDraftPo": .bool(autoDraftPo),
             "swapMinutes": .number(swapMinutes)]
        }
    }

    /// What the field shows for a shop that never set it. The rule's own
    /// `DEFAULT_SWAP_MINUTES`; `SwapPlanningTests` holds the two together.
    nonisolated static let swapMinutesDefault = 3.0

    @State private var draft = Draft()
    @State private var original = Draft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    // ── THE HOURS AND THE DAYS ARE THE GRID ABOVE ────────
                    //
                    // "Printing hours per working day" and "Working days per
                    // week" used to be typed here, a few rows under a Working
                    // Hours grid that says the same two things per day. Both
                    // were editable and they disagreed silently: a shop that
                    // closed Friday in the grid still had its promises counted
                    // on whatever was left in these boxes.
                    //
                    // The promise reads the grid now, so these would be two
                    // fields a shop can change with no effect — which is worse
                    // than the disagreement was. They are gone, and the footer
                    // says where the numbers come from.
                    numberRow("set.lead_finishing", $draft.finishingDays)
                    numberRow("set.lead_dispatch", $draft.dispatchDays)
                    numberRow("set.lead_safety", $draft.safetyDays)
                    Toggle(shop.words.callIt("set.lead_publish"), isOn: $draft.publishToCloud)
                } header: {
                    Text(shop.words.callIt("set.lead_title"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shop.words.callIt("mac.lead_from_hours"))
                        Text(shop.words.callIt("set.lead_safety_hint"))
                    }
                }
                Section(shop.words.callIt("set.wip_limits")) {
                    ForEach(Draft.columns, id: \.self) { col in
                        row(shop.words.callIt(Stage(rawValue: col)?.key ?? col)) {
                            TextField("", value: Binding(get: { draft.wip[col] ?? 0 }, set: { draft.wip[col] = $0 }),
                                      format: .number.locale(Money.digits).precision(.fractionLength(0)))
                                .multilineTextAlignment(.trailing).frame(width: 70)
                        }
                    }
                    Toggle(shop.words.callIt("set.wip_enforce_hard"), isOn: $draft.wipEnforceHardLimit)
                }
                Section(shop.words.callIt("set.stock_section")) {
                    Toggle(shop.words.callIt("set.auto_deduct"), isOn: $draft.autoDeduct)
                    row(shop.words.callIt("set.low_stock")) {
                        TextField("", value: $draft.lowStock, format: .number.locale(Money.digits).precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                    }
                }
                Section {
                    Toggle(shop.words.callIt("reorder.auto_toggle"), isOn: $draft.autoDraftPo)
                } footer: {
                    Text(shop.words.callIt("reorder.auto_hint"))
                }
                // Beside the other two opt-in automations, which is what it is.
                // The words are the other app's — it has had this switch all
                // along — so they arrive in nine languages rather than two.
                Section {
                    numberRow("mac.swap_minutes", $draft.swapMinutes)
                } footer: {
                    Text(shop.words.callIt("mac.swap_minutes_hint"))
                }
                Section(shop.words.callIt("set.qc_head")) {
                    Toggle(shop.words.callIt("set.qc_enabled"), isOn: $draft.qcEnabled)
                    Toggle(shop.words.callIt("set.qc_require_inspector"), isOn: $draft.qcRequireInspector).disabled(!draft.qcEnabled)
                    Toggle(shop.words.callIt("set.qc_require_photo"), isOn: $draft.qcRequirePhotoOnFail).disabled(!draft.qcEnabled)
                    numberRow("set.qc_warranty_days", $draft.qcWarrantyDays).disabled(!draft.qcEnabled)
                }
                // Saved as each one is added or removed, as the desktop's
                // lists are — straight to the book, not with the bar below.
                PostChecklistSettingsSection(shop: shop)
                PostPresetsSettingsSection(shop: shop)
                CustomFieldsSettingsSection(shop: shop)
                // Saved as each reading is logged, like the sites and staff
                // at the top — a reading is a record, not a setting.
                EnvironmentLogSection(shop: shop)

            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form(), opened: original.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
    /// A number, and the unit it is in where the label does not already say.
    private func numberRow(_ key: String, _ value: Binding<Double>, unit: String = "") -> some View {
        settingsNumberRow(shop, key, value, unit: unit)
    }
}

// MARK: - General

/// This Mac and how the app reads: language, digits, appearance, the menu
/// bar, Spotlight, updates, privacy, the browser extension, and how much of
/// the app the shop wants. Only the language is in the draft the bar saves;
/// everything else is this Mac's own or saves itself.
struct GeneralPane: View {
    let shop: Shop

    struct Draft: Equatable {
        var lang = "en"
        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            Draft(lang: SettingsReader(settings: settings).text("lang", "en"))
        }
        func form() -> [String: JSONValue] { ["lang": .string(lang)] }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @AppStorage("mac.menuBar") private var menuBar = true
    @AppStorage(Spotlight.defaultsKey) private var spotlight = true
    @AppStorage(MenuBarStyle.defaultsKey) private var menuBarStyle = MenuBarStyle.ringAndFigures.rawValue
    @AppStorage(FinishChime.defaultsKey) private var finishChime = false
    @AppStorage(PrintNoticeKind.finished.defaultsKey) private var notifyFinished = true
    @AppStorage(PrintNoticeKind.failed.defaultsKey) private var notifyFailed = true
    @AppStorage(PrintNoticeKind.paused.defaultsKey) private var notifyPaused = true
    /// The same key AND the same default as `ShopWindow` — both from
    /// `ShellChoice`, because declaring the default twice is how this switch
    /// came to read OFF in a window that was drawing the new shell.
    @AppStorage(ShellChoice.key) private var newShell = ShellChoice.byDefault

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
                // ── THE REDESIGNED WINDOW ─────────────────────────────────
                //
                // Off by default while the rest of the app is migrated screen
                // by screen. Here rather than hidden behind a `defaults write`
                // because a switch nobody can reach is a feature nobody can
                // judge — and the whole point of shipping it early is to live
                // with it before the other fifteen screens follow.
                Section(shop.words.callIt("set.appearance")) {
                    Toggle(shop.words.callIt("set.new_shell"), isOn: $newShell)
                    Text(shop.words.callIt("set.new_shell_why"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // MAC-LOCAL, and deliberately not in `Draft`. Everything else
                // on this pane is written into the shop's settings and reaches
                // every device; whether this Mac shows a menu bar icon is not
                // the shop's business and must not follow the book around.
                //
                // HEADED "On this Mac" for that reason, and it used to repeat
                // `set.prefs_section` — so the pane printed "App Preferences"
                // twice, two rows apart, and nothing said which of them syncs.
                // Two sections with one name read as one section with a gap in
                // it. Found by photographing the pane, which had never been
                // done: the snapshot runner could not open the settings window
                // while an orphaned Khayt held the status bar.
                Section(shop.words.callIt("mac.on_this_mac")) {
                    // WHICH DIGITS — first, because it sits with the language
                    // above: Western 0–9 in both languages unless this Mac's
                    // owner wants the Mac's own (`Digits`). This Mac's, not
                    // the book's: a reading habit, like the two below.
                    Toggle(shop.words.callIt("mac.mac_digits"), isOn: Binding(
                        get: { Digits.shared.followsMac },
                        set: { on in
                            Digits.shared.followsMac = on
                            // The widgets draw from the snapshot, which says.
                            WidgetFeed.shared.update(shop: shop)
                        }))
                    Text(shop.words.callIt("mac.mac_digits_note"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    UpdateToggles(shop: shop)
                    Toggle(shop.words.callIt("mac.menu_bar"), isOn: $menuBar)
                        .onChange(of: menuBar) { _, on in
                            // AppKit, so nothing redraws itself: say so plainly.
                            if on { FloorStatus.shared.install(shop: shop) }
                            else { FloorStatus.shared.remove() }
                        }
                    // What the item draws: the ring and "64%" (or how many print), the ring
                    // alone, or the nozzle as it always was. Mac-local, beside
                    // the switch above (`MenuBarStyle`).
                    Picker(shop.words.callIt("mac.mbp_style"), selection: $menuBarStyle) {
                        ForEach(MenuBarStyle.allCases, id: \.rawValue) { style in
                            Text(shop.words.callIt(style.wordKey)).tag(style.rawValue)
                        }
                    }
                    .disabled(!menuBar)
                    .onChange(of: menuBarStyle) { _, _ in FloorStatus.shared.restyle() }
                    // One soft sound when a print finishes. Off unless
                    // somebody wants it (`FinishChime`), and not tied to the
                    // menu bar switch: the print finishes either way.
                    Toggle(shop.words.callIt("mac.mbh_chime"), isOn: $finishChime)
                    // The print notices this Mac did not send before
                    // (`PrintNotices.swift`). Faults, runouts and silent
                    // printers were already notified and have no switch here.
                    Toggle(shop.words.callIt(PrintNoticeKind.finished.toggleKey), isOn: $notifyFinished)
                    Toggle(shop.words.callIt(PrintNoticeKind.failed.toggleKey), isOn: $notifyFailed)
                    Toggle(shop.words.callIt(PrintNoticeKind.paused.toggleKey), isOn: $notifyPaused)
                    Text(shop.words.callIt("mac.mbp_notify_note"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // SWITCHING THIS OFF HAS TO UNDO IT.
                    //
                    // A toggle that stops adding to an index but leaves what is
                    // already in it is not an off switch, it is a pause — and
                    // the person reaching for it wants their library out of
                    // their Mac's search, today.
                    Toggle(shop.words.callIt("mac.spotlight"), isOn: $spotlight)
                        .onChange(of: spotlight) { _, on in
                            if on { Spotlight.shared.reindex(shop: shop) }
                            else { Spotlight.shared.forget() }
                        }
                    Text(shop.words.callIt("mac.spotlight_note"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                // ── HOW MUCH OF THE APP THE SHOP WANTS ────────────────────
                //
                // Saved on the spot rather than with the bar below, because it
                // is NOT part of this pane's draft: `settings-edit.js` keeps
                // `out.mode = s.mode || 'professional'` — it preserves the
                // stored mode and takes none from a form — so a mode sent
                // through the Save bar would be read and thrown away. The
                // other app's pills write it straight onto the settings too.
                Section(shop.words.callIt("set.experience")) {
                    Text(shop.words.callIt("set.mode_subtitle"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("", selection: Binding(
                        get: { shop.mode },
                        set: { wanted in Task { await shop.chooseMode(wanted) } }
                    )) {
                        Text(shop.words.callIt("set.mode_simple")).tag("simple")
                        Text(shop.words.callIt("set.mode_pro")).tag("professional")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!shop.canWrite)
                    Text(shop.words.callIt("set.mode_changed_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // What Simple actually takes away, said out loud. The other
                    // app draws a whole tier comparison here; this names the
                    // two shelves this app itself hides, which is the part a
                    // person switching is about to notice.
                    if shop.mode == "simple" {
                        Text(shop.words.callIt("mac.simple_hides"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Crash reports and usage counts (#1789): the book's consent,
                // saved on the spot rather than with the bar below.
                TelemetrySettings(shop: shop)
                ActiveCountSettings(shop: shop)
                // Save to Khayt: whether this Mac takes pages from the
                // browser extension, and the door to switching it on.
                BrowserExtensionSettings(shop: shop)
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form(), opened: original.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
}

// MARK: - Preferences

struct PreferencesPane: View {
    let shop: Shop

    struct Draft: Equatable {
        /// The four estimator constants a shop can actually answer for.
        ///
        /// THROUGHPUT IS DELIBERATELY NOT HERE. It is the one nobody knows
        /// about their own printer, and Khayt learns it from jobs whose real
        /// weight and duration were recorded. Offering a field for it would
        /// invite guessing the very number the calibration exists to stop
        /// anyone guessing.
        var density = 1.24, infillPct = 20.0, wallMm = 1.2, wastePct = 5.0
        /// `demand` or `import`. Read as text with no default asserted here —
        /// `lib/print-risk.js` owns the default, and the save path normalises
        /// whatever this holds through the same reader.
        var riskWhen = ""

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let r = SettingsReader(settings: settings)
            let risk = SettingsReader(settings: r.object("printRisk"))
            let est = SettingsReader(settings: r.object("estimator"))
            return Draft(// The rule's own defaults, so an unset book shows what
                         // it is actually estimating with rather than blanks.
                         density: est.number("densityGPerCm3", 1.24),
                         infillPct: est.number("infillPct", 0.2) * 100,
                         wallMm: est.number("wallThicknessMm", 1.2),
                         wastePct: est.number("wastePct", 0.05) * 100,
                         // The shop's answer if it has given one, and otherwise
                         // whatever the shared rule says the default is — asked
                         // for rather than repeated, so the picker cannot show
                         // one thing while an import does another.
                         riskWhen: {
                             let stored = risk.text("when", "")
                             return stored.isEmpty ? (shop.riskWhen ?? "demand") : stored
                         }())
        }
        func form() -> [String: JSONValue] {
            ["printRisk": .object(["when": .string(riskWhen)]),
             // Per cent on screen, fraction in the book — the rule reads 0..1
             // and a 20 saved there would be 2,000% infill.
             "estimator": .object(["densityGPerCm3": .number(density),
                                   "infillPct": .number(infillPct / 100),
                                   "wallThicknessMm": .number(wallMm),
                                   "wastePct": .number(wastePct / 100)])]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("mac.est_section")) {
                    row(shop.words.callIt("mac.est_density")) {
                        TextField("", value: $draft.density, format: .number.locale(Money.digits).precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    row(shop.words.callIt("mac.est_infill")) {
                        TextField("", value: $draft.infillPct, format: .number.locale(Money.digits).precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    row(shop.words.callIt("mac.est_wall")) {
                        TextField("", value: $draft.wallMm, format: .number.locale(Money.digits).precision(.fractionLength(1)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    Text(shop.words.callIt("mac.est_wall_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    row(shop.words.callIt("mac.est_waste")) {
                        TextField("", value: $draft.wastePct, format: .number.locale(Money.digits).precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    // Said here rather than left to be wondered about: the
                    // missing field is missing on purpose.
                    Text(shop.words.callIt("mac.est_rate_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section(shop.words.callIt("mac.library")) {
                    row(shop.words.callIt("set.risk_when")) {
                        Picker("", selection: $draft.riskWhen) {
                            Text(shop.words.callIt("set.risk_demand")).tag("demand")
                            Text(shop.words.callIt("set.risk_import")).tag("import")
                        }.labelsHidden().frame(width: 220)
                    }
                    // The cost, said plainly and next to the choice. Reading a
                    // mesh is seconds on a real file, and a shop that turns
                    // this on without being told that finds out during its next
                    // four-hundred-file import.
                    Text(shop.words.callIt("set.risk_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LibraryLocationSettings(shop: shop)
                // Online storage (Google Drive, a bucket) is under Online,
                // where shops looked for it — see `OnlinePane`. Off-site
                // backups moved to Settings › Khayt Cloud (`CloudPane`).
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form(), opened: original.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() { original = .read(shop.settingsDict, shop: shop); draft = original }
}

// MARK: - The assistant

/// Which AI, and what each feature is allowed to send.
///
/// THE TWO HALVES SHIP TOGETHER, and that is the whole design of this screen.
/// A provider chooser on its own would let a shop point Khayt at a vendor
/// without ever being told that drafting a reply sends a customer's name, their
/// order reference and their outstanding balance. A consent list on its own
/// would name a vendor the shop had not chosen. `lib/ai-privacy.js` exists
/// because the first version of this was one toggle called "AI quote" over four
/// features that transmit very different things.
///
/// Nothing here decides anything. The features, their disclosures, whether each
/// is on, which providers exist and whether an address may receive a key all
/// come from the shared rules — the screen must never be able to show a feature
/// as off while the gate runs it.
struct AssistantPane: View {
    let shop: Shop

    struct Draft: Equatable {
        var enabled = false
        var provider = "anthropic"
        var baseUrl = ""
        var model = ""
        /// Typed, not stored. Empty means "keep the sealed one".
        var key = ""
        /// True when the shop has asked to remove the stored key.
        var clearKey = false
        var features: [String: Bool] = [:]
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var features: [KhaytEngine.AiFeature] = []
    @State private var providers: [KhaytEngine.AiProvider] = []
    @State private var chosen: KhaytEngine.AiProvider?
    @State private var addressProblem: String?
    @State private var hasStoredKey = false

    private var providerLabel: String {
        chosen?.label ?? providers.first { $0.id == draft.provider }?.label ?? draft.provider
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(shop.words.callIt("set.ai_master"), isOn: $draft.enabled)
                    Text(shop.words.callIt("set.ai_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // EVERY ROW STATES WHAT IT SENDS, and names the provider it
                // sends to — a disclosure that says "Anthropic" to a shop on
                // OpenAI is worse than none.
                //
                // ── AND WHERE THEY RUN, WHICH IS NOT YET HERE ─────────────
                //
                // This app bundles `ai-providers` and `ai-privacy` — the half
                // that decides which vendor and whether a feature MAY run — and
                // none of `ai-quote`, `ai-price`, `ai-reply` or `ai-assistant`,
                // which are the features themselves. So every switch below is
                // real consent over a shared book and a no-op on this Mac.
                //
                // The screen still earns its place: the book syncs, so a shop
                // running both apps had no way to see — let alone refuse — what
                // the other one sends. But a switch that does nothing where you
                // switched it has to say so, or the next question is why the
                // quote screen never offers a draft.
                Section(shop.words.callIt("set.ai_feats")) {
                    ForEach(features) { f in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Toggle(shop.words.callIt(f.labelKey),
                                       isOn: binding(for: f.id))
                                    .disabled(!draft.enabled)
                                if f.sendsCustomerData {
                                    Text(shop.words.callIt("set.ai_pii_badge"))
                                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Khayt.attention.opacity(0.16), in: Capsule())
                                        .foregroundStyle(Khayt.attention)
                                }
                            }
                            Text(shop.words.callIt("set.ai_sends_to",
                                                   ["provider": .string(providerLabel)])
                                 + " " + shop.words.callIt(f.sendsKey))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if f.needsConsent {
                                Text(shop.words.callIt("set.ai_reconsent"))
                                    .font(.caption).foregroundStyle(Khayt.attention)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            // On the features this app cannot perform yet, and
                            // only those. See `Shop.aiFeaturesOnThisMac`.
                            if !Shop.aiRunsHere(f.id) {
                                Text(shop.words.callIt("mac.ai_elsewhere"))
                                    .font(.caption).foregroundStyle(Khayt.note)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                // What the shop's key has spent this month, per feature.
                AiSpendSection(shop: shop)

                Section(shop.words.callIt("set.ai_provider")) {
                    row(shop.words.callIt("set.ai_provider")) {
                        Picker("", selection: $draft.provider) {
                            ForEach(providers) { p in Text(p.label).tag(p.id) }
                        }
                        .labelsHidden().frame(width: 220)
                        .onChange(of: draft.provider) { _, id in
                            // The model belongs to the provider: asking OpenAI
                            // for `claude-opus-5` is a 404 that reads as a bad
                            // key. Cleared so the new default shows through.
                            draft.model = ""
                            Task { await pickProvider(id) }
                        }
                    }
                    if chosen?.needsBaseUrl == true || !draft.baseUrl.isEmpty {
                        row(shop.words.callIt("set.ai_base_url")) {
                            TextField("", text: $draft.baseUrl, prompt: Text(verbatim: "http://localhost:11434"))
                                .frame(width: 240)
                                .onChange(of: draft.baseUrl) { _, v in Task { await checkAddress(v) } }
                        }
                        if let addressProblem {
                            Text(addressProblem)
                                .font(.caption).foregroundStyle(Khayt.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    row(shop.words.callIt("calc.ai_key")) {
                        SecureField("", text: $draft.key,
                                    prompt: Text(verbatim: hasStoredKey ? "••••••••" : ""))
                            .labelsHidden()
                            .frame(width: 240)
                    }
                    if hasStoredKey && draft.key.isEmpty {
                        Toggle(shop.words.callIt("mac.ai_forget_key"), isOn: $draft.clearKey)
                            .font(.caption)
                    }
                    row(shop.words.callIt("set.ai_model")) {
                        TextField("", text: $draft.model,
                                  prompt: Text(verbatim: chosen?.defaultModel ?? ""))
                            .labelsHidden()
                            .frame(width: 240)
                    }
                }

                // ── THE ASSISTANTS THAT ASK THE BOOK, NOT THE ONE ABOVE ───
                //
                // `khayt-mcp` answers whatever assistant the shop connects to
                // it, and that may be a cloud service. Saved the moment it
                // changes, like the telemetry consents: a choice about what
                // leaves the Mac is not part of the provider draft, and the
                // master switch above does not govern it.
                Section {
                    Toggle(isOn: Binding(get: { shop.sharesCustomerNamesWithMcp },
                                         set: { on in Task { await shop.shareCustomerNamesWithMcp(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shop.words.callIt("mac.mcp_share_names"))
                            Text(shop.words.callIt("mac.mcp_share_names_hint"))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(!shop.canWrite || !shop.source.isReal)
                    // Where the program is, and the setup an assistant needs,
                    // ready to paste: the switch above governs a program the
                    // shop could not find before (it was not in the app).
                    if let mcp = Shop.mcpExecutable {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shop.words.callIt("mac.mcp_where"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: mcp.path)
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(shop.words.callIt("mac.mcp_copy_setup")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Shop.mcpSetup(path: mcp.path), forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original && addressProblem == nil,
                    save: { Task { await save() } },
                    revert: { draft = original; addressProblem = nil })
        }
        .task(id: shop.settingsValue) { await reload() }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { draft.features[id] ?? false },
                set: { draft.features[id] = $0 })
    }

    private func reload() async {
        guard let engine = shop.engine else { return }
        let settings = shop.settingsDict
        features = (try? await engine.aiFeatures(settings: settings)) ?? []
        providers = (try? await engine.aiProviders()) ?? []
        chosen = try? await engine.aiProviderOf(settings: settings)

        let ai: [String: JSONValue] = {
            if case .object(let o)? = settings["ai"] { return o } else { return [:] }
        }()
        let text = { (k: String) -> String in
            if case .string(let v)? = ai[k] { return v } else { return "" }
        }
        hasStoredKey = !text("apiKey").isEmpty
        var d = Draft()
        d.enabled = { if case .bool(let b)? = ai["enabled"] { return b } else { return false } }()
        d.provider = chosen?.id ?? "anthropic"
        d.baseUrl = text("baseUrl")
        d.model = text("model")
        // Read through `aiFeatures`, which applies the consent migration — so a
        // book from before per-feature consent shows the same answers the gate
        // would give rather than four blanks.
        for f in features { d.features[f.id] = f.enabled }
        draft = d
        original = d
        addressProblem = nil
    }

    private func pickProvider(_ id: String) async {
        guard let engine = shop.engine else { return }
        var ai: [String: JSONValue] = [:]
        if case .object(let o)? = shop.settingsDict["ai"] { ai = o }
        ai["provider"] = .string(id)
        chosen = try? await engine.aiProviderOf(settings: ["ai": .object(ai)])
    }

    /// What the pane sends, the key aside — also run over what it opened
    /// with, so what was not touched is kept as stored.
    static func form(_ draft: Draft) -> [String: JSONValue] {
        [
            "enabled": .bool(draft.enabled),
            "provider": .string(draft.provider),
            "baseUrl": .string(draft.baseUrl.trimmingCharacters(in: .whitespaces)),
            "model": .string(draft.model.trimmingCharacters(in: .whitespaces)),
            "features": .object(draft.features.mapValues(JSONValue.bool)),
        ]
    }

    private func checkAddress(_ raw: String) async {
        guard let engine = shop.engine else { return }
        addressProblem = (try? await engine.aiAddressProblem(raw)) ?? nil
    }

    private func save() async {
        // The address is checked before anything is written, and a bad one stops
        // the save rather than being stored for the next request to use.
        if let engine = shop.engine,
           let problem = try? await engine.aiAddressProblem(draft.baseUrl), problem != nil {
            addressProblem = problem
            return
        }
        var ai = Self.form(draft)
        // ── THE KEY IS SEALED HERE OR NOT WRITTEN AT ALL ──────────────────
        //
        // `settings.ai.apiKey` is a registered secret path, so what belongs in
        // the book is `__enc__` + OSCrypt under the book's own Keychain key —
        // the same bytes Electron writes and reads. A key that cannot be sealed
        // is REFUSED rather than written in the clear: this file syncs, backs
        // up and exports.
        let typed = draft.key.trimmingCharacters(in: .whitespaces)
        if draft.clearKey && typed.isEmpty {
            ai["apiKey"] = .string("")
        } else if !typed.isEmpty {
            guard let build = shop.source.build else {
                shop.settingsProblem = shop.words.callIt("mac.move_sample"); return
            }
            do { ai["apiKey"] = .string(try await Secrets.seal(typed, for: build)) }
            catch {
                shop.settingsProblem = shop.words.callIt("mac.ai_key_unsealed"); return
            }
        }
        // Absent `apiKey` means the shared rule carries the stored one through.
        await shop.saveSettings(["ai": .object(ai)], opened: ["ai": .object(Self.form(original))])
        draft.key = ""
        draft.clearKey = false
        await reload()
    }
}

// MARK: - Customer names, to an assistant over khayt-mcp

extension Shop {
    /// `khayt-mcp` inside this app (`make-app.sh` puts it beside the app's own
    /// executable). Nil when it is not there — a `swift run` build — so
    /// Settings never offers a path that does not exist.
    static var mcpExecutable: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/khayt-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// What an assistant's configuration needs to start it — Claude Desktop's
    /// `claude_desktop_config.json` shape, which other MCP hosts copy.
    nonisolated static func mcpSetup(path: String) -> String {
        let body: [String: Any] = ["mcpServers": ["khayt": ["command": path]]]
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return path }
        return text
    }

    /// `settings.mcp.shareCustomerNames` — true only when the book says so.
    /// `khayt-mcp` reads the same key (`CustomerNames.sharing`).
    var sharesCustomerNamesWithMcp: Bool {
        guard case .object(let mcp)? = settingsDict["mcp"],
              case .bool(let on)? = mcp["shareCustomerNames"] else { return false }
        return on
    }

    /// The settings with the choice written in, every other key of the `mcp`
    /// block kept as the book has it.
    nonisolated static func sharingCustomerNames(_ on: Bool, over settings: [String: JSONValue]) -> [String: JSONValue] {
        var settings = settings
        var mcp: [String: JSONValue] = [:]
        if case .object(let o)? = settings["mcp"] { mcp = o }
        mcp["shareCustomerNames"] = .bool(on)
        settings["mcp"] = .object(mcp)
        return settings
    }

    /// Choose whether assistants connected to `khayt-mcp` read customers'
    /// names. Straight onto the settings, not through the settings form:
    /// `settings-edit.js` takes no `mcp` block from a form. The staff lock
    /// decides, as for every other setting.
    func shareCustomerNamesWithMcp(_ on: Bool) async {
        writeProblem = nil
        guard source.isReal else { writeProblem = words.callIt("mac.move_sample"); return }
        guard permitted(LockGate.person("settings", "edit")) else { return }
        guard let build = source.build else { return }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                root["settings"] = .object(Self.sharingCustomerNames(on, over: Self.settings(root)))
            }
        } catch {
            writeProblem = ErrorText.plain(error)
            return
        }
        await load(source)
    }
}

// MARK: - The shop's text fields, per language

extension Shop {
    struct ContentField: Hashable {
        let key: String
        let base: String
        let language: String
        let label: String

        /// Which edge this field's TEXT starts at.
        ///
        /// ── WHY IT IS NOT SIMPLY `.leading` ───────────────────────────────
        ///
        /// `.leading` and `.trailing` resolve against the layout direction of
        /// the WINDOW, not of the field, and overriding `layoutDirection` on a
        /// `TextField` does not move its text on macOS — measured, by
        /// photographing it. So a field holding Arabic inside an English
        /// window has to ask for the opposite edge to the one the window calls
        /// leading, and vice versa.
        ///
        /// Written as a disagreement between two directions rather than as two
        /// cases, because the four combinations are what it has to get right:
        /// an Arabic name in an English window starts at the right, an English
        /// name in an Arabic window starts at the left, and a field in its own
        /// window's direction starts where everything else on the screen does.
        func textAlignment(appIsRTL: Bool) -> TextAlignment {
            (language == "ar") == appIsRTL ? .leading : .trailing
        }
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
        // `#abc` and `#aabbccdd` as well as `#aabbcc`: CSS reads all three,
        // and so does every colour picker in the other app. A machine stored
        // as `#f80` opened here as the fallback blue.
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        if s.count == 8 { s = String(s.prefix(6)) }
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
                            .accessibilityLabel(shop.words.callIt("mac.slicer_make_default"))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(slicer.name)
                                Text(slicer.path)
                                    .font(.caption).foregroundStyle(Khayt.faint)
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
                            .accessibilityLabel(shop.words.callIt("mac.slicer_remove"))
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
                        .font(.caption).foregroundStyle(Khayt.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: dirty,
                    save: { Task { await shop.saveSlicers(list, defaultId: defaultId,
                                                                opened: (original, originalDefault)); reset() } },
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
