import SwiftUI
import KhaytCore

/// Which products are the best use of the printer.
///
/// The shop has one printer, so the thing it runs out of is machine hours.
/// `lib/profit-per-hour.js` ranks the catalogue by (price − cost) ÷ print
/// hours, and — where the product has been made — puts what the finished jobs
/// really earned per hour beside it. Three places show it: a sortable column in
/// the Catalogue, a card in Reports, and a few quiet suggestions in the Web
/// Store sheet. All three read one report, worked out once per load.
extension Shop {

    /// Work the ranking out and put the rate on each catalogue row.
    func readProfitPerHour() async {
        guard let engine else { stampPerHour(nil); return }
        let report = try? await engine.profitPerHour(
            products: productRows, orders: orderRows, expenses: expenseRows,
            inventory: inventoryRows, consumables: consumableRows,
            settings: settingsDict, clients: clientRows, language: words.language)
        stampPerHour(report)
    }
}

enum PerHour {
    /// A rate as the shop reads it, or a dash when there is none — a product
    /// with no hours or no price has no rate, and a zero would be a claim.
    @MainActor static func text(_ value: Double?, _ shop: Shop) -> String {
        guard let value else { return "—" }
        return shop.words.callIt("mac.pph_rate", ["amount": .string(Money.text(value, shop.currency))])
    }
}

// MARK: - Reports

/// "Best use of the printer": the catalogue by profit per machine hour.
///
/// Planned first — every product has one — with the actual beside it where
/// finished jobs exist. A product under the shop's own average is marked, with
/// the price that would bring it level, because that is the decision the card
/// is for.
struct BestUseOfPrinterCard: View {
    let shop: Shop
    let report: KhaytEngine.ProfitPerHour?
    /// Enough to see the top and the tail without making Reports a catalogue.
    static let shown = 8

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("mac.pph_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)
            Text(words.callIt("mac.pph_intro"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report, report.totals.ranked > 0 {
                if let average = report.totals.averagePerHour {
                    Text(words.callIt("mac.pph_average", ["amount": .string(Money.text(average, shop.currency))]))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actual = report.totals.actualPerHour {
                    Text(words.callIt("mac.pph_actual_average", ["amount": .string(Money.text(actual, shop.currency))]))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let ranked = report.rows.filter { $0.perHour != nil }
                let widest = max(ranked.map { abs($0.perHour ?? 0) }.max() ?? 0, 1)
                VStack(spacing: 0) {
                    let rows = Array(ranked.prefix(Self.shown))
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Line(shop: shop, row: row, widest: widest)
                            .padding(.vertical, 6)
                        if index < rows.count - 1 { Divider().opacity(0.5) }
                    }
                }
                let unranked = report.totals.noHours + report.totals.noPrice
                if unranked > 0 {
                    Text(words.callIt("mac.pph_unranked", ["n": .number(Double(unranked))]))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                EmptyHere(title: words.callIt("mac.pph_empty"), mark: .catalogue)
            }
        }
    }

    private struct Line: View {
        let shop: Shop
        let row: KhaytEngine.ProfitPerHour.Row
        let widest: Double

        var body: some View {
            let words = shop.words
            let rate = row.perHour ?? 0
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.name.isEmpty ? words.callIt("mac.unnamed") : row.name)
                        .font(.callout).lineLimit(1)
                    Text(detail(words)).font(.caption)
                        .foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.underpriced, let price = row.suggestedPrice {
                        Label(words.callIt("mac.pph_under", ["amount": .string(Money.text(price, shop.currency))]),
                              systemImage: "arrow.up.circle")
                            .font(.caption).foregroundStyle(Khayt.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(PerHour.text(row.perHour, shop))
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(rate < 0 ? Khayt.late : .primary)
                    Capsule()
                        .fill((rate < 0 ? Khayt.late : Khayt.brand).opacity(0.55))
                        .frame(width: max(4, (abs(rate) / widest) * 90), height: 3)
                }
            }
        }

        /// Hours, the price, and what the real jobs said — the actual rate and,
        /// where a printer measured it, how far the hours ran from the estimate.
        private func detail(_ words: Words) -> String {
            var parts: [String] = []
            if let hours = row.hours {
                parts.append(words.callIt("mac.pp_hours", ["n": .string(Money.quantity(hours, decimals: 1))]))
            }
            if let price = row.price { parts.append(Money.text(price, shop.currency)) }
            if let actual = row.actual, let rate = actual.perHour {
                parts.append(words.callIt("mac.pph_actual_jobs", [
                    "amount": .string(Money.text(rate, shop.currency)),
                    "n": .number(Double(actual.jobs)),
                ]))
                if let drift = actual.hoursDriftPct, abs(drift) >= 5 {
                    parts.append(words.callIt(drift > 0 ? "mac.pph_longer" : "mac.pph_shorter",
                                              ["pct": .number(abs(drift).rounded())]))
                }
            }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - Web store

/// Gentle suggestions under the web store's review: which listed products earn
/// most per printer hour, and which look underpriced against the shop's own
/// average. Advice only — nothing here changes a price.
struct WebStorePerHourHints: View {
    let shop: Shop
    let report: KhaytEngine.ProfitPerHour

    static func hasAnything(_ report: KhaytEngine.ProfitPerHour?) -> Bool {
        guard let report else { return false }
        return !report.storeBest.isEmpty || !report.storeUnderpriced.isEmpty
    }

    var body: some View {
        let words = shop.words
        Section(words.callIt("mac.ws_pph_title")) {
            if !report.storeBest.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(words.callIt("mac.ws_pph_best"), systemImage: "star")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(report.storeBest) { row in
                        HStack {
                            Text(verbatim: row.name).font(.callout)
                            Spacer(minLength: 8)
                            Text(PerHour.text(row.perHour, shop)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !report.storeUnderpriced.isEmpty, let average = report.totals.averagePerHour {
                VStack(alignment: .leading, spacing: 4) {
                    Label(words.callIt("mac.ws_pph_under"), systemImage: "lightbulb")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(report.storeUnderpriced) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: row.name).font(.callout)
                            Text(words.callIt("mac.ws_pph_under_line", [
                                "rate": .string(PerHour.text(row.perHour, shop)),
                                "average": .string(PerHour.text(average, shop)),
                                "price": .string(Money.text(row.suggestedPrice ?? 0, shop.currency)),
                            ]))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
