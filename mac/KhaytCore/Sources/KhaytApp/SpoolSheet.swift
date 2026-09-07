import SwiftUI
import AppKit
import KhaytCore

/// Writing a spool down, or correcting one.
///
/// The record and the correction are `lib/spool-edit.js`'s — the same clamps,
/// the same "a blank optional field is absent", the same price history when the
/// cost moves, and the same colour added to the shop's library. A shop's shelf
/// drifts every day (auto-deduction takes grams off, a spool runs out early, a
/// supplier's price changes), so an app that could show the shelf and not
/// correct it was an app a shop still had to leave.
struct SpoolSheet: View {
    /// How wide this sheet is. A CONSTANT rather than a number in the body,
    /// because `SnapshotTests` photographs the sheet at a size of its own and
    /// the two silently disagreed: the sheet grew and the picture kept the old
    /// width, so the render came back cropped down the middle with no failure.
    static let width: CGFloat = 440

    let shop: Shop
    /// The spool being corrected, or nil for one that is not on the shelf yet.
    let existing: Spool?
    @Environment(\.dismiss) private var dismiss

    @State private var material = ""
    @State private var colourVariant = ""
    @State private var swatch = Color(nsColor: NSColor(hex: "#888888") ?? .gray)
    @State private var cost: Double = 0
    @State private var weight: Double = 1000
    @State private var lot = ""
    @State private var reorderPoint: Double = 200
    @State private var openedAt: Date?
    @State private var colours: [String] = []
    @FocusState private var focused: Bool

    private var isNew: Bool { existing == nil }

    /// The materials already on the shelf, once each — a shop restocking types
    /// a name it has used before far more often than a new one.
    private var known: [String] {
        var seen = Set<String>()
        return shop.spools.map(\.material).filter { seen.insert($0).inserted && !$0.isEmpty }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt(isNew ? "mac.new_spool" : "mac.edit_spool")).font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("plib.material")).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField(shop.words.callIt("inv.material_ph"), text: $material)
                            .textFieldStyle(.roundedBorder).focused($focused)
                        if !known.isEmpty {
                            Menu {
                                ForEach(known, id: \.self) { m in
                                    Button(m) { material = m }
                                }
                            } label: { Image(systemName: "list.bullet") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("inv.colour_variant")).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("", text: $colourVariant).textFieldStyle(.roundedBorder)
                        // What the shop has called this material's colours
                        // before. Typing a new one adds it to the library.
                        if !colours.isEmpty {
                            Menu {
                                ForEach(colours, id: \.self) { c in
                                    Button(c) { colourVariant = c }
                                }
                            } label: { Image(systemName: "list.bullet") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("mac.swatch")).foregroundStyle(.secondary)
                    ColorPicker("", selection: $swatch, supportsOpacity: false).labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("mac.weight")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $weight, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 100)
                        Text(shop.words.callIt("mac.grams")).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("mac.cost")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $cost, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 100)
                        Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                        // What a kilo costs is the figure that compares two
                        // suppliers; a price per roll says nothing until you
                        // know what is on the roll.
                        if weight > 0 {
                            Text(shop.words.callIt("mac.per_kilo") + " "
                                 + Money.text(cost / weight * 1000, shop.currency))
                                .font(.callout).foregroundStyle(.tertiary).monospacedDigit()
                                .fixedSize()
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("inv.reorder_point")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $reorderPoint, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 100)
                        Text(shop.words.callIt("mac.grams")).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("inv.lot")).foregroundStyle(.secondary)
                    TextField("", text: $lot).textFieldStyle(.roundedBorder)
                }
                if !isNew {
                    GridRow {
                        Text(shop.words.callIt("inv.opened_on")).foregroundStyle(.secondary)
                        // Optional: a sealed spool has not been opened, and a
                        // date picker that insists on a date would invent one.
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { openedAt != nil },
                                set: { openedAt = $0 ? (openedAt ?? Date()) : nil }))
                                .labelsHidden()
                            if let opened = openedAt {
                                DatePicker("", selection: Binding(get: { opened }, set: { openedAt = $0 }),
                                           in: ...Date(), displayedComponents: .date)
                                    .labelsHidden()
                            }
                        }
                    }
                }
            }

            // What the cost used to be. A shop checking a supplier's invoice
            // asks this, and the answer is already on the record.
            if let history = existing?.priceHistory, !history.isEmpty {
                DetailSection(shop.words.callIt("inv.price_history")) {
                    ForEach(history.suffix(4).reversed(), id: \.date) { entry in
                        DetailLine(entry.date, Money.text(entry.cost, shop.currency), dim: true)
                    }
                }
            }

            HStack {
                if !isNew, shop.canMoveJobs {
                    Button(shop.words.callIt("common.delete"), role: .destructive) {
                        guard let id = existing?.id else { return }
                        dismiss()
                        Task { await shop.deleteSpool(id) }
                    }
                }
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(material.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear(perform: fill)
        .task(id: material) { await loadColours() }
    }

    private func fill() {
        guard let spool = existing else { focused = true; return }
        material = spool.material
        colourVariant = spool.colourVariant ?? ""
        swatch = Color(nsColor: NSColor(hex: spool.color ?? "#888888") ?? .gray)
        cost = spool.cost ?? 0
        weight = spool.weight ?? 0
        lot = spool.lot ?? ""
        reorderPoint = spool.reorderPoint ?? 200
        openedAt = Order.day(spool.openedAt)
        focused = true
    }

    private func loadColours() async {
        guard let engine = shop.engine, !material.isEmpty else { colours = []; return }
        colours = (try? await engine.spoolColours(settings: shop.settingsDict, material: material)) ?? []
    }

    private func commit() {
        var input: [String: JSONValue] = [
            "material": .string(material),
            "color": .string(NSColor(swatch).hexString ?? "#888888"),
            "cost": .number(cost),
            "weight": .number(weight),
            "lot": .string(lot),
            "colourVariant": .string(colourVariant),
            "reorderPoint": .number(reorderPoint),
        ]
        if !isNew {
            // Absent means "leave it as it is", so a cleared date has to be
            // sent as an empty string rather than left out.
            input["openedAt"] = .string(openedAt.map { Shop.today($0) } ?? "")
        }
        let id = existing?.id
        dismiss()
        Task { await shop.saveSpool(input, id: id) }
    }
}
