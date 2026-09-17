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
                    colour: Khayt.brand)
                Row(title: words.callIt("an.cost_per_gram"),
                    figure: trends.costPerGram.map { Money.text($0, shop.currency) },
                    values: trends.months.map { ($0.key, $0.costPerGram) },
                    colour: Khayt.late)
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

        var body: some View {
            let peak = max(values.compactMap(\.value).max() ?? 0, 0.0001)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if let figure {
                        Text(figure).font(.callout.weight(.medium)).monospacedDigit()
                    }
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(values, id: \.key) { month in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            if let value = month.value {
                                // A reading too small to draw still gets a
                                // sliver: a month that earned 3 an hour and a
                                // month with no reading must not look the same.
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(colour)
                                    .frame(height: max(0.04, min(1, value / peak)) * 48)
                            } else {
                                // The gap. A hairline where the bar would
                                // stand, so twelve columns still read as twelve.
                                Rectangle().fill(Khayt.hairline).frame(height: 1)
                            }
                            Text(MonthLabel.short(month.key))
                                .font(.caption2).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 3)
                    }
                }
                .frame(height: 66)
            }
        }
    }
}
