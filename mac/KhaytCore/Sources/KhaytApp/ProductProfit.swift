import SwiftUI
import KhaytCore

/// Which of the things the shop sells actually makes money.
///
/// NOT which sells most, and a shop that confuses the two prices the wrong
/// thing. The row worth finding is the big seller that earns nothing, so this
/// is ranked by PROFIT — ranking by revenue, which the other app does, puts
/// that row at the top looking like the best thing in the shop.
///
/// ── AND THE FIGURE A PRINT SHOP SHOULD OPTIMISE ───────────────────────────
///
/// Profit per machine hour. The constraint is not money, it is the hours the
/// printers can run — so two products at the same margin are not equal if one
/// takes two hours and the other twenty. It is stated in a sentence rather than
/// left as a column, because it is usually NOT the top row and a reader
/// scanning down the table will not find it.
struct ProductProfitTable: View {
    let shop: Shop
    let report: KhaytEngine.ProductProfit?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("mac.pp_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)

            if let report, !report.rows.isEmpty {
                if let best = report.totals.bestPerHour, let rate = best.profitPerHour {
                    Text(words.callIt("mac.pp_best", [
                        "name": .string(best.name),
                        "amount": .string(Money.text(rate, shop.currency)),
                    ]))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Rows(shop: shop, rows: report.rows)
            } else {
                EmptyHere(title: words.callIt("an.no_data"), mark: .catalogue)
            }
        }
    }

    private struct Rows: View {
        let shop: Shop
        let rows: [KhaytEngine.ProductProfit.Row]

        var body: some View {
            let words = shop.words
            // Against the best AND the worst, because a loss-making product is
            // a real row and a bar drawn from zero cannot show one.
            let widest = max(rows.map { abs($0.profit) }.max() ?? 0, 1)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.callout).lineLimit(1)
                            Text(detail(row, words)).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.text(row.profit, shop.currency))
                                .font(.callout.weight(.medium)).monospacedDigit()
                                // Red for a product that loses money, and
                                // nothing for one that does not: every other
                                // row is the ordinary case.
                                .foregroundStyle(row.profit < 0 ? Khayt.late : .primary)
                            Capsule()
                                .fill((row.profit < 0 ? Khayt.late : Khayt.brand).opacity(0.55))
                                .frame(width: max(4, (abs(row.profit) / widest) * 90), height: 3)
                        }
                    }
                    .padding(.vertical, 6)
                    if index < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
        }

        /// The line under the name: how many, how long, and what a machine hour
        /// on it is worth.
        private func detail(_ row: KhaytEngine.ProductProfit.Row, _ words: Words) -> String {
            var parts = ["\(row.jobs)×"]
            if let margin = row.marginPct {
                parts.append(Money.quantity(margin, decimals: 0) + "%")
            }
            if let rate = row.profitPerHour {
                parts.append(Money.text(rate, shop.currency) + " " + words.callIt("mac.pp_per_hour"))
            }
            return parts.joined(separator: " · ")
        }
    }
}
