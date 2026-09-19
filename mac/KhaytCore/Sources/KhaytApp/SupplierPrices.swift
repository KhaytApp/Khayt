import SwiftUI
import KhaytCore

/// What the shop has paid for a material, and whether that has moved.
///
/// ── WHY THIS IS NOT ONE TREND LINE PER MATERIAL ───────────────────────────
///
/// The same word — "PLA" — is attached to a spool bought for 75 and, a month
/// later, a kilogram bought for 22. One line through both says the shop's PLA
/// got cheaper when it did nothing of the sort, and a "best price" picked by
/// sorting the mixed numbers always names whoever sells by the smaller unit.
/// `lib/supplier-prices.js` groups by material AND unit family for exactly
/// that reason; this card draws the groups it is given and never merges them.
///
/// A card per group rather than a chart: what a shop does with this is decide
/// who to ring, and the two facts that settle it are what the last one cost
/// and who has been cheapest.
struct SupplierPricesCard: View {
    @Bindable var shop: Shop
    let groups: [KhaytEngine.PriceGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(shop.words.callIt("mac.price_history"), tint: Role.text3, size: 9)
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Row(shop: shop, group: group)
                    if group.id != groups.last?.id { Divider() }
                }
            }
        }
    }

    private struct Row: View {
        @Bindable var shop: Shop
        let group: KhaytEngine.PriceGroup

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(group.material).lineLimit(1)
                        // THE UNIT IS PART OF THE NAME HERE. Two cards reading
                        // "PLA" with different figures would look like a bug;
                        // "PLA /kg" and "PLA /spool" are two honest answers.
                        Text("/" + group.unit)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(said).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let move = group.pctChange, abs(move) >= 5 {
                    // Five percent, which is the other app's threshold: a
                    // badge on every one-riyal wobble is a badge nobody reads.
                    Text((move > 0 ? "▲" : "▼") + Money.quantity(abs(move)) + "%")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(move > 0 ? Khayt.late : Khayt.done)
                }
                if let latest = group.latest {
                    Text(Money.text(latest.price, shop.currency))
                        .font(.callout).monospacedDigit()
                }
            }
            .padding(.vertical, 7)
        }

        /// The second line: how many purchases are behind the figure, who sold
        /// it cheapest, and — when it happened — that the group mixes grams
        /// with kilograms.
        private var said: String {
            var parts = [shop.words.counting(group.count, "mac.purchases_word")]
            if let best = group.best, group.count > 1, !best.supplier.isEmpty {
                parts.append(shop.words.callIt("mac.cheapest_was")
                             + " " + Money.text(best.price, shop.currency)
                             + " · " + best.supplier)
            } else if let latest = group.latest, !latest.supplier.isEmpty {
                parts.append(latest.supplier)
            }
            if group.converted { parts.append(shop.words.callIt("mac.units_converted")) }
            return parts.joined(separator: " · ")
        }
    }
}
