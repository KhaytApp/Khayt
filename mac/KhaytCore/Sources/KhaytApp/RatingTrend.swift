import SwiftUI
import KhaytCore

/// What customers said, month by month.
///
/// ── THE CAPTION AND THE LINE MUST COVER THE SAME MONTHS ───────────────────
///
/// The other app drew six months of bars under a caption counting every rating
/// the shop had ever collected. A shop with forty happy reviews from last year
/// and two poor ones since read "42 responses · Avg 4.8" above a chart of the
/// two — and believed the 4.8, because the sentence is easier to read than the
/// shape. `lib/rating-trend.js` now returns both figures separately, and this
/// card prints the one that matches what it drew.
///
/// ── WHY MOST MONTHS ARE EMPTY, AND WHY THAT IS DRAWN ──────────────────────
///
/// Ratings arrive one at a time, from the survey the customer page posts back
/// (`POST /api/survey`). A shop gets a handful a month at best, so a gap is the
/// normal case rather than the broken one. An empty month draws a hairline
/// where its bar would stand: six columns still read as six, and "nobody
/// answered in July" stays visibly different from "July was rated zero".
struct RatingTrendCard: View {
    let shop: Shop
    let trend: KhaytEngine.RatingTrend?

    /// Out of five, always. Scaling to the best month would make a shop rated
    /// 3.1, 3.0, 3.2 look like a mountain range — the whole point of a rating
    /// is where it sits on a fixed scale, so the scale is fixed.
    private static let top = 5.0

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.nps_trend"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Spacer(minLength: 8)
                if let trend, trend.responses > 0, let average = trend.average {
                    // "3 responses · Avg 4.7" — the responses IN THE WINDOW.
                    Text("\(trend.responses) \(words.callIt("an.nps_responses")) "
                         + Self.oneDecimal(average))
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(Self.tint(average))
                }
            }

            if let trend, trend.responses > 0 {
                Bars(points: trend.points)
                    .frame(height: 74)
                // ── AND THE RATINGS THIS CHART DOES NOT COVER ─────────────
                //
                // The figure that used to be printed as though it were the
                // one above. Said plainly, and only when the two differ, so a
                // shop can still find its all-time standing without being
                // told it is this half-year's.
                if trend.allTimeResponses > trend.responses {
                    Text(words.callIt("mac.rt_all_time",
                                      ["n": .number(Double(trend.allTimeResponses))]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Three ratings is an anecdote. The rule says when it has
                // enough to be worth reading as a figure; below that the
                // average is still shown, with the caveat attached to it.
                if !trend.enough {
                    Text(words.callIt("mac.rt_thin"))
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // A shop that has never been rated is not a shop with a
                // problem — it is one whose customers have not been asked.
                // So this says how asking happens, not "no data".
                Text(words.callIt("mac.rt_none"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `4.65` → `4.7`. One decimal, because a rating out of five carries no
    /// more than that and `4.6499999` is what a Double will hand you.
    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Only the two ends are coloured. A shop rated 4.1 is doing fine and does
    /// not need telling in green; a shop rated 2.8 does need telling.
    static func tint(_ average: Double) -> Color {
        if average < 3 { return Khayt.late }
        if average >= 4.5 { return Khayt.done }
        return .primary
    }

    private struct Bars: View {
        let points: [KhaytEngine.RatingTrend.Point]

        var body: some View {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(points, id: \.month) { point in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if let average = point.average, point.responses > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(RatingTrendCard.tint(average) == .primary
                                      ? Khayt.brand : RatingTrendCard.tint(average))
                                .frame(height: max(0.04, average / RatingTrendCard.top) * 46)
                        } else {
                            Rectangle().fill(Khayt.hairline).frame(height: 1)
                        }
                        Text(MonthLabel.short(point.month))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 3)
                }
            }
        }
    }
}
