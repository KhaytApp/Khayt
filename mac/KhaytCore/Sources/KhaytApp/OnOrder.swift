import SwiftUI
import KhaytCore

/// What the shop is waiting for, on the screen where it decides what to buy.
///
/// ── WHY IT SITS ON THE SHELF AND NOT ON A SCREEN OF ITS OWN ───────────────
///
/// "Is more coming?" is a question a shop has while looking at a thin rack, not
/// one it goes somewhere else to ask. The other app gives purchase orders their
/// own tab; this app has no tab to spare on a list that is empty for most
/// shops, and the answer belongs beside what it is about.
///
/// Received orders are left out. They are history, and the card answers what is
/// still to come.
struct OnOrderCard: View {
    @Bindable var shop: Shop

    private var orders: [PurchaseOrder] { shop.openOrders }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CapsLabel(shop.words.callIt("po.title"), tint: Role.text3, size: 9)
                Spacer()
                Text(shop.words.counting(orders.count, "mac.orders_word"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(orders) { order in
                    Row(shop: shop, order: order)
                    if order.id != orders.last?.id { Divider() }
                }
            }
        }
    }

    /// One order: what it is, what is still to come, and the two things a shop
    /// does with it.
    private struct Row: View {
        @Bindable var shop: Shop
        let order: PurchaseOrder

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(order.itemName).lineLimit(1)
                    Text(said).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                // What is still to come, which is the figure the shop is
                // waiting on — not what was ordered, which it already knows.
                Text(amount).font(.callout).monospacedDigit()
                Button(shop.words.callIt(order.receivedSoFar > 0
                                         ? "po.receive_more" : "po.receive")) {
                    shop.receivingGoods = order
                }
                .disabled(!shop.canMoveJobs)
            }
            .padding(.vertical, 7)
            .contextMenu {
                Button(shop.words.callIt("po.close_po")) {
                    Task { shop.moveProblem = await shop.closeOrder(order.id) }
                }
                .disabled(!shop.canMoveJobs)
            }
        }

        /// "Ordered 2026-09-01 · Tuwaiq Supply · due 2026-09-25" — whichever of
        /// those the order actually carries. A supplier nobody named is left
        /// out rather than drawn as an empty gap.
        ///
        /// A DRAFT HAS NOT BEEN ORDERED. Khayt's batch generator writes orders
        /// with `status: 'draft'` for a shop to look over before it sends them,
        /// and saying "Ordered 2026-09-12" against one is the app asserting
        /// something the shop has not done — the same fault as calling an
        /// unpriced job settled.
        private var said: String {
            var parts = order.status == "draft"
                ? [shop.words.callIt("po.status.draft")]
                : [shop.words.callIt("po.ordered_at") + " " + order.orderedAt]
            if !order.supplierName.isEmpty { parts.append(order.supplierName) }
            if let due = order.estimatedDelivery {
                parts.append(shop.words.callIt("po.est_delivery") + " " + due)
            }
            if order.receivedSoFar > 0 {
                parts.append(shop.words.callIt("po.received_so_far") + " "
                             + Quantity.ordered(order.receivedSoFar, unit: order.unit, words: shop.words))
            }
            return parts.joined(separator: " · ")
        }

        private var amount: String {
            Quantity.ordered(order.outstanding, unit: order.unit, words: shop.words)
        }
    }
}

/// A purchase order's quantity, in whatever that order is counted in.
///
/// NOT a second `Quantity`: the shelf's own `Quantity.say` already knows how
/// many decimals a unit deserves and which word Khayt uses for a gram, and a
/// parallel one here would be the same figure spelled two ways in one app.
/// This adds only the case the shelf has no type for — the free-text unit a
/// shop typed onto an order, "roll" or "pcs".
extension Quantity {
    @MainActor
    static func ordered(_ amount: Double, unit: String, words: Words) -> String {
        let named = unit.trimmingCharacters(in: .whitespaces)
        // An order with no unit is a FILAMENT order — the same reading the
        // receive path takes, because absent `kind` means filament — so it is
        // grams, in Khayt's own word for them.
        guard !named.isEmpty else { return say(amount, nil, words) }
        let n = amount == amount.rounded() ? String(Int(amount))
                                           : String(format: "%.2f", amount)
        return n + " " + named
    }
}

/// Purchase orders priced per SPOOL where a per-gram rate was expected.
///
/// About a thousand times the real amount — 750 g of an 85 SAR/kg spool asking
/// for 63,750 instead of 63.75. The code was fixed long ago; books written
/// before it were not, and this app could not say so at all.
///
/// It FLAGS and never corrects on its own: an order may already have been sent
/// to a supplier, so both figures are shown and nothing moves until somebody
/// asks. An order whose linked item carries no cost says so instead of
/// offering a button that would refuse.
struct SuspectOrdersCard: View {
    @Bindable var shop: Shop

    @State private var confirming: KhaytEngine.SuspectOrder?
    @State private var problem: String?

    private var currency: String { shop.currency }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A CAPS LABEL LIKE EVERY OTHER CARD ON THIS SCREEN. Photographed
            // beside them, this one began with a sentence and read as loose
            // prose dropped into a column of labelled sections — a shop
            // scanning the screen could not see what it was without reading
            // it.
            CapsLabel(shop.words.callIt("mac.overpriced_orders"), tint: Role.text3, size: 9)
            Text(shop.words.callIt("po.suspect_head"))
                .font(.callout).fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Text(shop.words.callIt("po.suspect_sub"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(shop.suspectOrders) { suspect in
                HStack(spacing: 10) {
                    Text(suspect.itemName).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Money.text(suspect.currentTotal, currency))
                        .monospacedDigit().foregroundStyle(.tertiary)
                    Image(systemName: "arrow.forward").font(.caption2).foregroundStyle(.tertiary)
                    if let now = suspect.suggestedTotal {
                        Text(Money.text(now, currency)).monospacedDigit().fontWeight(.medium)
                        Button(shop.words.callIt("po.fix_btn")) { confirming = suspect }
                            .disabled(!shop.canMoveJobs)
                    } else {
                        // Nothing to derive a price from, so there is no button
                        // to press — said, rather than offered and refused.
                        Text(shop.words.callIt("po.fix_manual"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }

            if let problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            shop.words.callIt("po.fix_confirm", [
                "was": .string(Money.text(confirming?.currentTotal ?? 0, currency)),
                "now": .string(Money.text(confirming?.suggestedTotal ?? 0, currency))]),
            isPresented: Binding(get: { confirming != nil },
                                 set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button(shop.words.callIt("po.fix_btn")) {
                guard let suspect = confirming else { return }
                confirming = nil
                Task { problem = await shop.correctOrderPrice(suspect.id) }
            }
            Button(shop.words.callIt("common.cancel"), role: .cancel) { confirming = nil }
        }
    }
}
