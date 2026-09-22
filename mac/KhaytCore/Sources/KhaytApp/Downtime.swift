import SwiftUI
import KhaytCore

/// How long each machine was out of action.
///
/// ── BESIDE WHAT SERVICING COST, BECAUSE THEY ARE THE SAME QUESTION ────────
///
/// A repair costs money and it costs time, and the second is usually the
/// larger number. A printer that cost 200 in parts and stood idle for three
/// days did not cost the shop 200. So this sits under the maintenance figures
/// on the same screen: what stopped this machine earning, both ways.
///
/// ── THE UNION, NOT THE SUM ────────────────────────────────────────────────
///
/// A shop books a printer out for a belt change on Monday to Wednesday, then
/// adds "waiting for the part" for Tuesday to Thursday. Both are true, both
/// get recorded, and the machine is unavailable for 72 hours — not 96. Three
/// separate readers used to add the windows up; `lib/downtime.js` merges them
/// first, and this app has relied on that for scheduling without ever drawing
/// it.
///
/// ── A ROW PER MACHINE, NOT A STACK ────────────────────────────────────────
///
/// The other app draws one stacked bar per month with a colour per machine,
/// which needs five arbitrary colours and a legend to read at all. Colour means
/// something in this app, and a machine is not a meaning. The question here is
/// "which of my printers is not earning", so the machines are the rows, ranked,
/// and the months are read across.
struct DowntimeCard: View {
    let shop: Shop
    let rows: [KhaytEngine.DowntimeRow]
    /// The month labels the columns stand for, oldest first.
    let months: [String]

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.downtime"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Spacer(minLength: 8)
                if !rows.isEmpty {
                    Text(Self.hours(rows.reduce(0) { $0 + $1.total }, words))
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }

            if rows.isEmpty {
                // Not "no data". A fleet that was never out of action is the
                // good outcome, and saying so is different from admitting the
                // chart could not find anything.
                Text(words.callIt("mac.dt_none"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The column headings, read across.
                HStack(spacing: 8) {
                    Spacer().frame(width: 130)
                    ForEach(months, id: \.self) { month in
                        Text(MonthLabel.short(month))
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                    Spacer().frame(width: 62)
                }
                VStack(spacing: 6) {
                    ForEach(rows, id: \.machineId) { row in
                        Row(shop: shop, row: row, peak: rows.first?.total ?? 1)
                    }
                }
            }
        }
    }

    /// The same spelling the machine P&L above uses for its hours — one screen
    /// writing an hour two ways is a screen a reader has to translate.
    static func hours(_ value: Double, _ words: Words) -> String {
        Money.quantity(value, decimals: 1) + words.callIt("common.hours_short")
    }

    private struct Row: View {
        let shop: Shop
        let row: KhaytEngine.DowntimeRow
        let peak: Double

        var body: some View {
            HStack(spacing: 8) {
                Text(row.name).font(.callout).lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                ForEach(Array(row.hours.enumerated()), id: \.offset) { _, value in
                    // One cell per month. A month this machine ran through
                    // draws a dash, not a zero: "nothing went wrong" is not a
                    // measurement of nothing.
                    Text(value > 0 ? DowntimeCard.hours(value, shop.words) : "—")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(value > 0 ? AnyShapeStyle(.primary)
                                                   : AnyShapeStyle(.tertiary))
                        .frame(maxWidth: .infinity)
                }
                // The bar is the machine's TOTAL against the worst machine, so
                // the ranking is readable at a glance without comparing three
                // columns of figures.
                GeometryReader { geo in
                    Capsule()
                        .fill(Khayt.late.opacity(0.7))
                        .frame(width: max(3, geo.size.width * CGFloat(row.total / max(peak, 0.0001))))
                        .growsToItsReading(row.total / max(peak, 0.0001), from: .leading)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(width: 62, height: 12)
            }
        }
    }
}
