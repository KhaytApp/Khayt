import SwiftUI
import KhaytCore

/// What each machine earned, and what it cost to keep earning it.
///
/// ── THE QUESTION AN OWNER ASKS AFTER BUYING A MACHINE ────────────────────
///
/// "Was it worth it." The P&L page answers that for the SHOP; the unit the
/// money was spent on is the machine, and until now nothing here answered for
/// one. This shop has five, two of them bought recently and neither of them a
/// filament printer, so the question is live.
///
/// Every figure is `lib/machine-pl.js`'s, with revenue from `order-money` and
/// part cost from `calculator-cost` — the same two rules the rest of this app's
/// money comes from, so a machine's share of a quarter cannot disagree with the
/// quarter.
struct MachineProfitPage: View {
    let shop: Shop
    let report: KhaytEngine.MachineProfitReport?

    var body: some View {
        let words = shop.words
        if let report, !report.rows.isEmpty {
            ScrollView { rows(report) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // NOT "no data". A shop reaches this by having finished no work in
            // the period it is looking at, which is a thing it can change by
            // looking at another one.
            EmptyHere(title: words.callIt("mac.mpl_empty"),
                      message: words.callIt("mac.mpl_empty_why"), mark: .machines)
                .frame(maxHeight: .infinity)
        }
    }

    /// The rows, OUTSIDE the `ScrollView` that holds them.
    ///
    /// Split out so the harness can photograph them: `ImageRenderer` draws
    /// nothing inside a `ScrollView` and does not say so — the view comes back
    /// fully transparent, which reads as a white page in anything that opens
    /// the PNG. `Quoting.list` is split for the same reason.
    @ViewBuilder func rows(_ report: KhaytEngine.MachineProfitReport) -> some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.rows) { row in
                Row(shop: shop, row: row)
            }
            // The rows, added up — and they ARE the rows: the rule returns both
            // so a screen cannot show a sum that is not in the table above it.
            HStack {
                Text(words.callIt("mac.mpl_all_machines")).font(.callout.weight(.semibold))
                Spacer()
                Text(Money.text(report.totals.net, shop.currency))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(report.totals.net >= 0 ? Khayt.done : Khayt.late)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Khayt.recessed, in: RoundedRectangle(cornerRadius: 10))

            // ── WHAT THIS FIGURE IS NOT ──────────────────────────────────
            //
            // These margins run high — ninety per cent on the sample — because
            // what is taken off is what the JOB consumed: its filament, the
            // expenses filed against it, and the machine's own servicing. The
            // shop's labour, power, rent and everything else are in the P&L
            // and deliberately not here, because they are not a machine's to
            // carry and splitting them between five would be an invention.
            //
            // A shop that reads 90% as profit has been misled by a screen that
            // was accurate. So the screen says so.
            Text(words.callIt("mac.mpl_not_net"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .padding(Metric.screen)
    }

    private struct Row: View {
        let shop: Shop
        let row: KhaytEngine.MachineProfit

        var body: some View {
            let words = shop.words
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // The colour the shop gave this machine, which is how it is
                    // recognised on every other screen.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Swatch.rgb(fromHex: row.color).map {
                            Color(red: $0.r, green: $0.g, blue: $0.b)
                        } ?? Color.secondary)
                        .frame(width: 4, height: 15)
                    Text(row.name.isEmpty ? row.machineId : row.name)
                        .font(.headline)
                    Text(words.counting(row.jobs, "mac.jobs_word"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Money.text(row.net, shop.currency))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(row.net >= 0 ? Khayt.done : Khayt.late)
                }
                // What it earned, and the three things taken off it — laid out
                // so the arithmetic can be followed rather than trusted.
                HStack(alignment: .top, spacing: 20) {
                    Figure(label: words.callIt("an.revenue"), amount: row.revenue,
                           shop: shop, negative: false)
                    Figure(label: words.callIt("an.mat_cost_col"), amount: row.materialCost,
                           shop: shop, negative: true)
                    Figure(label: words.callIt("an.linked_exp_col"), amount: row.linkedExpenses,
                           shop: shop, negative: true)
                    Figure(label: words.callIt("an.maint_cost_col"), amount: row.maintenance,
                           shop: shop, negative: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(words.callIt("an.margin")).font(.caption).foregroundStyle(.secondary)
                        // AN EM DASH, NOT 0%. A machine that earned nothing has
                        // no margin, and zero reads as "broke even".
                        Text(row.marginPct.map { Money.quantity($0, decimals: 1) + "%" } ?? "—")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(tint(row.marginPct))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
        }

        /// Green at a healthy margin, amber at a thin one, red below — the same
        /// three bands Khayt's own table uses, so a shop reading both sees one
        /// judgement rather than two.
        private func tint(_ pct: Double?) -> Color {
            guard let pct else { return .secondary }
            if pct >= 30 { return Khayt.done }
            if pct >= 10 { return Khayt.attention }
            return Khayt.late
        }
    }

    private struct Figure: View {
        let label: String
        let amount: Double
        let shop: Shop
        let negative: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                // The minus sign belongs to the figure, not to a separate
                // label: `Money.text` of a negative already writes one, and a
                // cost stored positive has to be SHOWN as what it takes away.
                Text((negative && amount > 0 ? "−" : "") + Money.text(amount, shop.currency))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(negative && amount > 0 ? Khayt.late : .primary)
            }
        }
    }
}
