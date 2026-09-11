import SwiftUI
import KhaytCore

/// When the shop actually finishes work.
///
/// ── THE FINDING FIRST, THE GRID SECOND ────────────────────────────────────
///
/// The other app draws a 168-cell heatmap and stops. That is the shape of the
/// data, not a finding — and at the volume a small shop generates, a grid of
/// mostly-empty cells looks exactly like a pattern. So the two sentences a shop
/// can act on are on top: when it is busiest, and how much of the week's work
/// is finishing on a day it is CLOSED.
///
/// That second one is printers running unattended over a weekend, which is fine
/// and worth knowing, or somebody coming in on their day off, which is worth
/// knowing for a different reason. Neither app has said it.
///
/// And when there is not enough behind the grid to read, it says so rather than
/// drawing noise.
struct ThroughputCard: View {
    let shop: Shop
    let report: KhaytEngine.Throughput?

    /// Sunday first, matching `getDay()`. Short names from the shop's own
    /// calendar rather than a table of nine translations.
    private static func dayName(_ day: Int, _ language: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: language)
        let symbols = calendar.shortWeekdaySymbols
        return day >= 0 && day < symbols.count ? symbols[day] : ""
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("mac.tp_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.cyan)

            if let report, report.totals.jobs > 0 {
                if let day = report.totals.busiestDay, let hour = report.totals.busiestHour {
                    Text(words.callIt("mac.tp_busiest", [
                        "day": .string(Self.dayName(day, shop.words.language)),
                        "hour": .string(Self.oclock(hour)),
                    ]))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let share = report.totals.closedDayShare, share > 0 {
                    Text(words.callIt("mac.tp_closed",
                                      ["pct": .number((share * 100).rounded())]))
                        .font(.callout)
                        .foregroundStyle(share >= 0.25 ? Khayt.attention : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if report.totals.enough {
                    Grid(shop: shop, report: report)
                } else {
                    // Said rather than drawn. A grid of four marks in 168 cells
                    // is not a picture of anything, and a reader will find a
                    // pattern in it regardless.
                    Text(words.callIt("mac.tp_thin",
                                      ["n": .number(Double(report.totals.jobs))]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(words.callIt("an.no_data"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// `16` → `16:00`. Not a localised time: these are column headings on a
    /// narrow grid, and digits read the same in every language this ships in.
    static func oclock(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private struct Grid: View {
        let shop: Shop
        let report: KhaytEngine.Throughput

        var body: some View {
            let peak = max(Double(report.totals.peak), 1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(report.byDay) { day in
                    HStack(spacing: 2) {
                        Text(ThroughputCard.dayName(day.day, shop.words.language))
                            .font(.caption2).monospacedDigit()
                            // A day the shop does not work is dimmed rather
                            // than hidden — work still finishes on it, and that
                            // is the point of the line above.
                            .foregroundStyle(day.open ? .secondary : Khayt.attention)
                            .frame(width: 30, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let count = report.matrix[day.day][hour]
                            RoundedRectangle(cornerRadius: 2)
                                .fill(count == 0
                                      ? Khayt.recessed
                                      : Khayt.cyan.opacity(0.25 + 0.75 * (Double(count) / peak)))
                                .frame(height: 13)
                                .help("\(ThroughputCard.oclock(hour)) · \(count)")
                        }
                    }
                }
                // Only the even hours are labelled: twenty-four numbers under
                // thirteen-point cells is a row of overlapping digits.
                HStack(spacing: 2) {
                    Color.clear.frame(width: 30, height: 1)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour % 6 == 0 ? "\(hour)" : "")
                            .font(.system(size: 8)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
