import SwiftUI
import KhaytCore

/// Products costed on a figure other than their spool's size, and what each
/// price would become if they were costed on the size — before anything moves.
///
/// This used to happen on every open, without a word: a spool's size edited,
/// and every product made from it was re-priced (and a live web store followed).
/// Now the shop sees "A 50 → 48" and says yes, or closes the sheet and nothing
/// changes. See `Shop.applySpoolRepair`.
struct SpoolRepairSheet: View {
    @Bindable var shop: Shop
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [Shop.SpoolRepairChange]?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("mac.spool_repair_title")).font(.headline)
                Text(shop.words.callIt("mac.spool_repair_explain"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            Divider()
            Group {
                if let changes {
                    List(changes) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: change.name.isEmpty ? change.id : change.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(verbatim: Self.figure(change.priceWas, shop.currency)
                                 + " \u{2192} " + Self.figure(change.priceNow, shop.currency))
                                .monospacedDigit()
                                .foregroundStyle(change.priceWas == change.priceNow ? .secondary : .primary)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 160)
            Divider()
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.counting(changes?.count ?? 0, "mac.spool_repair_apply")) {
                    guard let changes else { return }
                    working = true
                    Task {
                        await shop.applySpoolRepair(changes)
                        working = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || (changes ?? []).isEmpty || !shop.canMoveJobs)
            }
            .padding()
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 320, idealHeight: 420)
        .task(id: shop.productRows) { changes = await shop.spoolRepairPreview() }
    }

    static func figure(_ value: Double?, _ currency: String) -> String {
        value.map { Money.text($0, currency) } ?? "\u{2014}"
    }
}
