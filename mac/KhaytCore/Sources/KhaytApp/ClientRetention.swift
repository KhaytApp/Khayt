import SwiftUI
import KhaytCore

/// Do customers come back, and how soon — `lib/client-retention.js`.
///
/// Beside the customer mix and where customers came from: those say whether a
/// shop is FINDING people, this says whether it keeps them.
///
/// Each rate carries the count it is a share OF, because the counts differ by
/// window: only a customer whose first order is at least 90 days old can be
/// asked whether they came back within 90. A shop that took ten new customers
/// last month has a 30-day figure about them and no 90-day figure yet, and
/// the card says "too soon" rather than reading those ten as lost.
struct ClientRetentionCard: View {
    let shop: Shop
    let report: KhaytEngine.ClientRetention?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 12) {
            Text(words.callIt("an.retention_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)

            if let report, report.enough {
                HStack(alignment: .top, spacing: 22) {
                    ForEach(report.windows, id: \.days) { window in
                        Rate(shop: shop, window: window)
                    }
                    Stat(value: report.avgDaysToReturn.map { Money.quantity($0, decimals: 1) } ?? "—",
                         label: words.callIt("an.retention_avg_days"), note: nil)
                    Spacer(minLength: 0)
                }

                if !report.top.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(words.callIt("an.top_returning"))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(report.top.enumerated()), id: \.element.id) { index, regular in
                            HStack(spacing: 8) {
                                Text("\(index + 1).")
                                    .monospacedDigit().foregroundStyle(.tertiary)
                                Text(regular.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(words.callIt("an.retention_orders_n",
                                                  ["n": .number(Double(regular.orders))]))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            } else {
                Text(words.callIt("an.retention_no_data"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct Rate: View {
        let shop: Shop
        let window: KhaytEngine.ClientRetention.Window

        var body: some View {
            let words = shop.words
            // Spelled out rather than assembled, so every key on this card is
            // one the translation guards can find.
            let key = window.days == 30 ? "an.retention_30"
                : window.days == 60 ? "an.retention_60" : "an.retention_90"
            if let rate = window.rate {
                let pct = rate * 100
                Stat(value: Money.quantity(pct, decimals: pct == pct.rounded() ? 0 : 1) + "%",
                     label: words.callIt(key),
                     note: words.callIt("an.retention_of_n",
                                        ["returned": .number(Double(window.returned)),
                                         "eligible": .number(Double(window.eligible))]))
            } else {
                Stat(value: "—", label: words.callIt(key),
                     note: words.callIt("an.retention_too_soon"))
            }
        }
    }

    private struct Stat: View {
        let value: String
        let label: String
        let note: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.medium)).monospacedDigit()
                Text(label)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        }
    }
}
