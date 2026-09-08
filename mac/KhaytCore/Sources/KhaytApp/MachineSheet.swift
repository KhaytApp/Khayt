import SwiftUI
import AppKit
import KhaytCore

/// Writing a printer down, or correcting one.
///
/// The record is `lib/machine-edit.js`'s, and so is what picking a model fills
/// in — the bed, the colours, the power, and what the nozzle is made of, which
/// is the point of Khayt's catalogue knowing it: an X1C ships hardened steel
/// and an MK4S ships brass, a ten-fold difference in expected life.
///
/// WHAT THIS SHEET DELIBERATELY DOES NOT OFFER: the printer's API, its webcam,
/// and its downtime blocks. Those belong with the polling this app does not do
/// yet, and a screen that writes connection settings it cannot test is worse
/// than one that does not offer them. They are carried through untouched.
struct MachineSheet: View {
    /// How wide this sheet is. A CONSTANT rather than a number in the body,
    /// because `SnapshotTests` photographs the sheet at a size of its own and
    /// the two silently disagreed: the sheet grew and the picture kept the old
    /// width, so the render came back cropped down the middle with no failure.
    static let width: CGFloat = 480

    let shop: Shop
    let existing: Machine?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// What kind of machine this is. `fdm` because every machine recorded
    /// before Khayt could ask genuinely is one — see `lib/machine-kinds.js`.
    @State private var kind = "fdm"
    @State private var kinds: [KhaytEngine.MachineKind] = []
    // The colour a new machine starts with, before the shop picks one. The
    // app's own, so a printer added and left alone still looks like it belongs
    // to Khayt rather than to whatever SwiftUI's `.blue` happens to be.
    @State private var swatch = Khayt.cyan
    @State private var model = ""
    @State private var search = ""
    @State private var nozzleDiameter: Double = 0.4
    @State private var powerDraw: Double = 0
    @State private var targetHours: Double = 0
    @State private var nozzleMaterial = "brass"
    @State private var nozzleInstalled: Date?
    @State private var nozzleThreshold: Double = 0
    @State private var nozzleAtInstall: Double = 0
    @FocusState private var focused: Bool

    private var isNew: Bool { existing == nil }

