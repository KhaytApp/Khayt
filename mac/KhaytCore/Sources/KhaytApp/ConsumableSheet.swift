import SwiftUI
import KhaytCore

/// Adding or correcting a consumable: glue, IPA, mailing bags, brass nozzles.
///
/// The fields are `lib/consumable-edit.js`'s, and the rule decides what each
/// one means — the trim, the clamp to zero, what a blank category does. This
/// sheet collects them and nothing more, so it cannot disagree with the other
/// app about any of it.
struct ConsumableSheet: View {
    /// A CONSTANT for the reason `SpoolSheet` gives: the snapshot tests
    /// photograph the sheet at a size of their own, and a number written into
    /// the body lets the two drift apart with no failure.
    static let width: CGFloat = 400

    let shop: Shop
    /// The consumable being corrected, or nil for one not on the shelf yet.
    let existing: Consumable?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var stock: Double = 0
    /// Free text, unlike a spool's unit — nothing converts with it. See
    /// `lib/consumable-edit.js` for why this is not a picker.
    @State private var unit = ""
    @State private var cost: Double = 0
    @State private var minStock: Double = 0
    /// 0 is hourly deduction switched OFF, which the rule stores as 0 rather
    /// than dropping — "never configured" is a different claim.
    @State private var usagePerHour: Double = 0
    @State private var category = ""
    @State private var isPackaging = false
    /// The shelves this shop already uses. A menu rather than a fixed list: a
    /// shop's shelves are its own, and matching is case- and space-insensitive
    /// so picking one and retyping it land in the same place.
    @State private var known: [String] = []
    @FocusState private var focused: Bool

    private var isNew: Bool { existing == nil }

    var body: some View {
        SheetFrame(width: Self.width) {
            Text(shop.words.callIt(isNew ? "cons.add_title" : "cons.edit_title")).font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("cons.name")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("cons.name_ph"), text: $name)
                        .textFieldStyle(.roundedBorder).focused($focused)
                }
                // BEFORE the count, because it says what the count is — the
                // same order and the same reason as the spool sheet.
                GridRow {
                    Text(shop.words.callIt("cons.unit")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("cons.unit_ph"), text: $unit)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(shop.words.callIt("cons.stock")).foregroundStyle(.secondary)
                    amount($stock)
                }
                GridRow {
                    Text(shop.words.callIt("cons.min_stock")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        amount($minStock)
                        // Said here because the shelf draws "low" on an empty
                        // item whatever this says, and a shop that leaves this
                        // at nought should know that is not "never warn me".
                        Text(shop.words.callIt("cons.min_stock_note"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    Text("\(shop.words.callIt("cons.cost")) (\(shop.currency))")
                        .foregroundStyle(.secondary)
                    amount($cost, step: 0.01)
                }
                GridRow {
                    Text(shop.words.callIt("cons.category")).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField(shop.words.callIt("cons.category_ph"), text: $category)
                            .textFieldStyle(.roundedBorder)
                        if !known.isEmpty {
                            Menu {
                                ForEach(known, id: \.self) { c in
                                    Button(c) { category = c }
                                }
                            } label: { Image(systemName: "list.bullet") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("cons.usage_per_hour")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        amount($usagePerHour, step: 0.01)
                        Text(shop.words.callIt("cons.auto_deducted"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle(shop.words.callIt("cons.is_packaging"), isOn: $isPackaging)
                }
            }

        } footer: {
            HStack {
                if !isNew, shop.canMoveJobs {
                    Button(shop.words.callIt("common.delete"), role: .destructive) {
                        guard let id = existing?.id else { return }
                        dismiss()
                        Task { await shop.deleteConsumable(id) }
                    }
                }
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: fill)
        .task { known = await shop.consumableCategorySuggestions() }
    }

    /// A number field that cannot be dragged below zero. The rule clamps
    /// anyway — this is so the form never SHOWS a figure the book will refuse.
    private func amount(_ value: Binding<Double>, step: Double = 1) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .onChange(of: value.wrappedValue) { _, now in
                if now < 0 { value.wrappedValue = 0 }
            }
    }

    private func fill() {
        guard let existing else { focused = true; return }
        name = (existing.name ?? "")
        stock = existing.onHand
        unit = existing.unit ?? ""
        cost = existing.cost ?? 0
        minStock = existing.threshold
        usagePerHour = existing.usagePerHour ?? 0
        category = existing.category ?? ""
        isPackaging = existing.isPackaging ?? false
        focused = true
    }

    private func commit() {
        // Every field is sent, including the zeroes and the empty category:
        // absent means "leave it alone" to the rule, so a shop clearing a
        // category or a usage rate has to send the cleared value, not omit it.
        let input: [String: JSONValue] = [
            "name": .string(name),
            "stock": .number(stock),
            "unit": .string(unit),
            "cost": .number(cost),
            "minStock": .number(minStock),
            "usagePerHour": .number(usagePerHour),
            "category": .string(category),
            "isPackaging": .bool(isPackaging),
        ]
        let id = existing?.id
        dismiss()
        Task { await shop.saveConsumable(input, id: id) }
    }
}
