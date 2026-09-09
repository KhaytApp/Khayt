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
/// ── THE CONNECTION, WHICH THIS SHEET USED TO REFUSE TO OFFER ─────────────
///
/// This header used to say the printer's API belonged "with the polling this
/// app does not do yet". That stopped being true: the app polls, watches,
/// raises alerts and draws a band off live readings. What had not changed was
/// that there was nowhere to TYPE an address — so a shop could add a printer
/// and had no way at all to link it, and the machines that did work only did
/// so because Electron had written them.
///
/// The old sentence carried one condition worth keeping: "a screen that writes
/// connection settings it cannot test is worse than one that does not offer
/// them". So this one tests them, against the printer, before the shop leaves.
///
/// The webcam and the downtime blocks are still carried through untouched.
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
    // ── The connection ───────────────────────────────────────────────────
    @State private var apiType = ""
    @State private var apiHost = ""
    @State private var apiPort = 0
    /// What the shop has TYPED. Empty means "leave what is stored alone" —
    /// the plaintext is never loaded into this sheet, so blank cannot mean
    /// "no key". `forgetKey` is how a shop says that on purpose.
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var forgetKey = false
    @State private var testing = false
    /// What the printer said, or why it could not be reached.
    @State private var testSaid: String?
    @State private var testWorked = false
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

            // ── HOW KHAYT REACHES IT ─────────────────────────────────────
            //
            // Only for a kind something here can actually ask.
            // `lib/machine-kinds.js` says a laser cutter has no protocol in
            // this repo, and offering it a host field would be inviting a shop
            // to fill in a form that can never do anything.
            if polled {
                LayerRule()
                Connection(
                    shop: shop, type: $apiType, host: $apiHost, port: $apiPort,
                    key: $apiKey, hasStoredKey: $hasStoredKey, forgetKey: $forgetKey,
                    testing: $testing, said: $testSaid, worked: $testWorked,
                    test: test)
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
        apiType = machine.printerApi?.type ?? ""
        apiHost = machine.printerApi?.host ?? ""
        apiPort = machine.printerApi?.port ?? 0
        // Whether there IS one, never what it is. Opening a credential to put
        // it in a text field is how a secret ends up in a screenshot.
        hasStoredKey = !(machine.printerApi?.apiKey ?? "").isEmpty
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

    /// Can anything in this repo ask a machine of this kind what it is doing?
    private var polled: Bool { kinds.first { $0.kind == kind }?.polled ?? true }

    /// Ask the printer, now, with what is on screen.
    ///
    /// ── WHY THIS BUTTON IS THE POINT ──────────────────────────────────────
    ///
    /// The sheet's old header refused to offer connection settings on the
    /// grounds that "a screen that writes connection settings it cannot test
    /// is worse than one that does not offer them", and it was right. A host
    /// typed wrong, a port that is someone else's, a key the printer refuses —
    /// none of it shows up until the shop wonders why the band is empty, hours
    /// later, with nothing on screen ever having said no.
    ///
    /// So this asks the real printer over the real network before the shop
    /// leaves the sheet, and prints what came back.
    private func test() {
        testing = true
        testSaid = nil
        guard let draft = draftMachine() else {
            testing = false
            testSaid = shop.words.callIt("mach.test_bad_draft")
            testWorked = false
            return
        }
        let typed = apiKey
        let build = shop.source.build
        let stored = existing?.printerApi?.apiKey ?? ""
        Task {
            defer { testing = false }
            guard let engine = shop.engine else {
                testSaid = shop.words.callIt("mac.move_no_engine"); testWorked = false; return
            }
            do {
                // The typed key if there is one, else the stored one opened at
                // the point of use — which is the only place this app opens a
                // credential at all.
                var key = typed
                if key.isEmpty, !stored.isEmpty, let build {
                    key = (try? await Secrets.open(stored, for: build)) ?? ""
                }
                let base = try await PrinterWatch.baseURL(draft, engine: engine)
                let status = try await PrinterWatch.read(draft, engine: engine, base: base, key: key,
                                                         fetch: { try await URLSession.shared.data(for: $0) })
                testWorked = true
                let state = status.state.isEmpty ? "—" : status.state
                testSaid = status.filename.isEmpty
                    ? state
                    : "\(state) · \(status.filename)"
            } catch {
                testWorked = false
                testSaid = PrinterWatch.say(error)
            }
        }
    }

    /// The machine as the form currently describes it, for the test above.
    /// Built by decoding, because `Machine` is the store's shape and this sheet
    /// must not become a second definition of it.
    private func draftMachine() -> Machine? {
        let api: [String: JSONValue] = [
            "type": .string(apiType),
            "host": .string(apiHost.trimmingCharacters(in: .whitespaces)),
            "port": .number(Double(apiPort)),
        ]
        let record: JSONValue = .object([
            "id": .string(existing?.id ?? "MACH-draft"),
            "name": .string(name),
            "printerApi": .object(api),
        ])
        guard let data = try? JSONEncoder().encode(record),
              let machine = try? JSONDecoder().decode(Machine.self, from: data) else { return nil }
        return machine
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
        var input: [String: JSONValue] = [
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
        let typed = apiKey
        let clearing = forgetKey
        let build = shop.source.build
        dismiss()
        Task {
            var api: [String: JSONValue] = [
                "type": .string(apiType),
                "host": .string(apiHost.trimmingCharacters(in: .whitespaces)),
                "port": .number(Double(apiPort)),
            ]
            // ── THE KEY IS SEALED HERE OR NOT WRITTEN AT ALL ──────────────
            //
            // `apiKey` is a registered secret path, so what belongs on the
            // record is `__enc__` + OSCrypt under the book's own Keychain key
            // — the same bytes Electron writes and reads. Absent means the
            // shared rule carries the stored one through untouched.
            //
            // A key that cannot be sealed is REFUSED rather than written in
            // the clear: this file syncs, backs up and exports.
            if clearing {
                api["apiKey"] = .string("")
            } else if !typed.isEmpty {
                guard let build else {
                    await MainActor.run { shop.spendProblem = shop.words.callIt("mac.move_sample") }
                    return
                }
                do {
                    api["apiKey"] = .string(try await Secrets.seal(typed, for: build))
                } catch {
                    await MainActor.run {
                        shop.spendProblem = String(describing: error)
                    }
                    return
                }
            }
            input["printerApi"] = .object(api)
            await shop.saveMachine(input, id: id, catalogId: catalogId)
        }
    }
}

/// Address, protocol, credential — and a button that proves them.
private struct Connection: View {
    let shop: Shop
    @Binding var type: String
    @Binding var host: String
    @Binding var port: Int
    @Binding var key: String
    @Binding var hasStoredKey: Bool
    @Binding var forgetKey: Bool
    @Binding var testing: Bool
    @Binding var said: String?
    @Binding var worked: Bool
    let test: () -> Void

    /// Only what this app can actually speak. A menu offering Bambu or Duet
    /// would be a menu whose choices quietly do nothing.
    private var protocols: [String] { PrinterWatch.spoken.sorted() }

    private var reachable: Bool {
        !type.isEmpty && !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("mach.connection"))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase).tracking(0.5).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(shop.words.callIt("mach.protocol")).foregroundStyle(.secondary)
                    Picker("", selection: $type) {
                        Text(shop.words.callIt("mach.protocol_none")).tag("")
                        ForEach(protocols, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: type) { _, now in
                        // The default port for the protocol, so a shop that
                        // picks Moonraker does not have to know it is 7125.
                        if port == 0, !now.isEmpty { port = PrinterWatch.defaultPort(now) }
                        said = nil
                    }
                }
                if !type.isEmpty {
                    GridRow {
                        Text(shop.words.callIt("mac.address")).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("192.168.1.40", text: $host)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: host) { _, _ in said = nil }
                            Text(":").foregroundStyle(.tertiary)
                            TextField("", value: $port, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 62)
                                .onChange(of: port) { _, _ in said = nil }
                        }
                    }
                    GridRow {
                        Text(shop.words.callIt("mach.api_key")).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                SecureField(hasStoredKey && !forgetKey
                                            ? shop.words.callIt("mach.key_kept")
                                            : shop.words.callIt("mach.key_ph"), text: $key)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(forgetKey)
                                    .onChange(of: key) { _, _ in said = nil }
                                if hasStoredKey {
                                    Button(shop.words.callIt(forgetKey ? "common.undo" : "mach.key_forget")) {
                                        forgetKey.toggle()
                                        if forgetKey { key = "" }
                                        said = nil
                                    }
                                    .buttonStyle(.link).font(.caption)
                                }
                            }
                            // WHAT HAPPENS TO IT, in a sentence. A field that
                            // takes a credential and says nothing about where
                            // it goes is one a shop is right to distrust.
                            Text(shop.words.callIt(forgetKey ? "mach.key_will_clear" : "mach.key_where"))
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !type.isEmpty {
                HStack(spacing: 8) {
                    Button(shop.words.callIt("mach.test")) { test() }
                        .disabled(!reachable || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let said {
                        HStack(spacing: 5) {
                            Image(systemName: worked ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(worked ? Khayt.done : Khayt.attention)
                            Text(said)
                                .font(.caption).foregroundStyle(worked ? Khayt.done : Khayt.attention)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
