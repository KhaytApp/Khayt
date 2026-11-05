import SwiftUI
import KhaytCore

// The three settings the desktop keeps in sections of their own, outside its
// form: the exchange-rate table, the invoice counter and the loyalty tiers.
// `settings-edit.apply` PRESERVES each of them and takes none from a form, so
// each section here writes its own keys with its own Save, through the rule
// the desktop's section uses (`Shop+MoneyStock.swift`).
//
// Not in a `*Sheet.swift` for the reason `LocationsSection` gives.

/// Whether whoever is here may change the shop's settings at all.
@MainActor private func mayEdit(_ shop: Shop) -> Bool {
    shop.canWrite && shop.lockAllows("settings", "edit")
}

// MARK: - Exchange rates

/// What one unit of each other currency is worth in the shop's own —
/// what a job priced in dollars is reported at. Typed, or fetched from the
/// same free feed the desktop asks.
struct ExchangeRatesSection: View {
    @Bindable var shop: Shop
    /// The typed rates, by code; nil is blank.
    @State private var typed: [String: Double?] = [:]
    @State private var original: [String: Double?] = [:]
    @State private var fetching = false
    @State private var problem: String?

    /// Every currency the shop knows but its own, in the shop's language.
    private var codes: [(code: String, label: String)] {
        shop.words.currencyChoices(shop.currencies.mapValues(\.label))
            .filter { $0.code != shop.currency }
    }

    /// The table as the book has it.
    static func stored(_ settings: [String: JSONValue]) -> [String: Double] {
        guard case .object(let rates)? = settings["exchangeRates"] else { return [:] }
        return rates.compactMapValues { Shop.plainNumber($0) }.filter { $0.value > 0 }
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 8) {
            Text(words.callIt("xr.section")).font(.headline)
            Text(words.callIt("xr.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    fetching = true
                    Task {
                        problem = await shop.fetchExchangeRates()
                        fetching = false
                    }
                } label: {
                    Label(words.callIt(fetching ? "xr.fetching" : "xr.fetch"), systemImage: "arrow.clockwise")
                }
                .disabled(fetching || !mayEdit(shop))
                if let at = Shop.plainString(shop.settingsDict["exchangeRatesUpdatedAt"]), !at.isEmpty {
                    Text(words.callIt("xr.updated") + " " + at)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Khayt.attention).font(.callout)
            }
            Text(words.callIt("xr.rate") + " (" + words.callIt("xr.rate_hint") + ")")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(codes, id: \.code) { item in
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(verbatim: "1 \(item.code) =").font(.caption).foregroundStyle(.secondary)
                        TextField("0.00", value: binding(item.code),
                                  format: .number.locale(Money.digits).precision(.fractionLength(0...6)))
                            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 110)
                        Text(verbatim: shop.currency).font(.caption).foregroundStyle(.secondary)
                    }
                    .environment(\.layoutDirection, .leftToRight)
                } label: {
                    Text(item.label).lineLimit(1)
                }
            }
            HStack {
                Spacer()
                Button(words.callIt("mac.revert")) { typed = original }
                    .disabled(typed == original)
                Button(words.callIt("common.save")) {
                    let edits = typed
                    Task { await shop.saveExchangeRates(edits) }
                }
                .disabled(typed == original || !mayEdit(shop))
            }
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func binding(_ code: String) -> Binding<Double?> {
        Binding(get: { typed[code] ?? nil }, set: { typed[code] = .some($0) })
    }

    private func reset() {
        let stored = Self.stored(shop.settingsDict)
        var table: [String: Double?] = [:]
        for item in codes { table[item.code] = .some(stored[item.code]) }
        original = table
        typed = table
    }
}

// MARK: - Invoice numbering

/// The formal invoice counter: its prefix, the next number, the format —
/// and the two things an auditor asks about it, a reset for the new year and
/// which numbers are missing.
struct InvoiceNumberingSection: View {
    @Bindable var shop: Shop
    @State private var prefix = "INV"
    @State private var next = 1
    @State private var format = "{prefix}-{year}-{seq4}"
    @State private var opened: (prefix: String, next: Int, format: String) = ("INV", 1, "{prefix}-{year}-{seq4}")
    @State private var gaps: [Int]?

    /// The formats both apps offer — `KhaytSettingsEdit.INV_NUM_FORMATS`.
    static let formats = ["{prefix}-{year}-{seq4}", "{prefix}-{seq4}"]

    /// What a number in `format` looks like — the desktop lists "e.g.
    /// INV-2026-0001" beside each.
    static func example(_ format: String, prefix: String, year: Int, seq: Int) -> String {
        format.replacingOccurrences(of: "{prefix}", with: prefix.isEmpty ? "INV" : prefix)
            .replacingOccurrences(of: "{year}", with: String(year))
            .replacingOccurrences(of: "{seq4}", with: String(format: "%04d", max(1, seq)))
    }

