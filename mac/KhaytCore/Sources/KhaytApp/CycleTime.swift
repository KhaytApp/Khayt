import SwiftUI
import KhaytCore

/// How long a job takes, from the day it was taken to the day it was done.
///
/// Six months of the average on top, and under it the products that take
/// longest — average, fastest, slowest — because "we are slow" is not a
/// finding and "the vases take eleven days and everything else takes three"
/// is. The rule is `lib/cycle-time.js`; the other app draws the same two
/// from it. A month that finished nothing is a gap, not a zero.
struct CycleTimeCard: View {
    let shop: Shop
    let cycle: KhaytEngine.CycleTime?
    let lead: KhaytEngine.LeadTime?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.cycle_time"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Spacer()
                if let avg = cycle?.avgDays {
                    Text(Self.days(avg) + " " + words.callIt("an.days"))
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }

            if let cycle, cycle.jobs > 0 {
                Months(months: cycle.months)
                    .frame(height: 74)
            } else {
                Text(words.callIt("an.no_data"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            // Three is the other app's threshold too: two jobs are two
            // anecdotes, and a table of them ranks nothing.
            if let lead, lead.jobs >= 3, !lead.rows.isEmpty {
                Divider().padding(.vertical, 2)
                Text(words.callIt("an.lead_time"))
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text(words.callIt("ord.project")).gridColumnAlignment(.leading)
                        Text(words.callIt("an.lead_time_avg"))
                        Text(words.callIt("an.lead_time_fastest"))
                        Text(words.callIt("an.lead_time_slowest"))
                        Text("#")
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                    ForEach(lead.rows) { row in
                        GridRow {
                            // The catalogue's name for the product when the
                            // job named one; the job's own words otherwise.
                            Text(productName(row.productId) ?? row.name)
                                .lineLimit(1).gridColumnAlignment(.leading)
                            Text(Self.days(row.avgDays)).fontWeight(.medium)
                            Text(Self.days(row.fastest)).foregroundStyle(.secondary)
                            Text(Self.days(row.slowest))
                                .foregroundStyle(row.slowest > row.avgDays * 2 ? Khayt.attention : .secondary)
                            Text("\(row.jobs)").foregroundStyle(.tertiary)
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
            }
        }
    }

    private func productName(_ id: String?) -> String? {
        guard let id else { return nil }
        let name = shop.catalogueRows.first { $0.id == id }?.name ?? ""
        return name.isEmpty ? nil : name
    }

    /// `3.5`, `11` — a day and a half is worth saying, a tenth is not.
    static func days(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private struct Months: View {
        let months: [KhaytEngine.CycleTime.Month]

        var body: some View {
            let peak = max(months.compactMap(\.avgDays).max() ?? 0, 0.1)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(months) { month in
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        if let avg = month.avgDays {
                            Text(CycleTimeCard.days(avg))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Khayt.brand)
                                .frame(height: max(0.05, min(1, avg / peak)) * 40)
                        } else {
                            Rectangle().fill(Khayt.hairline).frame(height: 1)
                        }
                        Text(MonthLabel.short(month.key))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                }
            }
        }
    }
}
