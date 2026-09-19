import SwiftUI
import KhaytCore

/// Booking goods in against a purchase order.
///
/// ── WHAT PRESSING SAVE ACTUALLY DOES ──────────────────────────────────────
///
/// Four records move together: the order, the spool or the consumable, that
/// spool's own history, and an expense. `lib/purchase-orders.js` decides all
/// four and `Shop.receiveGoods` writes them in ONE swap — the two faults this
/// chain has carried were each one of the four going missing on its own.
///
/// The box opens on what is still OUTSTANDING, because a part delivery is the
/// case worth typing and a full one should need no typing at all.
struct ReceiveSheet: View {
    @Bindable var shop: Shop
    let order: PurchaseOrder

    @State private var amount: Double = 0
    @State private var notes = ""
    @State private var problem: String?
    @State private var started = false
    @FocusState private var focused: Bool

    var body: some View {
        SheetFrame(width: 420) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("po.receive")).font(.headline)
                Text(order.itemName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("po.qty")).foregroundStyle(.secondary)
                    Text(Quantity.ordered(order.qty, unit: order.unit, words: shop.words))
                        .monospacedDigit()
                }
                if order.receivedSoFar > 0 {
                    GridRow {
                        Text(shop.words.callIt("po.received_so_far")).foregroundStyle(.secondary)
                        Text(Quantity.ordered(order.receivedSoFar, unit: order.unit, words: shop.words))
                            .monospacedDigit()
                    }
                }
                GridRow {
                    // The unit is the ORDER's, never a hard-captioned "(g)": a
                    // box of bags asked for in grams is a question nobody can
                    // answer.
                    Text(order.unit.isEmpty
                         ? shop.words.callIt("po.weight_received")
                         : shop.words.callIt("po.qty_received") + " (" + order.unit + ")")
                        .foregroundStyle(.secondary)
                    TextField("", value: $amount, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .focused($focused)
                        .onSubmit(commit)
                }
                GridRow {
                    Text(shop.words.callIt("po.notes")).foregroundStyle(.secondary)
                    TextField("", text: $notes).textFieldStyle(.roundedBorder)
                }
            }

            // What this will book, said before it is booked. An order with no
            // price books nothing, and a shop should know that BEFORE pressing
            // save rather than by finding no expense afterwards.
            if let rate = order.unitPrice, rate > 0 {
                Text(shop.words.callIt("exp.amount") + " "
                     + Money.text((amount * rate * 100).rounded() / 100, shop.currency))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(shop.words.callIt("mac.receipt_books_nothing"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.receivingGoods = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("po.receive"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(amount <= 0)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            // What is still to come. An order with no quantity on it has
            // nothing to offer, so the shop types what arrived.
            amount = order.outstanding
            focused = true
        }
    }

    private func commit() {
        let id = order.id
        let quantity = amount
        let note = notes
        Task {
            let said = await shop.receiveGoods(id, quantity: quantity, notes: note)
            if said == nil { shop.receivingGoods = nil } else { problem = said }
        }
    }
}
