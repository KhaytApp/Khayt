import SwiftUI
import KhaytCore

/// How many quotes turn into work, and how much of the money does.
///
/// A shop quoting all day and winning a third has a different problem from one
/// winning nearly all of it and not quoting enough — and no other screen in
/// either app answers that.
///
/// ── TWO RATES, BECAUSE THEY DISAGREE ──────────────────────────────────────
///
/// Ten small quotes won and one large one lost is a very different month from
/// the reverse, and a count cannot tell them apart. Both are drawn, side by
/// side: when they are far apart, the gap IS the finding — a shop winning most
/// of its quotes and a minority of its money is losing the jobs that matter.
///
/// ── AND THE PART THAT IS A PHONE CALL ─────────────────────────────────────
///
/// A funnel is a report. An open quote is something to do this afternoon. So
/// what is still waiting, what it is worth, and how long the oldest has sat are
/// stated in words under the chart, rather than being left as a bar to read.
struct QuoteFunnelCard: View {
    let shop: Shop
    let report: KhaytEngine.QuoteFunnel?

    /// The shared catalogue's word for each step, by the module's own key.
    private static let label = [
        "created": "an.funnel_created", "sent": "an.funnel_sent",
        "accepted": "an.funnel_accepted", "converted": "an.funnel_converted",
        "finished": "an.funnel_completed",
    ]

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 12) {
            Text(words.callIt("an.funnel_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.cyan)

            if let report, let byCount = report.totals.winRateByCount {
                HStack(alignment: .top, spacing: 22) {
                    Rate(words.callIt("mac.qf_by_count"), byCount, shop: shop)
                    if let byValue = report.totals.winRateByValue {
                        Rate(words.callIt("mac.qf_by_value"), byValue, shop: shop)
                    }
                    Spacer(minLength: 0)
                }

                Steps(shop: shop, steps: report.steps)

                if let days = report.totals.medianDaysToDecide {
                    Text(words.callIt("mac.qf_decide", ["n": .number(days.rounded())]))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if report.totals.openCount > 0 {
                    Text(words.callIt("mac.qf_open", [
                        "n": .number(Double(report.totals.openCount)),
                        "amount": .string(Money.text(report.totals.openValue, shop.currency)),
                        "days": .number(Double(report.totals.oldestOpenDays ?? 0)),
                    ]))
                    .font(.callout)
                    .foregroundStyle((report.totals.oldestOpenDays ?? 0) > 14
                                     ? Khayt.attention : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // A shop that has never quoted has no rate. Nought would read
                // as "you win nothing", which is a different and untrue claim.
                Text(words.callIt("an.no_data"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func Rate(_ label: String, _ value: Double, shop: Shop) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            BigFigure(value: Money.quantity(value * 100, decimals: 0), unit: "%",
                      tint: nil, size: 22)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The steps, each drawn against the first.
    ///
    /// Against the FIRST rather than against the one above it: a funnel where
    /// every bar is full because each step kept most of the last is a funnel
    /// that shows nothing. The drop from what was quoted to what was finished
    /// is the whole shape.
    private struct Steps: View {
        let shop: Shop
        let steps: [KhaytEngine.QuoteFunnel.Step]

        var body: some View {
            let top = max(Double(steps.first?.count ?? 0), 1)
            VStack(spacing: 5) {
                ForEach(steps) { step in
                    HStack(spacing: 8) {
                        Text(shop.words.callIt(QuoteFunnelCard.label[step.key] ?? step.key))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Khayt.recessed)
                                Capsule().fill(Khayt.cyan.opacity(0.75))
                                    .frame(width: (Double(step.count) / top) * geometry.size.width)
                            }
                        }
                        .frame(height: 12)
                        Text("\(step.count)")
                            .font(.caption).monospacedDigit()
                            .frame(width: 26, alignment: .trailing)
                    }
                }
            }
        }
    }
}
