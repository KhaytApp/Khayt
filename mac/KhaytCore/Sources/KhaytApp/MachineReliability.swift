import SwiftUI
import KhaytCore

/// Which machine is costing the shop, and what it keeps doing wrong.
///
/// NEITHER APP HAS HAD THIS. Waste is charted by failure type over time —
/// which tells a shop it has a warping problem — and never by machine, which is
/// what tells it WHICH printer has one. "Replace the old one" is a decision
/// worth thousands and there has been nothing to make it on.
///
/// ── THE RATE, NOT THE GRAMS ───────────────────────────────────────────────
///
/// A printer that ran nine hundred hours and scrapped two kilos is doing better
/// than one that ran ninety and scrapped one. Ranking by grams always names the
/// busiest machine, which is the wrong printer to sell — so this is ranked by
/// scrap against what each machine actually put out, with the grams beside it
/// rather than instead of it.
struct MachineReliabilityCard: View {
    let shop: Shop
    let report: KhaytEngine.MachineReliability?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("mac.mr_title"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.cyan)
                Spacer()
                if let rate = report?.totals.scrapRate {
                    Text(words.callIt("mac.mr_rate",
                                      ["pct": .string(Money.quantity(rate * 100, decimals: 1))]))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            if let report, !report.rows.isEmpty {
                // The machine to look at, named, with the fault that would fix
                // it. A shop scanning a table finds the number; it does not
                // find the sentence.
                if let worst = report.totals.worst, let fault = worst.worstFault {
                    Text(words.callIt("mac.mr_worst", [
                        "name": .string(worst.name),
                        "fault": .string(Self.fault(fault.type, words)),
                    ]))
                    .font(.callout)
                    .foregroundStyle((worst.scrapRate ?? 0) >= 0.05 ? Khayt.attention : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(Array(report.rows.enumerated()), id: \.element.id) { index, row in
                        Row(shop: shop, row: row)
                        if index < report.rows.count - 1 { Divider().opacity(0.5) }
                    }
                }
            } else {
                EmptyHere(title: words.callIt("an.no_data"), mark: .waste)
            }
        }
    }

    /// The shop's word for a failure category, and the stored value where the
    /// catalogue has none — a row reading `waste.ft.delamination` is worse than
    /// one reading the raw word.
    static func fault(_ type: String, _ words: Words) -> String {
        let key = "waste.ft." + type
        let said = words.callIt(key)
        return said == key ? type.replacingOccurrences(of: "_", with: " ") : said
    }

    private struct Row: View {
        let shop: Shop
        let row: KhaytEngine.MachineReliability.Row

        var body: some View {
            let words = shop.words
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Swatch(rgb: Swatch.rgb(fromHex: row.color), size: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.callout).lineLimit(1)
                    Text(under(words)).font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(rate(words)).font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(tint ?? .primary)
                    // Against the same scale for every row, so a bad machine
                    // looks bad next to a good one rather than each row being
                    // drawn to its own maximum.
                    Capsule()
                        .fill((tint ?? Khayt.cyan).opacity(0.55))
                        .frame(width: max(2, min(1, (row.scrapRate ?? 0) / 0.2) * 70), height: 3)
                }
            }
            .padding(.vertical, 6)
        }

        /// Amber at a twentieth of everything it prints. Not a gradient: a shop
        /// acts on this at one point, and a continuous colour has none.
        private var tint: Color? {
            guard let rate = row.scrapRate else { return nil }
            return rate >= 0.05 ? Khayt.attention : nil
        }

        private func rate(_ words: Words) -> String {
            guard let rate = row.scrapRate else { return "—" }
            return Money.quantity(rate * 100, decimals: 1) + "%"
        }

        private func under(_ words: Words) -> String {
            guard row.scraps > 0 else { return words.callIt("mac.mr_clean") }
            // With the unit. `Money.grams` is deliberately unitless — callers
            // add it — and without it the line reads "400 of 17,773.6", which
            // is two numbers of nothing.
            let g = words.callIt("common.grams")
            var line = words.callIt("mac.mr_of", [
                "scrap": .string(Money.grams(row.scrapGrams)),
                "out": .string(Money.grams(row.grams + row.scrapGrams) + " " + g),
            ])
            if let fault = row.worstFault {
                line += " · " + MachineReliabilityCard.fault(fault.type, words)
            }
            return line
        }
    }
}
