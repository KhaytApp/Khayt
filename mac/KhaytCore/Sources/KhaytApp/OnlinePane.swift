import SwiftUI
import KhaytCore

// MARK: - Online

/// The LAN server's switch, port and PIN — the block the Electron page keeps
/// under "Advanced: REST API…", in that page's own words.
///
/// Save restarts the server when the port or the PIN changed, because the
/// server is started from the book and a save is a reload of the book. There
/// is no separate Start button: on this app the switch IS the button, and a
/// switch that could disagree with what is running is two sources of truth.
struct OnlinePane: View {
    let shop: Shop

    struct Draft: Equatable {
        var enabled = false
        var port = "3219"
        var bindLan = false
        /// What was typed. Blank keeps the stored PIN — the rule's reading.
        var pin = ""
        /// Whether the book has a PIN at all, sealed or not.
        var pinStored = false

        @MainActor static func read(_ settings: [String: JSONValue], shop: Shop) -> Draft {
            let lan = SettingsReader(settings: SettingsReader(settings: settings).object("lanApi"))
            var d = Draft(enabled: lan.flag("enabled"),
                          port: String(Int(lan.number("port", 3219))),
                          bindLan: lan.flag("bindLan"),
                          pin: "",
                          pinStored: !lan.text("pin").isEmpty)
            readQuote(settings, into: &d)
            return d
        }

        var portNumber: Int { Int(port.trimmingCharacters(in: .whitespaces)) ?? 3219 }

        // ── WHAT A CUSTOMER MAY BE QUOTED ─────────────────────────────────
        //
        // Text, not numbers, for the same reason the product sheet's rates
        // are: blank is not zero. A shop that has not said what a spool costs
        // must not be read as saying it costs nothing.
        var quoteOn = false
        var presetId = ""
        var filamentId = ""
        /// Price a customer's upload by SLICING it, rather than estimating
        /// from its shape. Off unless the shop turns it on: it is the only
        /// setting in Khayt that writes a stranger's file down and points a
        /// native binary at it.
        var sliceUploads = false
        /// Which slicer does that. Empty means the shop's default.
        var sliceWithId = ""
        var spoolCost = "", spoolWeight = "", margin = "", minPrice = "", waste = "", limit = ""

        @MainActor static func readQuote(_ settings: [String: JSONValue], into d: inout Draft) {
            let lan = SettingsReader(settings: SettingsReader(settings: settings).object("lanApi"))
            let q = SettingsReader(settings: lan.object("intakeQuote"))
            d.quoteOn = q.flag("enabled")
            d.presetId = q.text("presetId")
            d.filamentId = q.text("filamentId")
            d.spoolCost = Money.fieldValue(q.number("spoolCost", 0))
            d.spoolWeight = Money.fieldValue(q.number("spoolWeight", 1000))
            d.margin = Money.fieldValue(q.number("marginPct", 0))
            d.minPrice = Money.fieldValue(q.number("minPrice", 0))
            // Stored as a fraction, shown as a percentage — the other app's
            // page does the same, and storing what is shown would quietly
            // multiply every shop's waste allowance by a hundred.
            d.waste = Money.fieldValue(q.number("wastePct", 0) * 100)
            d.limit = Money.fieldValue(q.number("hourlyLimit", 12))
            d.sliceUploads = q.flag("sliceUploads")
            d.sliceWithId = q.text("sliceWithId")
        }

