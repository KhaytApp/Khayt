import SwiftUI
import KhaytCore

/// What the shop spent, by category — the P&L's own expense figure, broken up.
///
/// ── WHY THIS IS HERE AND NOT ON THE EXPENSES SCREEN ───────────────────────
///
/// The Expenses screen already totals by category, and correctly: it sits
/// beside a table of what was PAID, so it sums what was paid. That panel is a
/// summary of the rows next to it and must keep agreeing with them.
///
/// This is a different figure with the same name. The P&L charges an expense
/// at `paid − reclaimable`, because for a registered shop the tax on a
/// purchase is not a cost — it is reclaimed. So a breakdown of the P&L's
/// expenses has to net it too, or the parts do not add up to the whole they
/// are a breakdown of. In the other app they did not: the chart summed the
/// gross while the P&L above it charged the net, and the two disagreed by the
/// entire reclaimable amount. `lib/expense-categories.js` is the one rule now,
/// and it takes the same reclaim test the P&L takes.
///
/// An unregistered shop reclaims nothing, so for most shops this and the
/// Expenses panel print the same numbers — which is correct, not a redundancy.
struct ExpenseCategoriesCard: View {
    let shop: Shop
    let report: KhaytEngine.Spending?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.exp_by_cat"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Spacer(minLength: 8)
                if let report, !report.rows.isEmpty {
                    Text(Money.text(report.total, shop.currency))
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }

            if let report, !report.rows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(report.rows, id: \.category) { row in
                        Row(shop: shop, row: row, peak: report.biggest)
                    }
                }
                // ── AND WHAT THE SHOP GETS BACK ───────────────────────────
                //
                // Only for a shop that reclaims anything. The figure is the
                // whole reason this card's totals differ from the Expenses
                // screen's, so it is said rather than left to be inferred
                // from two screens that appear to contradict each other.
                if report.reclaimed > 0 {
                    Text(words.callIt("mac.ec_reclaimed",
                                      ["amount": .string(Money.text(report.reclaimed,
                                                                    shop.currency))]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(words.callIt("an.no_data"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private struct Row: View {
        let shop: Shop
        let row: KhaytEngine.ExpenseCategoryRow
        let peak: Double

        var body: some View {
            HStack(spacing: 8) {
                Text(shop.words.callIt("exp.cat." + row.category))
                    .font(.callout).lineLimit(1)
                    .frame(width: 104, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Khayt.attention.opacity(0.8))
                            .frame(width: max(3, geo.size.width
                                               * CGFloat(share(of: peak))))
                            .growsToItsReading(share(of: peak), from: .leading)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 14)
                Text(Money.short(row.amount, shop.currency))
                    .font(.callout.weight(.medium)).monospacedDigit()
                    .frame(width: 78, alignment: .trailing)
                // The share of the whole, which is what makes a column of
                // amounts comparable between two periods of different size.
                Text("\(Int((row.share * 100).rounded()))%")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
        }

        /// Against the BIGGEST category, not the total: bars scaled to the
        /// total leave every row short in a book with many categories, and the
        /// comparison a reader makes here is between the rows.
        ///
        /// A negative category is possible — a refunded purchase larger than
        /// the period's other spending — and draws as the minimum sliver
        /// rather than as a bar growing the wrong way.
        private func share(of peak: Double) -> Double {
            guard peak > 0 else { return 0 }
            return max(0, min(1, row.amount / peak))
        }
    }
}
