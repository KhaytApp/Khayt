import SwiftUI
import KhaytCore

/// Erasing a customer who has work in the book (PDPL's right to erasure).
///
/// The desktop's dialog (`renderer/clients.js deleteClient`), in its words:
/// what the customer has, how many invoiced or paid jobs keep the name, and
/// the two ways — Unlink, recommended, and Full erase — each explained. The
/// write plans again on the book as it is then (`Shop.applyCustomerErase`).
struct CustomerEraseSheet: View {
    let shop: Shop
    let request: CustomerEraseRequest
    @Environment(\.dismiss) private var dismiss
    @State private var full = false
    @State private var working = false

    var body: some View {
        let counts = request.plan.counts
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("priv.erase_title")).font(.headline)
                Text(request.name).font(.callout).foregroundStyle(.secondary)
            }
            Text(shop.words.callIt("priv.erase_summary", [
                "orders": .number(Double(counts.orders)),
                "intake": .number(Double(counts.intake)),
                "comms": .number(Double(counts.communications)),
            ]))
            .fixedSize(horizontal: false, vertical: true)
            if counts.keptNames > 0 {
                Text(shop.words.callIt("priv.erase_keeps_invoiced", ["n": .number(Double(counts.keptNames))]))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A card with a balance is money the shop owes, and keeps its holder.
            if counts.keptCards > 0 {
                Text(shop.words.counting(counts.keptCards, "mac.erase_keeps_cards"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            choice(full: false, title: "priv.mode_unlink", hint: "priv.mode_unlink_hint")
            choice(full: true, title: "priv.mode_full", hint: "priv.mode_full_hint")
            Text(shop.words.callIt("mac.undo_after"))
                .font(.caption).foregroundStyle(.secondary)
            if let problem = shop.moveProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.delete"), role: .destructive) {
                    working = true
                    let id = request.clientId, chosen = full
                    Task {
                        await shop.eraseCustomer(id, full: chosen)
                        working = false
                        if shop.moveProblem == nil { dismiss() }
                    }
                }
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// One way to erase: a radio mark, its name, and what it does.
    private func choice(full value: Bool, title: String, hint: String) -> some View {
        Button {
            full = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: full == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(full == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(shop.words.callIt(title)).fontWeight(.semibold)
                    Text(shop.words.callIt(hint))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(full == value ? .isSelected : [])
    }
}