        func quoteForm() -> [String: JSONValue] {
            let n = { (t: String, fallback: Double) -> Double in
                let cleaned = t.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? fallback : (Double(cleaned) ?? fallback)
            }
            return [
                "enabled": .bool(quoteOn),
                "presetId": .string(presetId), "filamentId": .string(filamentId),
                "spoolCost": .number(max(0, n(spoolCost, 0))),
                "spoolWeight": .number(max(1, n(spoolWeight, 1000))),
                "marginPct": .number(max(0, n(margin, 0))),
                "minPrice": .number(max(0, n(minPrice, 0))),
                "wastePct": .number(min(0.5, max(0, n(waste, 0) / 100))),
                "hourlyLimit": .number(min(10_000, max(1, n(limit, 12)))),
                "sliceUploads": .bool(sliceUploads),
                "sliceWithId": .string(sliceWithId),
            ]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var showQuote = false
    @State private var newPresetName = ""
    @State private var presetRates: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(shop.words.callIt("mac.online_title")) {
                    Text(shop.words.callIt("mac.online_desc"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(shop.words.callIt("lan.enabled"), isOn: $draft.enabled)
                    LabeledContent(shop.words.callIt("lan.port")) {
                        TextField("", text: $draft.port)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle(shop.words.callIt("lan.bind_lan"), isOn: $draft.bindLan)
                    Text(shop.words.callIt(draft.bindLan ? "lan.bind_lan_hint" : "lan.loopback_warn"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    LabeledContent(shop.words.callIt("lan.pin")) {
                        SecureField(draft.pinStored ? shop.words.callIt("common.secret_unchanged") : "",
                                    text: $draft.pin)
                            .frame(maxWidth: 220)
                    }
                    if draft.enabled, !draft.pinStored, draft.pin.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label(shop.words.callIt("mac.lan_pin_missing"), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Khayt.attention)
                    }
                }
                // ── LETTING A STRANGER SEE A PRICE ────────────────────
                //
                // Folded away, and off unless the shop turns it on: this is
                // the only place in Khayt where a number is computed for
                // somebody who is not the shop.
                Section {
                    DisclosureGroup(isExpanded: $showQuote) {
                        Toggle(shop.words.callIt("lan.iq_enable"), isOn: $draft.quoteOn)
                        Text(shop.words.callIt("lan.iq_enable_hint"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LabeledContent(shop.words.callIt("lan.iq_printer")) {
                            Picker("", selection: $draft.presetId) {
                                Text(shop.words.callIt("lan.iq_pick")).tag("")
                                ForEach(shop.presets) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                            .labelsHidden().frame(maxWidth: 220)
                        }
                        // THE ONE THAT STOPS IT WORKING. The shared rule builds
                        // a customer's price from a real preset and refuses
                        // without one, so a shop with none is told here rather
                        // than left to wonder why the form never answers.
                        if shop.presets.isEmpty {
                            Label(shop.words.callIt("mac.iq_no_preset"), systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Khayt.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        LabeledContent(shop.words.callIt("lan.iq_filament")) {
                            Picker("", selection: $draft.filamentId) {
                                Text(shop.words.callIt("lan.iq_flat")).tag("")
                                ForEach(shop.spools) { spool in
                                    Text(spool.label(shop.words, unit: shop.unit(of: spool))).tag(spool.id)
                                }
                            }
                            .labelsHidden().frame(maxWidth: 220)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            quoteRow("lan.iq_spool_cost", $draft.spoolCost, unit: shop.currency)
                            quoteRow("lan.iq_spool_weight", $draft.spoolWeight, unit: "g")
                            quoteRow("lan.iq_margin", $draft.margin, unit: "%")
                            quoteRow("lan.iq_min", $draft.minPrice, unit: shop.currency)
                            quoteRow("lan.iq_waste", $draft.waste, unit: "%")
                            quoteRow("lan.iq_limit", $draft.limit, unit: "")
                        }
                        Text(shop.words.callIt("lan.iq_note"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // ── PRICED BY THE SLICER, NOT BY THE SHAPE ────────
                        //
                        // The estimate above is worked out from the model's
                        // geometry, and geometry cannot know about purge: on
                        // the shop's own four-colour dragon the slicer said
                        // 57 g where the shape said 13. Asking the slicer is
                        // the only way to close that.
                        //
                        // It is also the only setting here that writes a
                        // stranger's file down and points a native binary at
                        // it, so it is off until the shop says otherwise and
                        // the sentence beside it says what the check before
                        // it does and does not promise.
                        Divider()
                        Toggle(shop.words.callIt("mac.iq_slice"), isOn: $draft.sliceUploads)
                        Text(shop.words.callIt("mac.iq_slice_hint"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if draft.sliceUploads {
                            LabeledContent(shop.words.callIt("mac.iq_slice_with")) {
                                Picker("", selection: $draft.sliceWithId) {
                                    Text(shop.words.callIt("mac.iq_slice_default")).tag("")
                                    ForEach(shop.slicers) { slicer in
                                        Text(slicer.name).tag(slicer.id)
                                    }
                                }
                                .labelsHidden().frame(maxWidth: 220)
                            }
                            if shop.slicers.isEmpty {
                                Label(shop.words.callIt("slicer.none"), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(Khayt.attention)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        presetMaker
                    } label: {
                        Text(shop.words.callIt("lan.iq_enable")).font(.callout)
                    }
                }
                Section {
                    if let url = shop.lanURL {
                        Text(shop.words.callIt("mac.lan_open")).font(.callout)
                        Text(url)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("lan-url")
                        // "…Customer form: /intake" — true here now.
                        Text(shop.words.callIt("lan.same_wifi_hint"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // The calendar subscription, in the other app's words.
                        if let calendar = shop.calendarLink {
                            Text(shop.words.callIt("icalDescription")).font(.callout).padding(.top, 6)
                            Text(calendar)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .accessibilityIdentifier("calendar-url")
                        }
                    } else {
                        Text(shop.words.callIt("lan.not_running")).foregroundStyle(.secondary)
                    }
                    if let problem = shop.lanProblem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Khayt.attention).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(shop.words.callIt("mac.lan_restart_note"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task {
                        await shop.saveLanSettings(enabled: draft.enabled, port: draft.portNumber,
                                                   pin: draft.pin, bindLan: draft.bindLan,
                                                   intakeQuote: draft.quoteForm())
                        reset()
                    } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
    }

    /// Make a preset here, because the shop cannot make one anywhere else in
    /// this app — and without one the whole section above does nothing. A name
    /// and the seven figures a part is costed at, which is exactly what the
    /// other app's calculator saves under "Save preset".
    private var presetMaker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(shop.words.callIt("mac.iq_new_preset")).font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                TextField(shop.words.callIt("calc.machine.preset_name_ph"), text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                Button(shop.words.callIt("calc.machine.save_preset")) {
                    Task {
                        var rates: [String: Double] = [:]
                        for key in Shop.Preset.rateKeys {
                            let typed = (presetRates[key] ?? "").replacingOccurrences(of: ",", with: "")
                                .trimmingCharacters(in: .whitespaces)
                            rates[key] = max(0, Double(typed) ?? 0)
                        }
                        if let id = await shop.savePreset(name: newPresetName, rates: rates) {
                            // Chosen straight away: a preset made and then not
                            // picked is the same as no preset at all.
                            draft.presetId = id
                            newPresetName = ""
                        }
                    }
                }
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                presetRow("calc.labor.rate", "laborRate", unit: shop.currency)
                presetRow("calc.labor.prep", "prepTime", unit: shop.words.callIt("common.hours"))
                presetRow("calc.labor.post", "postTime", unit: shop.words.callIt("common.hours"))
                presetRow("calc.machine.wear", "wearRate", unit: shop.currency)
                presetRow("calc.machine.power", "powerDraw", unit: shop.words.callIt("calc.machine.watts"))
                presetRow("calc.machine.elec", "elecRate", unit: shop.words.callIt("calc.machine.per_kwh"))
                presetRow("calc.labor.failure", "failureRate", unit: "%")
            }
        }
    }

    private func quoteRow(_ key: String, _ text: Binding<String>, unit: String) -> some View {
        GridRow {
            Text(shop.words.callIt(key)).gridColumnAlignment(.trailing)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder).frame(width: 80).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
            }
        }
    }

    private func presetRow(_ key: String, _ field: String, unit: String) -> some View {
        quoteRow(key, Binding(get: { presetRates[field] ?? "" },
                              set: { presetRates[field] = $0 }), unit: unit)
    }

    private func reset() {
        original = .read(shop.settingsDict, shop: shop)
        draft = original
        Task {
            if presetRates.isEmpty, let defaults = await shop.printRateDefaults() { presetRates = defaults }
        }
    }
}
