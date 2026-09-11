import SwiftUI
import KhaytCore

/// Can the shop take this job, and when would it start?
///
/// Agreed, unfinished work against the hours each machine is actually run for.
///
/// ── THE ANSWER IS A DATE, NOT A PERCENTAGE ────────────────────────────────
///
/// "78% booked" is a fact a shop has to convert before it can use it. "Clear in
/// 3 days" is the thing it was going to work out anyway, and it is what goes on
/// the phone to the customer asking when their part will be ready. So the days
/// are the figure and the bar is the context.
///
/// ── AND OVERBOOKED IS DRAWN, NOT CLAMPED ──────────────────────────────────
///
/// The other app computed `Math.min(100, pct)`, so a machine three weeks behind
/// drew the same full bar as one with nothing waiting. Here the bar fills and
/// the overflow is drawn past its end in the warning colour — being over is the
/// one state on this card that has to be visible from across the workshop.
struct CapacityCard: View {
    let shop: Shop
    let report: KhaytEngine.Capacity?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("dash.capacity_title"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.cyan)
                Spacer()
                if let pct = report?.totals.loadPct {
                    Text(words.callIt("dash.capacity_booked", ["pct": .number(pct.rounded())]))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            if let report, !report.rows.isEmpty {
                if report.totals.noTargets {
                    // The shop has work and has never said how long a day is.
                    // Nothing can be a percentage of that, so it says which
                    // field to fill in rather than drawing an empty panel.
                    Text(words.callIt("dash.capacity_no_targets"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 9) {
                    ForEach(report.rows) { row in
                        Row(shop: shop, row: row)
                    }
                }
                if report.totals.untargeted > 0, !report.totals.noTargets {
                    Text(words.callIt("mac.cap_untargeted",
                                      ["h": .number(report.totals.untargeted.rounded())]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(words.callIt("dash.capacity_no_targets"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct Row: View {
        let shop: Shop
        let row: KhaytEngine.Capacity.Row

        var body: some View {
            let words = shop.words
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The machine's own colour, so a row here and the same
                    // machine elsewhere are recognisably one thing.
                    Swatch(rgb: Swatch.rgb(fromHex: row.color), size: 7)
                    Text(row.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(said(words)).font(.caption).monospacedDigit()
                        .foregroundStyle(tint ?? .secondary)
                }
                Meter(fraction: (row.loadPct ?? 0) / 100, over: row.overbooked)
                    .frame(height: 6)
            }
        }

        /// Amber at three-quarters, red once it is over. Not a gradient: a shop
        /// acts on this at two points and a continuous colour has none.
        private var tint: Color? {
            guard let load = row.loadPct else { return nil }
            if row.overbooked { return Khayt.late }
            return load >= 75 ? Khayt.attention : nil
        }

        private func said(_ words: Words) -> String {
            guard let days = row.daysToClear else {
                // No target, so no date. The hours are still true.
                return Money.quantity(row.bookedHours, decimals: 1) + " h"
            }
            if row.overbooked {
                let over = days - (row.availableHours / max(row.hoursPerDay, 1))
                return words.callIt("mac.cap_over", ["n": .number(over.rounded())])
            }
            if days < 1 { return words.callIt("mac.cap_clear_soon") }
            return words.callIt("mac.cap_clear_days", ["n": .number(days.rounded())])
        }

        /// Fills to the end, then keeps going past it in the warning colour.
        private struct Meter: View {
            let fraction: Double
            let over: Bool

            var body: some View {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Khayt.recessed)
                        Capsule()
                            .fill(over ? Khayt.late : Khayt.cyan)
                            .frame(width: max(0, min(1, fraction)) * geometry.size.width)
                        if over {
                            // The overflow, striped against the end of the bar
                            // so being 300% booked does not look like being
                            // 100% booked. Capped at a second bar-width: past
                            // that the number is what carries it.
                            Capsule()
                                .fill(Khayt.late.opacity(0.35))
                                .frame(width: min(1, fraction - 1) * geometry.size.width)
                                .offset(x: 0)
                        }
                    }
                }
            }
        }
    }
}
