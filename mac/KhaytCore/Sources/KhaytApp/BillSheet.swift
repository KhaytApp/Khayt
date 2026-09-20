import SwiftUI
import KhaytCore

/// A supplier's bill that turned up after the goods.
///
/// The receive sheet takes one at the moment the box is opened, which is when
/// it usually arrives. This is the other case — a week later, against an order
/// that has already left the "still to come" card — and it asks for the same
/// three things and gives the same verdict, from the same rule.
struct BillSheet: View {
    @Bindable var shop: Shop
    let order: PurchaseOrder

    @State private var bill = Shop.Bill()
    @State private var verdict = "none"
    @State private var started = false

    var body: some View {
        SheetFrame(width: 420) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("po.ap_record")).font(.headline)
                Text(order.itemName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("po.sup_inv_num")).foregroundStyle(.secondary)
                    TextField("", text: $bill.number).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(shop.words.callIt("po.sup_inv_amount")).foregroundStyle(.secondary)
                    TextField("", value: $bill.amount,
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                }
                GridRow {
                    Text(shop.words.callIt("po.sup_inv_date")).foregroundStyle(.secondary)
                    TextField("", text: $bill.day).textFieldStyle(.roundedBorder)
                }
            }

            // What the order expected, said plainly: somebody typing a figure
            // off a piece of paper is comparing it with this.
            if let total = order.total, total > 0 {
                Text(shop.words.callIt("po.qty") + " · " + Money.text(total, shop.currency))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if verdict != "none" {
                Label(shop.words.callIt(verdict == "mismatch" ? "po.ap_mismatch" : "po.ap_matched"),
                      systemImage: verdict == "mismatch"
                          ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(verdict == "mismatch" ? Khayt.attention : Role.text2)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.billingOrder = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    let id = order.id
                    let paper = bill
                    shop.billingOrder = nil
                    Task { shop.moveProblem = await shop.recordBill(id, paper) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!bill.isWorthRecording)
            }
        }
        .task(id: bill) { verdict = await shop.billVerdict(on: order, bill: bill) }
        .onAppear {
            guard !started else { return }
            started = true
            bill.day = Shop.localDay()
        }
    }
}
