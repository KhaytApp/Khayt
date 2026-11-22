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
            // The LOG's price, said as such — see `MaterialCostCard`, which
            // is the shelf's.
            Text(shop.words.callIt("mac.price_history_sub"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Row(shop: shop, group: group)
                    if group.id != groups.last?.id { Divider().opacity(0.5) }
                }
            }
        }
    }

    private struct Row: View {
        @Bindable var shop: Shop
        let group: KhaytEngine.PriceGroup

        var body: some View {
            // THE UNIT IS PART OF THE NAME HERE. Two rows reading "PLA" with
            // different figures would look like a bug; "per kg" and "per
            // spool" under them are two honest answers. Said the way the
            // shelf's card says it, in the shop's word for the unit — and in
            // the shelf card's row (`PriceRow`).
            //
            // Five percent before a move is shown, which is the other app's
            // threshold: a badge on every one-riyal wobble is a badge nobody
            // reads.
            PriceRow(title: group.material,
                     detail: shop.words.callIt("mac.mc_per", ["unit": .string(shop.words.unitWord(group.unit))])
                        + " · " + said,
                     figure: group.latest.map { Money.text($0.price, shop.currency) } ?? "\u{2014}",
                     change: PriceRow.change(group.pctChange, atLeast: 5),
                     changeTint: (group.pctChange ?? 0) > 0 ? Khayt.late : Khayt.done)
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
