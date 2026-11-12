import SwiftUI
import KhaytCore

/// Every rating the shop has collected: the average, the NPS and how the
/// stars fall — the other app's "Customer Satisfaction (NPS)" card, from the
/// same rule (`lib/rating-trend.js summary`, ported in `KhaytCore.RatingTrend`).
///
/// Under the trend, not instead of it. The trend says where the last six
/// months sit; this says what the shop's whole record is and what it is made
/// of, which a single average hides — a 4.0 from all fours and a 4.0 from
/// fives and ones are not the same shop.
///
/// NPS on a five-star scale is an adaptation (five a promoter, four passive,
/// three or fewer a detractor), and the card says so rather than letting the
/// figure pass for the 0–10 kind.
struct SurveySummaryCard: View {
    let shop: Shop
    let summary: KhaytCore.RatingTrend.Summary

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("an.nps_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(Words.spaced(0.6))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                figure(summary.average.map(RatingTrendCard.oneDecimal) ?? "—", "mac.sv_avg",
                       tint: summary.average.map(RatingTrendCard.tint) ?? .primary)
                figure(summary.nps.map { ($0 > 0 ? "+" : "") + words.numeral($0) } ?? "—", "mac.sv_nps",
                       tint: Self.npsTint(summary.nps))
                figure(words.numeral(summary.responses), "mac.sv_responses", tint: .primary)
            }
            VStack(spacing: 4) {
                ForEach(summary.spread) { bar in
                    HStack(spacing: 8) {
                        Text(verbatim: words.numeral(bar.stars) + "★")
                            .font(.caption).monospacedDigit()
                            .frame(width: 26, alignment: .trailing)
                        GeometryReader { box in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Khayt.hairline)
                                Capsule().fill(Khayt.brand)
                                    .frame(width: box.size.width * Double(bar.pct) / 100)
                                    .growsToItsReading(Double(bar.pct) / 100, from: .leading)
                            }
                        }
                        .frame(height: 8)
                        Text(verbatim: words.numeral(bar.pct) + "%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(verbatim: "(" + words.numeral(bar.count) + ")")
                            .font(.caption).monospacedDigit().foregroundStyle(Khayt.faint)
                            .frame(width: 36, alignment: .leading)
                    }
                }
            }
            Text(words.callIt("mac.sv_nps_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func figure(_ value: String, _ key: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(tint)
            Text(shop.words.callIt(key)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The other app's three colours: 50 and over is good, below zero is not.
    static func npsTint(_ nps: Int?) -> Color {
        guard let nps else { return .primary }
        if nps >= 50 { return Khayt.done }
        if nps < 0 { return Khayt.late }
        return .primary
    }
}
