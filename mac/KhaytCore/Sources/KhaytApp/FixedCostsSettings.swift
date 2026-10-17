import SwiftUI
import KhaytCore

/// What the shop pays every month whether it prints anything or not.
///
/// ── THE SCREEN POINTED AT A DOOR THIS APP DID NOT HAVE ────────────────────
///
/// `BreakEven` already says the right thing when there is nothing here: *"No
/// fixed costs are set, so there is no target to reach. Add rent,
/// subscriptions and anything else that is paid every month in Settings."*
/// Its comment is careful about it — "NOT 'no data'. A shop reaches this by
/// never having told Khayt what it pays every month, which is a thing it can
/// go and do — so the screen says what and where."
///
/// And Settings had nowhere to do it. The sentence was written for the other
/// app's Settings and shipped in this one, so a shop following the instruction
/// arrived at a pane that did not exist.
///
/// It is not only the break-even target: `lib/pnl-report.js` puts a quarter's
/// share of these into the Profit & Loss, so a Mac-only shop's P&L has been
/// computed as though the business had no overhead at all — a wrong figure
/// rather than a missing one, which is the worse kind.
struct FixedCostsSettings: View {
    let shop: Shop

    /// One line a shop can type. `id` is carried so that editing a row is not
    /// deleting it and adding another — the other app keys its list on it.
    struct Line: Identifiable, Equatable {
        var id: String
        var name: String
        var amount: Double
    }

    @State private var lines: [Line] = []
    @State private var original: [Line] = []
    /// The overhead-per-print-hour line, as the pane edits it and as it opened.
    @State private var overhead = OverheadForm()
    @State private var overheadOpened = OverheadForm()

    /// `settings.overheadPerHour` as a form: on or off, and the shop's own
    /// monthly print hours — nil (an EMPTY field) to work them out from the
    /// machines.
    ///
    /// Optional because the hint under the field says "leave it empty", and a
    /// non-optional Double could not be left empty: it showed 0, never the
    /// "Auto" prompt, and clearing it put the 0 back (alpha.74 review). The
    /// stored 0 the rule writes for "auto" reads back as nil, so a book saved
    /// by either app opens on the prompt.
    struct OverheadForm: Equatable {
        var enabled = false
        var monthlyHours: Double?

        static func read(_ settings: [String: JSONValue]) -> OverheadForm {
            guard case .object(let o)? = settings["overheadPerHour"] else { return OverheadForm() }
            var f = OverheadForm()
            if case .bool(true)? = o["enabled"] { f.enabled = true }
            if let n = Shop.plainNumber(o["monthlyHours"]), n.isFinite, n > 0 { f.monthlyHours = n }
            return f
        }

        /// As the pane sends it: the hours only when there is a figure — an
        /// empty field is sent ABSENT, never as a 0 somebody typed.
        /// `lib/settings-edit.js` cleans it with the rule that reads it
        /// (`KhaytOverheadRate.clean`), which keeps "auto" as it always has.
        var value: JSONValue {
            var o: [String: JSONValue] = ["enabled": .bool(enabled)]
            if let h = monthlyHours, h.isFinite, h > 0 { o["monthlyHours"] = .number(h) }
            return .object(o)
        }
    }

    private var total: Double { lines.reduce(0) { $0 + $1.amount } }

