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
struct WasteTrendCard: View {
    let shop: Shop
    let trend: KhaytEngine.WasteTrend?

    /// Three tints and grey for the rest. The palette's own attention colours
    /// for the three: waste is the one chart where every stripe is bad news.
    static let tints: [Color] = [Khayt.late, Khayt.attention, Khayt.brand]

    static func tint(_ index: Int, of types: [String]) -> Color {
        types[index] == "other" ? Color.secondary.opacity(0.4) : tints[index % tints.count]
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.waste_trend"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Spacer()
                if let trend, trend.total > 0 {
                    Text(Money.grams(trend.total) + " " + words.callIt("mac.grams"))
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }
            if let trend, trend.total > 0 {
                Columns(trend: trend).frame(height: 84)
                // The key, one type per line in stacking order, with its grams.
                // A line each rather than a row of chips: this pane is 240 to
                // 360 points wide and "Bed Adhesion" beside "Operator Error"
                // in chips broke mid-word.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(trend.types.enumerated()), id: \.offset) { i, type in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Self.tint(i, of: trend.types))
                                .frame(width: 9, height: 9)
                            Text(words.callIt("waste.ft." + type)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Money.grams(trend.byType[type] ?? 0) + " " + words.callIt("mac.grams"))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
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

        var body: some View {
            let peak = max(trend.months.map(\.total).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(trend.months) { month in
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
                        } else {
                            Rectangle().fill(Khayt.hairline).frame(height: 1)
                        }
                        Text(Self.shortMonth(month.key))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                }
            }
        }

        static func shortMonth(_ key: String) -> String {
            let parts = key.split(separator: "-")
            guard parts.count == 2 else { return key }
            return "\(parts[1])/\(parts[0].suffix(2))"
        }
    }
}
