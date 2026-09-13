import SwiftUI
import KhaytCore

/// Which customers are worth keeping.
///
/// What each has been worth over its whole life with the shop, how often it
/// comes back, and when it was last seen. Lifetime value is revenue EARNED —
/// the same set the quarters count — so a customer's total cannot disagree with
/// the P&L beside it, and a quote is not value however large it is.
///
/// ── THE LINE ABOVE THE TABLE IS THE POINT ─────────────────────────────────
///
/// A ranked list of customers is a thing a shop already knows. What it does not
/// know, and cannot work out by reading down a column, is how much of the
/// business rests on the first row. A shop with 60% of its revenue in one
/// customer has a different business from one with 6% — same table, different
/// decision — so that sentence is stated rather than left to be inferred.
struct ClientValueTable: View {
    let shop: Shop
    let report: KhaytEngine.ClientValue?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("an.client_ltv"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)

            if let report, !report.rows.isEmpty {
                // Stated, not inferred. And coloured only past the point where
                // it is a risk rather than a fact: every shop's biggest
                // customer is its biggest customer.
                let share = report.totals.topShare
                Text(words.callIt("mac.cv_share",
                                  ["pct": .number((share * 100).rounded())]))
                    .font(.callout)
                    .foregroundStyle(share >= 0.4 ? Khayt.attention : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Rows(shop: shop, rows: report.rows)
            } else {
                EmptyHere(title: words.callIt("an.no_data"), mark: .clients)
            }
        }
    }

    private struct Rows: View {
        let shop: Shop
        let rows: [KhaytEngine.ClientValue.Row]

        var body: some View {
            let words = shop.words
            let widest = max(rows.map(\.value).max() ?? 0, 1)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.callout).lineLimit(1)
                            Line(shop: shop, row: row)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.text(row.value, shop.currency))
                                .font(.callout.weight(.medium)).monospacedDigit()
                            // The bar is the comparison. A column of figures
                            // makes a reader measure the gap between the first
                            // and the fourth; a bar has already done it.
                            Capsule()
                                .fill(Khayt.brand.opacity(0.55))
                                .frame(width: max(4, (row.value / widest) * 90), height: 3)
                        }
                        Text("\(row.jobs)")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                            .help(words.callIt("an.op_jobs"))
                    }
                    .padding(.vertical, 6)
                    if index < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
        }

        /// The one sentence under each name: when they were last here, what
        /// they have in flight, or that they have never bought anything.
        private func Line(shop: Shop, row: KhaytEngine.ClientValue.Row) -> some View {
            let words = shop.words
            var parts: [String] = []
            if let days = row.daysSince {
                if row.quiet { parts.append(words.callIt("mac.cv_quiet_for",
                                                         ["n": .number(Double(days))])) }
            } else {
                parts.append(words.callIt("mac.cv_never"))
            }
            if row.inFlight > 0 {
                parts.append(Money.text(row.inFlight, shop.currency)
                             + " " + words.callIt("mac.cv_in_flight"))
            }
            return Text(parts.joined(separator: " · "))
                .font(.caption)
                // Amber only for the ones a shop should do something about.
                .foregroundStyle(row.quiet ? Khayt.attention : .secondary)
                .lineLimit(1)
                .opacity(parts.isEmpty ? 0 : 1)
        }
    }
}
