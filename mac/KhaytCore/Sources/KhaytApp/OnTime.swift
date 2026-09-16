import SwiftUI
import KhaytCore

/// Whether the shop keeps its promises.
///
/// Of the finished jobs that had a due date, how many were done by it — and
/// for the ones that were not, by how many days. The rate is the figure a
/// customer would quote back at the shop, so it is the big one; the worst
/// miss and the list under it are what the shop can do something about. The
/// rule is `lib/on-time.js`, drawn by both apps. Nothing promised is no
/// record, and the card says so rather than showing 0% or 100%.
struct OnTimeCard: View {
    let shop: Shop
    let report: KhaytEngine.OnTime?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.sla_title"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Spacer()
                if let rate = report?.rate {
                    // Green is not a colour this palette has; a kept promise
                    // is the ordinary state, and only a broken one is coloured.
                    Text(Money.quantity(rate, decimals: rate == rate.rounded() ? 0 : 1) + "%")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(rate < 70 ? Khayt.late : rate < 90 ? Khayt.attention : .primary)
                }
            }

            if let report, report.promised > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Figure(words.callIt("an.sla_with_due"), "\(report.promised)")
                    Spacer(minLength: 10)
                    Figure(words.callIt("an.sla_on_time"), "\(report.onTime)")
                    Spacer(minLength: 10)
                    Figure(words.callIt("an.sla_late"), "\(report.late)",
                           tint: report.late > 0 ? Khayt.late : nil)
                    Spacer(minLength: 10)
                    Figure(words.callIt("an.sla_avg_delay"),
                           report.avgDelayDays.map { CycleTimeCard.days($0) } ?? "—",
                           alignment: .trailing)
                }
                // The promises missed, worst first — the ones worth a phone call.
                if !report.lateJobs.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(report.lateJobs.prefix(5)) { job in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.project.isEmpty ? job.id : job.project).lineLimit(1)
                                Text(job.dueDate + " → " + job.finishedDay)
                                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 8)
                            Text(words.callIt("mac.days_late", ["n": .number(Double(job.delayDays))]))
                                .font(.callout).monospacedDigit()
                                .foregroundStyle(job.delayDays >= 7 ? Khayt.late : Khayt.attention)
                        }
                        .font(.callout)
                    }
                }
            } else {
                Text(words.callIt("an.sla_no_data"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func Figure(_ label: String, _ value: String, tint: Color? = nil,
                        alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
    }
}
