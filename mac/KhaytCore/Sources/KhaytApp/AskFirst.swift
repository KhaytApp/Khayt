import SwiftUI

/// One question before a write that takes something away.
///
/// ── WHY EVERY ONE-CLICK DELETE NOW ASKS ──────────────────────────────────
///
/// A waste entry, a maintenance task, a spool, what a customer paid, a payment
/// plan: each went in ONE click — a context-menu item next to "Edit", or a red
/// button at the bottom of a sheet beside Save. Several have no undo at all, so
/// the slip that hit the wrong row was simply a record gone. The question
/// names the thing being removed, because "Delete?" asks a shop to agree to
/// something it has not been shown.
///
/// `presenting:` rather than a flag: the item the shop chose is held until the
/// answer, so a table that re-sorts or a book that reloads under the dialog
/// cannot swap which record the confirmation deletes.
extension View {
    func askFirst<Item>(_ item: Binding<Item?>,
                        title: @escaping (Item) -> String,
                        message: ((Item) -> String)? = nil,
                        confirm: String,
                        cancel: String,
                        perform: @escaping (Item) -> Void) -> some View {
        confirmationDialog(
            item.wrappedValue.map(title) ?? "",
            isPresented: Binding(get: { item.wrappedValue != nil },
                                 set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { chosen in
            Button(confirm, role: .destructive) {
                item.wrappedValue = nil
                perform(chosen)
            }
            Button(cancel, role: .cancel) { item.wrappedValue = nil }
        } message: { chosen in
            if let message { Text(message(chosen)) }
        }
    }
}

/// What a confirmation calls a record, in the words the screen already uses.
enum AskName {
    /// "PLA · Galaxy Black" — the two lines of a spool card, on one.
    static func spool(_ spool: Spool) -> String {
        let material = spool.material.isEmpty ? "—" : spool.material
        guard let variant = spool.colourVariant, !variant.isEmpty else { return material }
        return material + " · " + variant
    }

    /// "2026-09-14 · PETG · 180 g" — the row's own date, material and weight.
    @MainActor static func waste(_ entry: WasteEntry, words: Words) -> String {
        [entry.date,
         entry.material.isEmpty ? nil : entry.material,
         Money.grams(entry.weight) + " " + words.callIt("common.grams")]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
