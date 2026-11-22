import SwiftUI
import KhaytCore

/// Where a spool actually went.
///
/// ── WRITTEN BY BOTH APPS, SHOWN BY ONE ────────────────────────────────────
///
/// Every deduction appends to `usageHistory` — the other app has drawn it
/// since it was added and this one never has, so a shop working here held the
/// record and could not read it.
///
/// It is the answer to "what happened to that kilo", which is the question a
/// shelf count raises every time it disagrees with the book. A total at the
/// bottom, because the arithmetic somebody would otherwise do on paper is the
/// whole reason to open this.
struct SpoolHistorySheet: View {
    /// What the rows on screen that are USES add up to — a receipt is shown
    /// (it is where the plastic came from) but is not spending, and adding its
    /// negative grams in read 1000 g received and 300 g used as "−700 g".
    static func shownTotal(_ spool: Spool, places: Int) -> Double {
        (spool.usageHistory ?? []).reduce(0) {
            $1.isReceipt ? $0 : $0 + $1.weightUsed.rounded(toPlaces: places)
        }
    }

    @Bindable var shop: Shop
    let spool: Spool
    /// What the copy-as-CSV button last said.
    @State private var copied: String?

    /// This spool's lot, trimmed; empty when it has none.
    private var lot: String { (spool.lot ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private var uses: [Spool.Use] {
        // Newest first. The book appends, so its own order is oldest-first and
        // the entry a shop is looking for is almost always the last one.
        (spool.usageHistory ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        SheetFrame(width: 460) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.spool_history")).font(.headline)
                Text(spool.label(shop.words)).font(.callout)
                    .foregroundStyle(.secondary).lineLimit(1)
            }

            if uses.isEmpty {
                Text(shop.words.callIt("mac.spool_history_empty"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(uses.enumerated()), id: \.offset) { index, use in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(use.date.isEmpty ? "—" : use.date)
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit().frame(width: 84, alignment: .leading)
                            // The job as it was NAMED at the time, falling back
                            // to its id. A spool spent on a job since deleted
                            // still spent it, and an empty cell would read as
                            // though the plastic went nowhere.
                            VStack(alignment: .leading, spacing: 1) {
                                Text(use.project.isEmpty ? use.orderId : use.project)
                                    .lineLimit(1)
                                // The lot stamped on the row when it was drawn,
                                // or the spool's own, marked as presumed.
                                if let shown = use.lot ?? (lot.isEmpty ? nil : lot) {
                                    Text(shop.words.callIt("mac.lot_label", ["lot": .string(shown)])
                                         + (use.lot == nil ? " " + shop.words.callIt("mac.lot_inferred") : ""))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(Quantity.say(use.weightUsed, shop.unit(of: spool), shop.words))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        if index < uses.count - 1 { Divider() }
                    }
                }
                Divider()
                HStack {
                    Text(shop.words.callIt("mac.spool_history_total")).foregroundStyle(.secondary)
                    Spacer()
                    // The rows as SHOWN, added up: each row is rounded to the
                    // unit's places, and a total of the unrounded draws read
                    // 376 g under 298 g and 79 g (alpha.80 review).
                    Text(Quantity.say(Self.shownTotal(spool, places: shop.unit(of: spool)?.decimals ?? 0),
                                      shop.unit(of: spool), shop.words))
                        .monospacedDigit().fontWeight(.semibold)
                }
                .padding(.top, 4)
            }
        } footer: {
            HStack {
                // A RECALL: every job, across every spool, that drew from this
                // spool's lot — `lib/lot-trace.js`, as CSV on the clipboard.
                if !lot.isEmpty {
                    Button(shop.words.callIt("mac.lot_copy_csv", ["lot": .string(lot)])) {
                        Task { copied = await shop.copyLotRecall(lot) }
                    }
                    .buttonStyle(.link)
                    if let copied {
                        Text(copied).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.spoolHistoryFor = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
