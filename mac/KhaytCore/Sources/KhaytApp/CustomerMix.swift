import SwiftUI
import KhaytCore

/// Is the shop growing, or serving the same people?
///
/// A shop living on returning customers is stable and not growing; one living
/// on new ones is growing and keeping nobody. Neither is wrong and the split
/// says which the shop is — which is a thing it cannot tell from a revenue
/// figure, however large.
///
/// ── PEOPLE AS WELL AS MONEY ───────────────────────────────────────────────
///
/// The other app reports orders. "12 from new clients" could be twelve people
/// or one person ordering twelve times, and those are different businesses. So
/// the count of PEOPLE is under each figure.
struct CustomerMixCard: View {
    let shop: Shop
    let report: KhaytEngine.CustomerMix?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("mac.cm_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.cyan)

            if let report, let share = report.fresh.shareOfRevenue {
                HStack(alignment: .top, spacing: 22) {
                    Side(words.callIt("mac.cm_new"), report.fresh, Khayt.cyan)
                    Side(words.callIt("mac.cm_returning"), report.returning, Khayt.done)
                    Spacer(minLength: 0)
                }

                // One bar, two shares — not two bars to be compared. The
                // question is what proportion of the money is which, and a
                // split bar answers it without any reading of lengths.
                Split(fresh: share)
                    .frame(height: 8)

                if let first = report.totals.firstOrderValue {
                    Text(words.callIt("mac.cm_first",
                                      ["amount": .string(Money.text(first, shop.currency))]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(words.callIt("an.no_data"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func Side(_ label: String, _ side: KhaytEngine.CustomerMix.Side,
                      _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 8, height: 8)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(Money.text(side.revenue, shop.currency))
                .font(.title3.weight(.medium)).monospacedDigit()
            // People, not orders — twelve sales to one person is not twelve
            // customers, and the other app could not tell them apart.
            Text(shop.words.callIt("mac.cm_people", ["n": .number(Double(side.clients))]))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private struct Split: View {
        let fresh: Double

        var body: some View {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    Capsule().fill(Khayt.cyan)
                        .frame(width: max(0, min(1, fresh)) * (geometry.size.width - 2))
                    Capsule().fill(Khayt.done)
                }
            }
        }
    }
}