    /// The catalogue, narrowed by what has been typed. Everything when nothing
    /// has: a shop that has not typed yet is browsing, not searching.
    private var matches: [CatalogPrinter] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return shop.catalog }
        return shop.catalog.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt(isNew ? "mach.add" : "mach.edit")).font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("mach.name")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("mach.name_ph"), text: $name)
                        .textFieldStyle(.roundedBorder).focused($focused)
                }
                // FIRST, because it decides what the rest of this sheet is
                // asking about. A nozzle diameter is a question for a filament
                // printer and nonsense for a laser cutter, and a form that asks
                // it anyway is a form that records nonsense.
                GridRow {
                    Text(shop.words.callIt("mach.kind")).foregroundStyle(.secondary)
                    Picker("", selection: $kind) {
                        ForEach(kinds) { choice in
                            Text(shop.words.callIt(choice.nameKey)).tag(choice.kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text(shop.words.callIt("mach.printer_model")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField(shop.words.callIt("mach.printer_model_ph"), text: $search)
                                .textFieldStyle(.roundedBorder)
                            Menu {
                                if matches.isEmpty {
                                    Text(shop.words.callIt("mac.not_found"))
                                } else {
                                    // Capped: a menu of two hundred printers is
                                    // a list nobody scrolls. Typing narrows it.
                                    ForEach(matches.prefix(40)) { printer in
                                        Button(printer.name) { pick(printer) }
                                    }
                                }
                            } label: { Image(systemName: "list.bullet") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        // What the catalogue has checked about the model —
                        // and, by what is missing, what it has not.
                        Text(model.isEmpty ? shop.words.callIt("mach.printer_model_hint") : model)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("mach.color")).foregroundStyle(.secondary)
                    ColorPicker("", selection: $swatch, supportsOpacity: false).labelsHidden()
                }
                // A nozzle diameter is a question for a filament printer and
                // nonsense for a laser cutter. A form that asks it anyway is a
                // form that records nonsense.
                if shows("nozzleDiameter") {
                    GridRow {
                        Text(shop.words.callIt("mac.nozzle")).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            TextField("", value: $nozzleDiameter,
                                      format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 70)
                            Text("mm").foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("mac.power")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $powerDraw, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 70)
                        Text("W").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("mach.target_hours")).foregroundStyle(.secondary)
                    TextField("", value: $targetHours, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 70)
                }
            }

            // The whole wear block belongs to the nozzle, and only a filament
            // printer has one. What wears on a resin printer is its FEP film
            // and its screen, on two different clocks; on a laser it is the
            // tube and the lens. `lib/machine-kinds.js` names all of them —
            // recording them is the next piece of work, and asking a laser
            // when its nozzle went in until then is worse than asking nothing.
            if shows("nozzleDiameter") {
            Divider()

            // The nozzle, as a block: what it is made of, when it went in, and
            // what it had printed by then. Half of that written down is a wear
            // figure that lies.
            Text(shop.words.callIt("mac.nozzle_wear")).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("mach.nozzle_material")).foregroundStyle(.secondary)
                    Picker("", selection: $nozzleMaterial) {
                        // The fitments the wear data knows, with its own
                        // labels. A list written here said "steel" where the
                        // data says "stainless", so a stainless nozzle matched
                        // nothing and the picker came out blank.
                        ForEach(shop.nozzleMaterials) { m in
                            Text(m.label).tag(m.key)
                        }
                        // Whatever this machine actually carries, if the data
                        // has never heard of it — so an unknown fitment is
                        // shown rather than silently replaced by the first
                        // one on the list.
                        if !shop.nozzleMaterials.contains(where: { $0.key == nozzleMaterial }) {
                            Text(nozzleMaterial.capitalized).tag(nozzleMaterial)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("mach.nozzle_installed")).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { nozzleInstalled != nil },
                            set: { nozzleInstalled = $0 ? (nozzleInstalled ?? Date()) : nil }))
                            .labelsHidden()
                        if let installed = nozzleInstalled {
                            DatePicker("", selection: Binding(get: { installed }, set: { nozzleInstalled = $0 }),
                                       in: ...Date(), displayedComponents: .date)
                                .labelsHidden()
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("mach.nozzle_threshold")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $nozzleThreshold, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 90)
                        Text(shop.words.callIt("mac.grams")).foregroundStyle(.secondary)
                    }
                }
            }
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .task {
            await shop.readCatalog()
            kinds = await shop.machineKindChoices()
        }
        .onAppear(perform: fill)
    }

    /// The catalogue model this sheet is about to apply, if any.
    @State private var chosen: String?

    private func fill() {
        guard let machine = existing else { focused = true; return }
        name = machine.name
        // What the module says this machine is, which for every machine
        // recorded before Khayt could ask is a filament printer.
        kind = shop.kind(of: machine)?.kind ?? "fdm"
        swatch = Color(nsColor: NSColor(hex: machine.color ?? "#5b9cf0") ?? .systemBlue)
        model = machine.printerModelName ?? ""
        nozzleDiameter = machine.nozzleDiameter ?? 0.4
        powerDraw = machine.powerDraw ?? 0
        nozzleMaterial = machine.nozzle?.material ?? "brass"
        nozzleInstalled = Order.day(machine.nozzle?.installedAt)
        nozzleThreshold = machine.nozzle?.gramsThreshold ?? 0
        nozzleAtInstall = machine.nozzle?.gramsAtInstall ?? 0
        focused = true
    }

    /// Picking a model fills the fields in front of the shop, so what will be
    /// saved is what is on screen — the rule is applied again at save time.
    private func pick(_ printer: CatalogPrinter) {
        chosen = printer.id
        model = printer.specs
        search = printer.name
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = printer.name }
    }

    /// Whether a field belongs to the kind being edited. The module decides;
    /// nil is the instant before the choices have loaded, and everything shows.
    private func shows(_ field: String) -> Bool {
        kinds.first { $0.kind == kind }?.shows(field) ?? true
    }

    private func commit() {
        var nozzle: [String: JSONValue] = [
            "material": .string(nozzleMaterial),
            "installedAt": .string(nozzleInstalled.map { Shop.today($0) } ?? ""),
            "gramsThreshold": .number(nozzleThreshold),
            "gramsAtInstall": .number(nozzleAtInstall),
        ]
        // A threshold left at zero is one nobody has chosen; the rule fills it
        // from what that material is expected to last.
        if nozzleThreshold <= 0 { nozzle["gramsThreshold"] = .number(0) }
        let input: [String: JSONValue] = [
            "name": .string(name),
            "color": .string(NSColor(swatch).hexString ?? "#5b9cf0"),
            "kind": .string(kind),
            "nozzleDiameter": .number(nozzleDiameter),
            "powerDraw": .number(powerDraw),
            "targetHoursPerDay": .number(targetHours),
            "nozzle": .object(nozzle),
        ]
        let id = existing?.id
        let catalogId = chosen
        dismiss()
        Task { await shop.saveMachine(input, id: id, catalogId: catalogId) }
    }
}
