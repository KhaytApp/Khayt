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
                    // ONLY THE PRICES THAT MOVE. A product whose figure comes
                    // out the same ("48 → 48") was listed and counted as
                    // though it were being re-priced; it is still re-costed
                    // with the rest, and said so in one line underneath.
                    VStack(spacing: 0) {
                        List(Self.repriced(changes)) { Self.row($0, currency: shop.currency) }
                        Self.sameNote(changes, words: shop.words)
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
                Button(Self.applyLabel(changes ?? [], words: shop.words)) {
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

    /// One product, what it is listed at and what it would be.
    static func row(_ change: Shop.SpoolRepairChange, currency: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: change.name.isEmpty ? change.id : change.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: figure(change.priceWas, currency)
                 + " \u{2192} " + figure(change.priceNow, currency))
                .monospacedDigit()
        }
    }

    /// The products the repair re-costs without moving their price, in one
    /// line rather than as rows reading "48 → 48".
    @ViewBuilder @MainActor
    static func sameNote(_ changes: [Shop.SpoolRepairChange], words: Words) -> some View {
        let same = changes.count - repriced(changes).count
        if same > 0 {
            Text(words.counting(same, "mac.spool_repair_same_price"))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The rows whose price would actually change.
    static func repriced(_ changes: [Shop.SpoolRepairChange]) -> [Shop.SpoolRepairChange] {
        changes.filter { $0.priceWas != $0.priceNow }
    }

    /// "Re-price 3 products" counts what is re-PRICED; a repair that moves
    /// no price at all only re-costs, and says that instead.
    @MainActor static func applyLabel(_ changes: [Shop.SpoolRepairChange], words: Words) -> String {
        let moved = repriced(changes).count
        return moved > 0 ? words.counting(moved, "mac.spool_repair_apply")
                         : words.callIt("mac.spool_repair_apply_costs")
    }

    static func figure(_ value: Double?, _ currency: String) -> String {
        value.map { Money.text($0, currency) } ?? "\u{2014}"
    }
}
