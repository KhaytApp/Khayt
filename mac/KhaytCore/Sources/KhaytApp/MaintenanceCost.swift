import SwiftUI
import KhaytCore

/// What the shop spent keeping each machine running, this year.
///
/// ── A CHART THAT COULD NEVER HAVE DRAWN ANYTHING ──────────────────────────
///
/// The other app's version read `machine.machMaintLog` — a per-machine
/// property nothing in Khayt has ever written. It was always undefined, always
/// became an empty list, so every machine totalled zero, every machine was
/// filtered out, and the chart printed "No data yet" however many services the
/// shop had logged. The machine screen listed those same services correctly
/// the whole time, from the one flat list they actually live in.
///
/// This app already reads that list — `Shop.maintenanceRows`, for the machine
/// P&L — so the figures were here before the chart was.
///
/// ── BESIDE WHAT THE MACHINE EARNED, NOT ON A PAGE OF ITS OWN ──────────────
///
/// The P&L above already subtracts a machine's maintenance from its profit.
/// This says how much of it there was, which is the question a shop asks next
/// and cannot answer from a single net figure: a printer that earned little
/// because it was idle and one that earned little because it was constantly
/// being repaired are the same row up there and different decisions.
struct MaintenanceCostCard: View {
    let shop: Shop
    let rows: [KhaytEngine.MaintenanceCostRow]
    /// Which year the figures cover, said out loud — the rule buckets by year
    /// and a total with no period on it is a number nobody can check.
    let year: Int

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.maint_cost"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Text(String(year))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if !rows.isEmpty {
                    Text(Money.text(rows.reduce(0) { $0 + $1.total }, shop.currency))
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }

            if rows.isEmpty {
                Text(words.callIt("mac.mc_no_service", ["year": .string(String(year))]))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let peak = max(rows.map(\.total).max() ?? 0, 0.0001)
                VStack(spacing: 6) {
                    ForEach(rows, id: \.machineId) { row in
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Text(row.name).font(.callout).lineLimit(1)
                                // A machine the shop has since sold. The money
                                // still left the shop, so the row stays — but
                                // a reader hunting for that printer in the
                                // fleet list needs telling why it is not there.
                                if row.orphan {
                                    Image(systemName: "questionmark.circle")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                        .help(shop.words.callIt("mac.mc_sold"))
                                }
                            }
                            .frame(width: 130, alignment: .leading)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Khayt.attention.opacity(0.8))
                                    .frame(width: max(3, geo.size.width * CGFloat(row.total / peak)))
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 14)
                            Text(Money.short(row.total, shop.currency))
                                .font(.callout.weight(.medium)).monospacedDigit()
                                .frame(width: 82, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}
