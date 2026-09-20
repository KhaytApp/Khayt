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
    @Bindable var shop: Shop
    let spool: Spool

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
                    ForEach(uses) { use in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(use.date.isEmpty ? "—" : use.date)
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit().frame(width: 84, alignment: .leading)
                            // The job as it was NAMED at the time, falling back
                            // to its id. A spool spent on a job since deleted
                            // still spent it, and an empty cell would read as
                            // though the plastic went nowhere.
                            Text(use.project.isEmpty ? use.orderId : use.project)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Quantity.ordered(use.weightUsed, unit: spool.unit ?? "",
                                                  words: shop.words))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        if use.id != uses.last?.id { Divider() }
                    }
                }
                Divider()
                HStack {
                    Text(shop.words.callIt("mac.spool_history_total")).foregroundStyle(.secondary)
                    Spacer()
                    Text(Quantity.ordered(spool.totalUsed, unit: spool.unit ?? "",
                                          words: shop.words))
                        .monospacedDigit().fontWeight(.semibold)
                }
                .padding(.top, 4)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.spoolHistoryFor = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
