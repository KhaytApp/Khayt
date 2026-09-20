import SwiftUI
import KhaytCore

/// Whose bill is sitting here.
///
/// ── WHY THIS EXISTS AT ALL ────────────────────────────────────────────────
///
/// `OnOrderCard` answers what is still to come and leaves received orders off
/// on purpose — they are history. But a bill is not history: it arrives after
/// the goods as often as with them, and once an order was received this app
/// had nowhere to reach it. The receive sheet takes a bill at the moment the
/// box is opened; this is the week-later case, and the paying of it.
///
/// ── AND WHY IT IS NOT THE OTHER APP'S AGING BAR ───────────────────────────
///
/// That bar counts money committed on orders that have not arrived as well.
/// It answers "what have we taken on"; this answers "whose bill is sitting
/// here", and they are different questions that would have been quietly
/// merged by sharing one filter.
///
/// `invoicePaid` was read by that bar and written by NOTHING, in either app —
/// it sat on a known-unwritten list in the guard. This is the write.
struct BillsCard: View {
    @Bindable var shop: Shop

    private var bills: [PurchaseOrder] { shop.billsToSettle }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CapsLabel(shop.words.callIt("po.ap_record"), tint: Role.text3, size: 9)
                Spacer()
                Text(shop.words.counting(bills.count, "mac.orders_word"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(bills) { order in
                    Row(shop: shop, order: order)
                    if order.id != bills.last?.id { Divider() }
                }
            }
        }
    }

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
                if order.hasBill {
                    // Billed already: the only thing left is to say it is paid.
                    Button(shop.words.callIt("pay.mark_paid")) {
                        Task { shop.moveProblem = await shop.settleBill(order.id, paid: true) }
                    }
                    .disabled(!shop.canMoveJobs)
                } else {
                    Button(shop.words.callIt("po.ap_record")) { shop.billingOrder = order }
                        .disabled(!shop.canMoveJobs)
                }
            }
            .padding(.vertical, 7)
        }

        /// The supplier and what the order came to — the two things somebody
        /// about to pay a bill is checking it against.
        private var said: String {
            var parts: [String] = []
            if !order.supplierName.isEmpty { parts.append(order.supplierName) }
            if let total = order.total, total > 0 {
                parts.append(Money.text(total, shop.currency))
            }
            // A bill that does not match says so HERE, not only on the sheet
            // it was typed into: this is where somebody decides to pay it.
            if order.billMismatched {
                parts.append(shop.words.callIt("po.ap_mismatch"))
            }
            return parts.joined(separator: " · ")
        }
    }
}