    var body: some View {
        Section(shop.words.callIt("mac.fixed_section")) {
            if lines.isEmpty {
                Text(shop.words.callIt("mac.fixed_none"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($lines.byID) { $line in
                HStack {
                    // The hint goes INSIDE the field. A title argument is
                    // drawn as a label beside it once the field has a bezel,
                    // so every row in this list repeated the same sentence.
                    TextField("", text: $line.name,
                              prompt: Text(shop.words.callIt("mac.fixed_name_ph")))
                        .frame(maxWidth: .infinity)
                    LiveNumberField(value: $line.amount)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Button {
                        lines.removeAll { $0.id == line.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(shop.words.callIt("mac.fixed_remove"))
                }
            }

            HStack {
                Button(shop.words.callIt("mac.fixed_add")) {
                    lines.append(Line(id: "fc_" + UUID().uuidString.prefix(8).lowercased(),
                                      name: "", amount: 0))
                }
                Spacer()
                // The total, because it is the number the break-even target is
                // built from and a shop typing six rows should not have to add
                // them up to check.
                //
                // AND IT IS THE ONLY PLACE THE CURRENCY APPEARS. The first
                // draft put "SAR" beside every field — three repetitions of
                // the code, two lines above a total reading "3,510.00 ﷼",
                // which is two notations for one currency on one small pane.
                // `Money.text` is how this app writes money; the fields are
                // bare numbers and the total says what they are in.
                if !lines.isEmpty {
                    Text(shop.words.callIt("mac.fixed_total") + " "
                         + Money.text(total, shop.currency))
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }

            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(lines == original)
                if lines != original {
                    Button(shop.words.callIt("common.cancel")) { lines = original }
                }
                Spacer()
            }
        }
        .task(id: shop.settingsValue) { reload() }

        overheadSection
    }

    // MARK: - Overhead per print hour

    /// Whether quotes carry these costs by the print hour, and the figure
    /// they would carry. The rate is shown whether the line is on or off, so a
    /// shop can see what turning it on does before it does.
    @ViewBuilder private var overheadSection: some View {
        Section(shop.words.callIt("set.overhead_title")) {
            Toggle(shop.words.callIt("set.overhead_on"), isOn: $overhead.enabled)
            Text(shop.words.callIt("set.overhead_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(shop.words.callIt("set.overhead_hours"))
                Spacer()
                // A Double? so an empty field IS empty — the "Auto" prompt
                // shows, and that is what is saved — and bordered like the
                // other figures a shop types in Settings.
                TextField("", value: $overhead.monthlyHours,
                          format: .number.precision(.fractionLength(0)),
                          prompt: Text(shop.words.callIt("set.overhead_hours_ph")))
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            Text(shop.words.callIt("set.overhead_hours_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Where the figure comes from, worked out from the book as it was
            // last opened — saving re-opens it, so this follows a save.
            Text(Self.explanation(shop.overhead, words: shop.words, currency: shop.currency))
                .font(.callout.weight(.medium)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let left = shop.overhead?.left, !left.isEmpty {
                Text(shop.words.callIt("set.overhead_left",
                                       ["names": .string(left.map(\.name).joined(separator: ", "))]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await saveOverhead() } }
                    .disabled(overhead == overheadOpened)
                if overhead != overheadOpened {
                    Button(shop.words.callIt("common.cancel")) { overhead = overheadOpened }
                }
                Spacer()
            }
        }
    }

    /// "≈ 4.20 SAR per print hour from 2,100 SAR a month over ~500 h · your
    /// figure", or why there is no rate. Static so a test can hold it to what
    /// the rule resolved.
    static func explanation(_ o: KhaytEngine.Overhead?, words: Words, currency: String) -> String {
        guard let o else { return "" }
        guard let rate = o.rate, let hours = o.hours else {
            switch o.reason {
            case "no_costs": return words.callIt("set.overhead_no_costs")
            case "few_hours":
                return words.callIt("set.overhead_few_hours",
                                    ["min": .number(o.minHours),
                                     "hours": .number(((o.hours ?? 0)).rounded())])
            default: return words.callIt("set.overhead_no_hours")
            }
        }
        let said = words.callIt("set.overhead_rate", [
            "rate": .string(Money.text(rate, currency)),
            "cost": .string(Money.text(o.monthlyCost, currency)),
            "hours": .string(Words.plain(.number(hours.rounded()))),
        ])
        let from = words.callIt(o.source == "shop" ? "set.overhead_src_shop" : "set.overhead_src_machines")
        return said + " · " + from
    }

    private func saveOverhead() async {
        await shop.saveSettings(["overheadPerHour": overhead.value],
                                opened: ["overheadPerHour": overheadOpened.value])
        reload()
    }

    private func reload() {
        original = Self.read(shop.settingsDict)
        lines = original
        overheadOpened = OverheadForm.read(shop.settingsDict)
        overhead = overheadOpened
    }

    static func read(_ settings: [String: JSONValue]) -> [Line] {
        guard case .array(let rows)? = settings["fixedCosts"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let c) = row else { return nil }
            return Line(id: Shop.plainString(c["id"]) ?? UUID().uuidString,
                        name: Shop.plainString(c["name"]) ?? "",
                        amount: Shop.plainNumber(c["amount"]) ?? 0)
        }
    }

    /// The list as the pane sends it. Also run over the list it opened with,
    /// so a line nobody touched keeps every field the book gave it.
    static func form(_ lines: [Line]) -> JSONValue {
        .array(lines.map { line in
            .object(["id": .string(line.id),
                     "name": .string(line.name),
                     "amount": .number(line.amount)])
        })
    }

    private func save() async {
        // SENT WHOLE. A row removed on screen has to be a row removed in the
        // book, so this is the list and not a merge into the stored one.
        await shop.saveSettings(["fixedCosts": Self.form(lines)],
                                opened: ["fixedCosts": Self.form(original)])
        reload()
    }
}
