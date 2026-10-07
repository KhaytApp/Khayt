import SwiftUI
import KhaytCore

/// What each of the shop's sites earned and kept, over the chosen period.
///
/// Every figure is `lib/location-pl.js`'s, which is the shop's own P&L
/// (`lib/pnl-report.js`) run once per site — so the sites add up to the shop
/// and cannot disagree with the Profit page about the same jobs. Fixed
/// overhead belongs to the whole shop and is in no row, which the card says.
///
/// On the Machines page because a site is where machines stand: "which branch
/// pays" is the question right after "which printer pays". Drawn only for a
/// book that has locations.
struct LocationPlCard: View {
    let shop: Shop
    let report: KhaytEngine.LocationPl

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("an.location_pl"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)
            Text(words.callIt("mac.location_pl_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(words.callIt("an.location"))
                    Text(words.callIt("an.orders")).gridColumnAlignment(.trailing)
                    Text(words.callIt("an.location_revenue")).gridColumnAlignment(.trailing)
                    Text(words.callIt("an.location_expenses")).gridColumnAlignment(.trailing)
                    Text(words.callIt("an.location_profit")).gridColumnAlignment(.trailing)
                    Text(words.callIt("an.margin")).gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                let peak = max(report.rows.map(\.revenue).max() ?? 0, 0.0001)
                ForEach(report.rows) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name(row)).lineLimit(1)
                                .foregroundStyle(row.locationId.isEmpty ? .secondary : .primary)
                            // Revenue against the busiest site's, so a branch
                            // that sold a fraction of the other reads as one.
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Khayt.brand.opacity(0.75))
                                    .frame(width: max(row.revenue > 0 ? 3 : 0,
                                                      geo.size.width * CGFloat(row.revenue / peak)))
                                    .growsToItsReading(row.revenue / peak, from: .leading)
                            }
                            .frame(width: 140, height: 6)
                        }
                        Text("\(row.orders)").monospacedDigit()
                        Text(Money.text(row.revenue, shop.currency)).monospacedDigit()
                        Text(Money.text(row.costs, shop.currency)).monospacedDigit()
                            .help(costsHelp(row))
                        Text(Money.text(row.net, shop.currency)).monospacedDigit()
                            .foregroundStyle(row.net < 0 ? Khayt.late : .primary)
                        Text(row.marginPct.map { Money.quantity($0, decimals: 1) + "%" } ?? "—").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func name(_ row: KhaytEngine.LocationPl.Row) -> String {
        row.locationId.isEmpty
            ? shop.words.callIt("an.unassigned_location")
            : (shop.locationName(row.locationId) ?? row.locationId)
    }

    /// What the costs figure is made of, on hover — the four lines the P&L
    /// table shows as columns.
    private func costsHelp(_ row: KhaytEngine.LocationPl.Row) -> String {
        let words = shop.words
        var parts = [words.callIt("pnl.cogs") + " " + Money.text(row.cogs, shop.currency),
                     words.callIt("an.pnl_expenses") + " " + Money.text(row.expenses, shop.currency)]
        if row.waste > 0 { parts.append(words.callIt("pnl.waste") + " " + Money.text(row.waste, shop.currency)) }
        if row.depreciation > 0 {
            parts.append(words.callIt("mac.pnl_depreciation") + " " + Money.text(row.depreciation, shop.currency))
        }
        if let labour = row.labour, labour > 0 {
            parts.append(words.callIt("pnl.labour") + " " + Money.text(labour, shop.currency))
        }
        return parts.joined(separator: "\n")
    }
}

/// What the location P&L is recomputed on, beside the period: the sites, which
/// machine stands where, and how much book there is.
struct SitesKey: Equatable {
    let locations: [JSONValue]
    let placed: [String]
    let books: Int
}
