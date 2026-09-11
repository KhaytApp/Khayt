import SwiftUI
import KhaytCore

/// What the shop's materials cost, and whether that has moved.
///
/// A shop quoting off last year's filament price is quoting at a loss. Nothing
/// has answered this: the other app has a supplier price history, which needs a
/// suppliers list and purchase records inside it that no shop's book actually
/// has. The spools have it — every one carries what it cost and what it held.
///
/// ── EACH IN ITS OWN UNIT ──────────────────────────────────────────────────
///
/// A kilo, a litre, one sheet. A per-kilo figure for everything reported the
/// sample shop's acrylic at 42,000, because a sheet is not weighed — so the
/// rows are grouped by unit and never interleave two kinds of price.
struct MaterialCostCard: View {
    let shop: Shop
    let report: KhaytEngine.MaterialCost?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("mac.mc_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.cyan)

            if let report, !report.rows.isEmpty {
                // The one finding on the card. A shop scanning a column of
                // percentages finds the number; it does not find the sentence.
                if let steepest = report.totals.steepest, let pct = steepest.changePct {
                    Text(words.callIt("mac.mc_risen", [
                        "name": .string(steepest.material),
                        "pct": .number(pct.rounded()),
                    ]))
                    .font(.callout)
                    .foregroundStyle(pct >= 10 ? Khayt.attention : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if !report.totals.anyChangeKnown {
                    // Not an empty column of dashes: a shop that has bought
                    // each thing once cannot be told a price has moved, and
                    // saying why beats printing nothing.
                    Text(words.callIt("mac.mc_none"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Rows(shop: shop, rows: report.rows)
            } else {
                EmptyHere(title: words.callIt("an.no_data"), mark: .filament)
            }
        }
    }

    private struct Rows: View {
        let shop: Shop
        let rows: [KhaytEngine.MaterialCost.Row]

        var body: some View {
            let words = shop.words
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.material).font(.callout).lineLimit(1)
                            Text(words.callIt("mac.mc_per", ["unit": .string(row.rate)])
                                 + (row.spoolCount < 2
                                    ? " · " + words.callIt("mac.mc_one_buy")
                                    : " · \(row.spoolCount)×"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(Money.text(row.perUnit, shop.currency))
                            .font(.callout.weight(.medium)).monospacedDigit()
                        // The change, or nothing. An arrow rather than a sign,
                        // because a "+" on a cost is good news everywhere else
                        // on this screen and here it is the opposite.
                        Text(change(row))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(tint(row))
                            .frame(width: 56, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    if index < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
        }

        private func change(_ row: KhaytEngine.MaterialCost.Row) -> String {
            guard let pct = row.changePct, abs(pct) >= 1 else { return "" }
            return (pct > 0 ? "▲ " : "▼ ") + Money.quantity(abs(pct), decimals: 0) + "%"
        }

        /// Red for dearer, and nothing at all for cheaper — a shop paying less
        /// than it used to does not need telling twice.
        private func tint(_ row: KhaytEngine.MaterialCost.Row) -> Color {
            guard let pct = row.changePct, abs(pct) >= 1 else { return .secondary }
            return pct > 0 ? Khayt.late : .secondary
        }
    }
}
