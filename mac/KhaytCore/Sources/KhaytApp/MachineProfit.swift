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
    /// How far each machine runs from the time it was quoted at, and the shop's
    /// own figure. Beside the money on purpose: "this printer earned 4,000" and
    /// "this printer takes 20% longer than you quote" are the same sentence
    /// read twice, and a shop deciding what to charge needs both at once.
    ///
    /// Drawn even when the P&L above it is empty — the periods are different.
    /// The money is filtered to the chosen range; accuracy is every measured
    /// print there has ever been, because a machine's calibration is not a
    /// property of this quarter.
    var accuracy: [KhaytEngine.MachineAccuracy] = []
    var shopAccuracy: KhaytEngine.MachineAccuracy?

    var body: some View {
        let words = shop.words
        if let report, !report.rows.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    rows(report)
                    Accuracy(shop: shop, rows: accuracy, all: shopAccuracy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if !accuracy.isEmpty {
            // The money is empty and the calibration is not, which happens
            // whenever a shop looks at a quiet month. Showing the empty state
            // over figures this screen HAS would be hiding them.
            ScrollView { Accuracy(shop: shop, rows: accuracy, all: shopAccuracy) }
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

    /// What the machines said about themselves.
    ///
    /// Split out of `rows` for the same reason that is: `ImageRenderer` draws
    /// nothing inside a `ScrollView` and does not say so, so anything the
    /// harness must photograph has to exist outside one.
    struct Accuracy: View {
        let shop: Shop
        let rows: [KhaytEngine.MachineAccuracy]
        let all: KhaytEngine.MachineAccuracy?

        var body: some View {
            let words = shop.words
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(words.callIt("an.machine_accuracy"))
                            .font(.callout.weight(.semibold))
                        Spacer()
                        if let all, let pct = all.hoursDeltaPct {
                            // The shop's own figure, off the same readings as
                            // the rows beneath it. The two used to be computed
                            // separately and nothing made them agree.
                            Text(signed(pct))
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(tint(pct))
                            Text(words.counting(all.sampled, "mac.acc_prints"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rows) { row in Line(shop: shop, row: row) }

                    // ── WHAT IS NOT COUNTED, AND WHY THE PANEL CAN LOOK THIN ─
                    //
                    // Only prints a PRINTER timed. The completion dialog
                    // pre-fills the estimate, so a typed actual is usually the
                    // estimate confirmed — counting those would compare an
                    // estimate to itself and report every machine as perfectly
                    // calibrated. A shop seeing two prints here rather than
                    // twenty is seeing the truth about its evidence.
                    Text(words.callIt("mac.acc_measured_only"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
                .padding(Metric.screen)
            }
        }

        /// Over is what costs a shop money. Under is worth knowing and is not a
        /// fault, so it does not get a warning colour — a machine that finishes
        /// early painted red teaches people to ignore the colour.
        private func tint(_ pct: Double) -> Color {
            if pct >= 25 { return Khayt.late }
            if pct >= 10 { return Khayt.attention }
            return Khayt.done
        }

        private func signed(_ pct: Double) -> String {
            (pct >= 0 ? "+" : "−") + Money.quantity(abs(pct), decimals: 1) + "%"
        }

        private struct Line: View {
            let shop: Shop
            let row: KhaytEngine.MachineAccuracy

            var body: some View {
                let words = shop.words
                let machine = shop.machines.first { $0.id == row.machineId }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Swatch.rgb(fromHex: machine?.color).map {
                            Color(red: $0.r, green: $0.g, blue: $0.b)
                        } ?? Color.secondary)
                        .frame(width: 4, height: 15)
                    Text(machine?.name ?? row.machineId)
                        .font(.callout.weight(.medium))
                    Text(words.counting(row.sampled, "mac.acc_prints"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // Quoted, then measured, then the gap — in that order,
                    // because the gap is only readable if the two figures it
                    // came from are on the same line.
                    Text(hours(row.estHours)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("→").font(.caption).foregroundStyle(.secondary)
                    Text(hours(row.actHours)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(row.hoursDeltaPct.map(signed) ?? "—")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(row.hoursDeltaPct.map(tint) ?? .secondary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 12)
            }

            private func hours(_ h: Double?) -> String {
                guard let h else { return "—" }
                return Money.quantity(h, decimals: 1) + shop.words.callIt("common.hours_short")
            }

            private func tint(_ pct: Double) -> Color {
                if pct >= 25 { return Khayt.late }
                if pct >= 10 { return Khayt.attention }
                return Khayt.done
            }

            private func signed(_ pct: Double) -> String {
                (pct >= 0 ? "+" : "−") + Money.quantity(abs(pct), decimals: 1) + "%"
            }
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