    private var year: Int { Calendar.book.component(.year, from: Date()) }
    private var dirty: Bool { prefix != opened.prefix || next != opened.next || format != opened.format }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 8) {
            Text(words.callIt("set.inv_num_title")).font(.headline)
            latinRow(words.callIt("set.inv_num_prefix")) {
                TextField("", text: $prefix).frame(width: 120)
            }
            row(words.callIt("set.inv_num_next")) {
                TextField("", value: $next, format: .number.locale(Money.digits).grouping(.never))
                    .monospacedDigit().frame(width: 90)
            }
            row(words.callIt("mac.inv_num_format")) {
                Picker("", selection: $format) {
                    ForEach(Self.formats, id: \.self) { f in
                        Text(verbatim: Self.example(f, prefix: prefix, year: year, seq: 1)).tag(f)
                    }
                }
                .labelsHidden()
            }
            Text(words.callIt("mac.inv_num_next_is",
                              ["number": .string(Self.example(format, prefix: prefix, year: year, seq: next))]))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(words.callIt("set.inv_num_reset")) {
                    Task { await shop.saveInvoiceNumbering(["reset": .bool(true)]) }
                }
                .disabled(!mayEdit(shop))
                Button(words.callIt("set.inv_num_detect_gaps")) {
                    Task { gaps = await shop.invoiceNumberGaps() }
                }
                Spacer()
                Button(words.callIt("mac.revert")) { reset() }.disabled(!dirty)
                Button(words.callIt("common.save")) {
                    let form: [String: JSONValue] = ["prefix": .string(prefix), "next": .number(Double(next)),
                                                     "format": .string(format)]
                    Task { await shop.saveInvoiceNumbering(form) }
                }
                .disabled(!dirty || !mayEdit(shop))
            }
            if let gaps {
                if gaps.isEmpty {
                    Label(words.callIt("set.inv_num_no_gaps"), systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(Khayt.done)
                } else {
                    Text(words.callIt("set.inv_num_gaps_found", ["n": .string(words.numeral(gaps.count))])
                         + ": " + gaps.prefix(20).map(String.init).joined(separator: ", "))
                        .font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: shop.settingsValue) { reset() }
    }

    private func reset() {
        let s = shop.settingsDict
        let p = Shop.plainString(s["invNumPrefix"]).flatMap { $0.isEmpty ? nil : $0 } ?? "INV"
        let n = max(1, Int(Shop.plainNumber(s["invNumNext"]) ?? 1))
        let stored = Shop.plainString(s["invNumFormat"]) ?? ""
        let f = Self.formats.contains(stored) ? stored : Self.formats[0]
        opened = (p, n, f)
        prefix = p; next = n; format = f
    }
}

// MARK: - Loyalty tiers

/// The tiers a customer climbs: a name, the orders and spend that reach it,
/// and the discount it brings. Saved through `lib/loyalty.js` `cleanTiers`,
/// which drops an unnamed row and keeps whatever else a tier carries.
struct LoyaltyTiersSection: View {
    @Bindable var shop: Shop

    /// One row of the editor. `rest` is the stored tier, so a field this
    /// editor does not show rides through the save.
    struct Tier: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var minOrders = 5
        var minSpend: Double = 0
        var discountPct: Double = 0
        var rest: [String: JSONValue] = [:]

        var record: [String: JSONValue] {
            var out = rest
            out["name"] = .string(name)
            out["minOrders"] = .number(Double(minOrders))
            out["minSpend"] = .number(minSpend)
            out["discountPct"] = .number(discountPct)
            return out
        }

        static func == (a: Tier, b: Tier) -> Bool {
            a.name == b.name && a.minOrders == b.minOrders && a.minSpend == b.minSpend
                && a.discountPct == b.discountPct && a.rest == b.rest
        }
    }

    @State private var tiers: [Tier] = []
    @State private var original: [Tier] = []

    static func read(_ settings: [String: JSONValue]) -> [Tier] {
        guard case .array(let rows)? = settings["loyaltyTiers"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let r) = row else { return nil }
            return Tier(name: Shop.plainString(r["name"]) ?? "",
                        minOrders: Int(Shop.plainNumber(r["minOrders"]) ?? 0),
                        minSpend: Shop.plainNumber(r["minSpend"]) ?? 0,
                        discountPct: Shop.plainNumber(r["discountPct"]) ?? 0,
                        rest: r)
        }
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 8) {
            Text(words.callIt("mac.loyalty_tiers")).font(.headline)
            Text(words.callIt("mac.loyalty_tiers_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !tiers.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text(words.callIt("mac.loyalty_tier_name"))
                        Text(words.callIt("set.loyalty_min_orders"))
                        Text(words.callIt("set.loyalty_min_spend"))
                        Text(words.callIt("set.loyalty_benefit"))
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach($tiers) { $tier in
                        GridRow {
                            TextField("", text: $tier.name).textFieldStyle(.roundedBorder).frame(minWidth: 110)
                            TextField("", value: $tier.minOrders, format: .number.locale(Money.digits))
                                .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 70)
                            TextField("", value: $tier.minSpend,
                                      format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 90)
                            TextField("", value: $tier.discountPct,
                                      format: .number.locale(Money.digits).precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 60)
                            Button(role: .destructive) {
                                tiers.removeAll { $0.id == tier.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(words.callIt("common.delete"))
                        }
                    }
                }
            }
            HStack {
                // An icon, not the catalogue's "+ " prefix — see the operators'.
                Button {
                    tiers.append(Tier())
                } label: {
                    Label(words.callIt("mac.loyalty_add_tier"), systemImage: "plus")
                }
                .disabled(!mayEdit(shop))
                Spacer()
                Button(words.callIt("mac.revert")) { tiers = original }.disabled(tiers == original)
                Button(words.callIt("common.save")) {
                    let records = tiers.map(\.record)
                    Task { await shop.saveLoyaltyTiers(records) }
                }
                .disabled(tiers == original || !mayEdit(shop))
            }
        }
        .task(id: shop.settingsValue) {
            original = Self.read(shop.settingsDict)
            tiers = original
        }
    }
}
