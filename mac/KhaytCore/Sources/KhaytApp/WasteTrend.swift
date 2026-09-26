import SwiftUI
import KhaytCore

/// What the shop threw away, month by month, and why.
///
/// Six columns of grams, each stacked by failure type — the heaviest three
/// in the window by name, and the rest as "other". The rule is
/// `lib/waste-trend.js`, drawn by both apps; what this one adds is the key
/// under the columns, so a reader can tell the stripe that keeps coming back.
/// A month with nothing thrown away is a zero, drawn as a baseline, because
/// zero waste is a real and good answer.
///
/// ── A STRIPE THAT KEEPS COMING BACK IS A MONTH-BY-MONTH QUESTION ──────────
///
/// The key is the whole point of this card and it carried the WINDOW's totals,
/// so "bed adhesion, 340g" was six months added together. A reader who saw one
/// stripe growing down the chart could not find out by how much without
/// counting pixels. The key is a readout now: pointing at a column puts that
/// month's grams beside every type, so the comparison the card is for can
/// actually be made.
struct WasteTrendCard: View {
    let shop: Shop
    let trend: KhaytEngine.WasteTrend?

    /// `YYYY-MM`, while a pointer is on it.
    @State private var pointingAt: String?

    /// Three tints and grey for the rest. The palette's own attention colours
    /// for the three: waste is the one chart where every stripe is bad news.
    static let tints: [Color] = [Khayt.late, Khayt.attention, Khayt.brand]

    static func tint(_ index: Int, of types: [String]) -> Color {
        types[index] == "other" ? Color.secondary.opacity(0.4) : tints[index % tints.count]
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            let month = pointingAt.flatMap { key in trend?.months.first { $0.key == key } }
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.waste_trend"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Spacer()
                if let trend, trend.total > 0 {
                    Text(Money.grams(month?.total ?? trend.total) + " " + words.callIt("common.grams"))
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            if let trend, trend.total > 0 {
                Columns(trend: trend, language: words.language,
                        gram: words.callIt("common.grams"), pointingAt: $pointingAt)
                    .frame(height: 84)
                // WHAT THE FIGURES BELOW ARE ABOUT. The card never said which
                // months it covered, so the total in the corner was six months
                // of a span the reader had to work out from the axis.
                Text(MonthLabel.span(trend.months.map(\.key), pointingAt: pointingAt,
                                     language: words.language))
                    .font(.caption)
                    .foregroundStyle(pointingAt == nil ? AnyShapeStyle(.secondary)
                                                       : AnyShapeStyle(.primary))
                    .lineLimit(1).minimumScaleFactor(0.75)
                // The key, one type per line in stacking order, with its grams.
                // A line each rather than a row of chips: this pane is 240 to
                // 360 points wide and "Bed Adhesion" beside "Operator Error"
                // in chips broke mid-word.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(trend.types.enumerated()), id: \.offset) { i, type in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Self.tint(i, of: trend.types))
                                .frame(width: 9, height: 9)
                            Text(words.callIt("waste.ft." + type)).font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            // A type that cost this month nothing says so, and
                            // "0 g" is the true answer rather than an absence:
                            // a stripe missing from one column is exactly the
                            // fact a reader is hunting for.
                            Text(Money.grams((month?.byType ?? trend.byType)[type] ?? 0)
                                 + " " + words.callIt("common.grams"))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
            } else {
                Text(words.callIt("an.no_data"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private struct Columns: View {
        let trend: KhaytEngine.WasteTrend
        let language: String
        /// The gram in the shop's language — never a Latin "g" on an Arabic card.
        let gram: String
        @Binding var pointingAt: String?
        @Environment(\.accessibilityReduceMotion) private var reduced

        var body: some View {
            let peak = max(trend.months.map(\.total).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(trend.months) { month in
                    let here = pointingAt == month.key
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if month.total > 0 {
                            Text(Money.grams(month.total))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                            // Stacked heaviest type at the bottom, so the
                            // stripe that matters most sits on the baseline.
                            VStack(spacing: 1) {
                                ForEach(Array(trend.types.enumerated().reversed()), id: \.offset) { i, type in
                                    if let grams = month.byType[type], grams > 0 {
                                        Rectangle()
                                            .fill(WasteTrendCard.tint(i, of: trend.types))
                                            .frame(height: max(2, grams / peak * 52))
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            // The stack, not each stripe: the column is one
                            // month's waste and it grows as one thing, so the
                            // stripes keep their proportions the whole way up.
                            .growsToItsReading(month.total / peak)
                        } else {
                            Rectangle().fill(Khayt.hairline).frame(height: 1)
                        }
                        Text(MonthLabel.short(month.key))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(here ? AnyShapeStyle(.primary)
                                                  : AnyShapeStyle(.secondary))
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .background(here ? Khayt.recessed : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .animation(Motion.of(Motion.hover, unless: reduced), value: here)
                    // A month that threw nothing away draws a one-point
                    // hairline, and it is one of the months most worth asking
                    // about — so the whole column answers the pointer.
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { pointingAt = month.key }
                        else if pointingAt == month.key { pointingAt = nil }
                    }
                    .help(MonthLabel.long(month.key, language: language)
                          + " · " + Money.grams(month.total) + " " + gram)
                }
            }
            .onHover { inside in if !inside { pointingAt = nil } }
        }
    }
}
