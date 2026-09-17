import SwiftUI
import KhaytCore

/// Where the shop's customers came from, and what they were worth.
///
/// ── THE SOURCE THE CHART HAD NEVER HEARD OF ───────────────────────────────
///
/// The other app's chart iterated the six sources its customer form offers.
/// The intake form is a seventh writer: importing an order request stamps
/// `source: 'online'`, so every customer who arrived through the shop's own
/// intake page — and all of their revenue — was missing from the chart that
/// claims to say where customers come from. `lib/client-sources.js` owns the
/// list now, `online` is in it, and anything unrecognised is filed under Other
/// rather than dropped: a source that shows nothing looks like a source that
/// brought nothing, and a shop spends money on that reading.
///
/// ── COUNT AND MONEY ARE DIFFERENT ANSWERS ─────────────────────────────────
///
/// Both are drawn, because they routinely disagree and the disagreement is the
/// finding: a source that brings many small jobs and one that brings a few
/// large ones look identical on a chart of customers and nothing alike on a
/// chart of revenue. The bar is the count; the money is printed beside it.
struct ClientSourcesCard: View {
    let shop: Shop
    let report: KhaytEngine.ClientSources?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("an.source_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)

            if let report, !report.rows.isEmpty {
                // ── WHEN THE ONLY ANSWER IS "OTHER" ───────────────────────
                //
                // A shop that has never filled the field in gets one row
                // reading "Other — 31 customers", which is a true chart and a
                // useless one. It is told what to do about it instead, because
                // the fix is one field on the customer sheet and the shop has
                // no reason to know that.
                if report.rows.count == 1, report.rows[0].source == "other" {
                    Text(words.callIt("mac.cs_unrecorded"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let peak = max(report.rows.map(\.count).max() ?? 1, 1)
                    VStack(spacing: 6) {
                        ForEach(report.rows, id: \.source) { row in
                            Row(shop: shop, row: row, peak: peak)
                        }
                    }
                }
            } else {
                Text(words.callIt("an.source_empty"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private struct Row: View {
        let shop: Shop
        let row: KhaytEngine.ClientSourceRow
        let peak: Int

        var body: some View {
            HStack(spacing: 8) {
                Text(shop.words.callIt("cl.source_" + row.source))
                    .font(.callout).lineLimit(1)
                    .frame(width: 92, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // A sliver for a source with one customer, so it stays
                        // visibly different from one with none — which is not
                        // drawn at all.
                        Capsule()
                            .fill(Khayt.brand.opacity(0.85))
                            .frame(width: max(3, geo.size.width
                                               * CGFloat(row.count) / CGFloat(peak)))
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 14)
                Text("\(row.count)")
                    .font(.callout.weight(.medium)).monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
                // The money, which is the other answer and often a different
                // order from the bars above it.
                Text(Money.short(row.revenue, shop.currency))
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }
}
