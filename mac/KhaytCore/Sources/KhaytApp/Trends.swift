import SwiftUI
import KhaytCore

/// What an hour of printing earned, and what a gram of material cost, month by
/// month for a year.
///
/// The two figures a shop can do something about. Revenue per print-hour is
/// the machine's worth as a shop actually runs it — quoting, failures, idle
/// time and all — and a month where it drops is a month worth asking about.
/// Cost per gram is what the shelf really cost, by the month each spool was
/// opened, so a supplier's price rise shows as a step rather than as a total
/// nobody can date.
///
/// The rule is `lib/cost-trends.js`, drawn by both apps. What this draws that
/// the other app does not: a month with no answer is a GAP, not a zero bar —
/// no printing is not "earned nothing per hour", and no spool opened is not
/// "material was free".
///
/// ── THE MONTH WORTH ASKING ABOUT WAS NOT READABLE ─────────────────────────
///
/// The whole argument above is that a month where the figure drops is worth
/// asking about — and twelve columns carrying one number each said only which
/// was taller. The figure beside the title was the window's, so the reader
/// could see the dip and not read it. It is a readout now: pointing at a month
/// puts that month's answer where the window's was, and names the month.
struct TrendsChart: View {
    let shop: Shop
    let trends: KhaytEngine.CostTrends?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("an.cost_trends"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)

            if let trends, trends.anyReading {
                Row(title: words.callIt("an.rev_per_hour"),
                    figure: trends.perHour.map { Money.text($0, shop.currency) },
                    values: trends.months.map { ($0.key, $0.perHour) },
                    colour: Khayt.brand,
                    currency: shop.currency, language: words.language)
                Row(title: words.callIt("an.cost_per_gram"),
                    figure: trends.costPerGram.map { Money.text($0, shop.currency) },
                    values: trends.months.map { ($0.key, $0.costPerGram) },
                    colour: Khayt.late,
                    currency: shop.currency, language: words.language)
            } else {
                Text(words.callIt("an.no_data"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// One figure across twelve months: the title, the whole window's answer,
    /// and a column per month — or a gap where the month had none.
    private struct Row: View {
        let title: String
        let figure: String?
        let values: [(key: String, value: Double?)]
        let colour: Color
        let currency: String
        let language: String

        /// `YYYY-MM`, while a pointer is on it. Per row on purpose: the two
        /// rows answer different questions and a reader is reading one of them.
        @State private var pointingAt: String?
        @Environment(\.accessibilityReduceMotion) private var reduced

        /// What the figure beside the title is saying: the month under the
        /// pointer, or the window. Nil for a month the shop has no answer for,
        /// which is the gap — and the figure says so rather than falling back
        /// to the window's and looking like the month had a reading.
        private var reading: (label: String, value: String?) {
            guard let pointingAt else { return (title, figure) }
            let month = values.first { $0.key == pointingAt }
            return (MonthLabel.long(pointingAt, language: language),
                    month?.value.map { Money.text($0, currency) })
        }

        var body: some View {
            let peak = max(values.compactMap(\.value).max() ?? 0, 0.0001)
            let now = reading
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(now.label)
                        .font(.caption)
                        .foregroundStyle(pointingAt == nil ? AnyShapeStyle(.secondary)
                                                           : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // A month with no reading shows the dash every column in
                    // this app shows for nothing, so the figure is never a
                    // number belonging to a different question.
                    Text(now.value ?? "—")
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(now.value == nil ? AnyShapeStyle(.quaternary)
                                                          : AnyShapeStyle(.primary))
                        .contentTransition(.numericText())
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(values, id: \.key) { month in
                        let here = pointingAt == month.key
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            if let value = month.value {
                                // A reading too small to draw still gets a
                                // sliver: a month that earned 3 an hour and a
                                // month with no reading must not look the same.
                                let fraction = max(0.04, min(1, value / peak))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(colour)
                                    .frame(height: fraction * 48)
                                    .growsToItsReading(fraction)
                            } else {
                                // The gap. A hairline where the bar would
                                // stand, so twelve columns still read as twelve.
                                Rectangle().fill(Khayt.hairline).frame(height: 1)
                            }
                            Text(MonthLabel.short(month.key))
                                .font(.caption2).monospacedDigit()
                                .foregroundStyle(here ? AnyShapeStyle(.primary)
                                                      : AnyShapeStyle(.secondary))
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 3)
                        .background(here ? Khayt.recessed : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .animation(Motion.of(Motion.hover, unless: reduced), value: here)
                        // The column, not the bar: a month whose reading is a
                        // sliver two points tall has to be as easy to ask
                        // about as the tallest one — and a gap month, which
                        // has no bar at all, has to be askable too. That is
                        // the month a reader most wants to point at.
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { pointingAt = month.key }
                            else if pointingAt == month.key { pointingAt = nil }
                        }
                        .help(MonthLabel.long(month.key, language: language) + " · "
                              + (month.value.map { Money.text($0, currency) } ?? "—"))
                    }
                }
                .frame(height: 66)
                .onHover { inside in if !inside { pointingAt = nil } }
            }
        }
    }
}
