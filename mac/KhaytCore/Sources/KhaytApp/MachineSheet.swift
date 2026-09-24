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
/// The camera is here too, under the connection, because it depends on it: the
/// address is normalised against the printer's host, the credential that
/// fetches a still is the printer's, and a snapshot may only be fetched from
/// that same host at all.
///
/// The downtime blocks are still carried through untouched.
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
    @State private var swatch = Khayt.brand
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
    /// Which pane is open. Not `@SceneStorage`: two machines edited in one
    /// session are two different questions, and reopening on "Upkeep" because
    /// the last machine needed a nozzle is answering the wrong one.
    @State private var pane = MachineSheet.opensOn
    /// Which tab the sheet opens on. Always the printer's, except for the
    /// snapshot run, which photographs the Connection tab as well — the only
    /// way the camera and plug sections there are ever seen before they ship.
    static var opensOn = "printer"

    // The camera. `camSnapshot` may be typed as a path — `/webcam/?action=snapshot`
    // — and the shared rule makes it absolute against the printer's host.
    @State private var camEnabled = false
    @State private var camSnapshot = ""
    @State private var camRotate = 0
    @State private var camFlipH = false
    @State private var camFlipV = false
    /// What a probe found, or why it did not. Cleared by the next attempt.
    @State private var camNote: String?
    @State private var camLooking = false

    /// When this machine is out of action. Loaded from the record and written
    /// back through the shared rule, which drops a window that cannot be read.
    @State private var downtime: [Shop.DowntimeBlock] = []
    // The smart plug. Secrets typed here are sealed on save; blank keeps what
    // is stored, as the printer's key does.
    @State private var plugType = "none"
    @State private var plugHost = ""
    @State private var plugEntity = ""
    @State private var plugUser = ""
    @State private var plugToken = ""
    @State private var plugPassword = ""
    @State private var plugAutoOff = false
    @State private var plugDelay: Double = 10
    /// What is in each head, typed by the shop. See `LoadedRow`.
    @State private var loadedRows: [LoadedRow] = []
    @State private var hasStoredKey = false
    @State private var forgetKey = false
    /// What a Bambu or an Elegoo is addressed by on its own transport — the
    /// serial on a Bambu, the mainboard id on SDCP. Not a secret.
    @State private var apiSerial = ""
    /// Which printer, on a Repetier-Server running several.
    @State private var apiSlug = ""
    /// A Bambu's LAN access code, as TYPED — the same rules as the key.
    @State private var accessCode = ""
    @State private var hasStoredCode = false
    @State private var forgetCode = false
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
        // The tallest sheet in the app — 36 fields. A sheet cannot be moved, so
        // without this its buttons sit below the screen. See `SheetFrame`.
        SheetFrame(width: Self.width) {
            Text(shop.words.callIt(isNew ? "mach.add" : "mach.edit")).font(.headline)

            // §6: TABS ABOVE TWELVE FIELDS, AND NEVER AT OR BELOW.
            //
            // Both halves apply here and this sheet moves between them: a
            // filament printer Khayt can talk to asks sixteen questions and
            // earns panes; the same sheet for a laser cutter asks seven — no
            // protocol in this repo, no nozzle to wear — and panes over seven
            // fields would be §6 failing in the other direction, a short form
            // pretending to be a preferences window.
            if tabbed {
                SheetPanes(panes: Self.panes, chosen: $pane, words: shop.words) { id in
                    VStack(alignment: .leading, spacing: 14) {
                        switch id {
                        case "connection": connectionPane
                        case "upkeep":     upkeepPane
                        default:           printerPane
                        }
                    }
                    .padding(.top, 14)
                }
            } else {
                printerPane
                if polled { LayerRule(); connectionPane }
                LayerRule()
                upkeepPane
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task {
            await shop.readCatalog()
            kinds = await shop.machineKindChoices()
        }
        .onAppear(perform: fill)
    }

    /// The catalogue model this sheet is about to apply, if any.
    @State private var chosen: String?

    // MARK: - The three panes — §6, and the design's own names

    /// Printer · Connection · Upkeep, in the order a shop meets them.
    static let panes: [Pane] = [
        .init(id: "printer", titleKey: "mac.pane_printer"),
        .init(id: "connection", titleKey: "mac.pane_connection"),
        .init(id: "upkeep", titleKey: "mac.pane_upkeep"),
    ]

    /// What this sheet is actually asking, which is not a constant.
    ///
    /// The design's table counted 13. That is the filament-printer-with-a-
    /// protocol case; `lib/machine-kinds.js` says a laser cutter has no
    /// protocol here and nothing on it wears like a nozzle, so the same sheet
    /// asks seven. §6's rule is about the form in front of the person, so the
    /// count has to be too.
    private var fieldCount: Int {
        var n = 6                                // name, kind, model, colour, power, target hours
        if shows("nozzleDiameter") { n += 1 }    // nozzle size
        if polled { n += 5 }                     // protocol, host, port, key, and the camera block
        n += 1                                   // the downtime log
        if shows("nozzleDiameter") { n += 3 }    // fitment, installed on, replace after
        return n
    }

    private var tabbed: Bool { SheetMap.Sheet.earnsTabs(fieldCount) }

    /// What the machine IS.
    @ViewBuilder private var printerPane: some View {

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
                // WHAT IS LOADED, for a printer that cannot say. The library's
                // "Ready on" chip reads it; a printer that reports its spools
                // (a U1) is read instead, so for those this is only a fallback.
                if kind == "fdm" {
                    GridRow(alignment: .top) {
                        Text(shop.words.callIt("mach.loaded")).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach($loadedRows) { $row in
                                HStack(spacing: 8) {
                                    Toggle(shop.words.callIt("mach.head_n", ["n": .number(Double(row.id + 1))]),
                                           isOn: $row.on)
                                        // One width for every head, or "Head 1"
                                        // is narrower and its row's fields sit
                                        // out of line with the rest.
                                        .frame(minWidth: 90, alignment: .leading)
                                    ColorPicker("", selection: $row.colour, supportsOpacity: false)
                                        .labelsHidden().disabled(!row.on)
                                    TextField("PLA", text: $row.material)
                                        .textFieldStyle(.roundedBorder).frame(width: 110)
                                        .disabled(!row.on)
                                }
                            }
                            Text(shop.words.callIt("mach.loaded_hint"))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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
    }

    /// How Khayt reaches it — and the camera, which the design folds in here
    /// because "a URL and a toggle are a connection, not a subject".
    @ViewBuilder private var connectionPane: some View {
        // ── HOW KHAYT REACHES IT ─────────────────────────────────────
        //
        // Only for a kind something here can actually ask.
        // `lib/machine-kinds.js` says a laser cutter has no protocol in
        // this repo, and offering it a host field would be inviting a shop
        // to fill in a form that can never do anything.
            Connection(
                shop: shop, type: $apiType, host: $apiHost, port: $apiPort,
                key: $apiKey, hasStoredKey: $hasStoredKey, forgetKey: $forgetKey,
                serial: $apiSerial, slug: $apiSlug,
                code: $accessCode, hasStoredCode: $hasStoredCode, forgetCode: $forgetCode,
                testing: $testing, said: $testSaid, worked: $testWorked,
                test: test)

            // ── AND THE CAMERA ───────────────────────────────────────
            //
            // Under the connection because it depends on it: the address is
            // normalised against the printer's host, the credential that
            // fetches a still is the printer's, and a snapshot may only be
            // fetched from that same host at all.
            // ── AND THE PLUG IT SITS ON ──────────────────────────────
            LayerRule()
            plugSection
            LayerRule()
            CameraSettings(
                shop: shop, enabled: $camEnabled, snapshot: $camSnapshot,
                rotate: $camRotate, flipH: $camFlipH, flipV: $camFlipV,
                note: $camNote, looking: $camLooking, find: findCamera)
    }

    /// The smart plug: which kind, where, and whether to switch it off after a
    /// print. The rule that it never cuts a print is said under it, because
    /// that is the question a shop has before trusting a plug with a printer.
    @ViewBuilder private var plugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The Connection section's own heading style, directly above it.
            Text(shop.words.callIt("plug.title"))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase).tracking(0.5).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(shop.words.callIt("mach.kind")).foregroundStyle(.secondary)
                    Picker("", selection: $plugType) {
                        Text(shop.words.callIt("plug.none")).tag("none")
                        Text(shop.words.callIt("plug.kind_shelly")).tag("shelly")
                        // Product names, the same in every language: shown as
                        // they are, not run through the word table.
                        Text(verbatim: "Shelly Plus / Pro").tag("shelly-rpc")
                        Text(verbatim: "Tasmota").tag("tasmota")
                        Text(verbatim: "Home Assistant").tag("homeassistant")
                    }
                    .labelsHidden().fixedSize()
                }
                if plugType != "none" {
                    GridRow {
                        Text(shop.words.callIt("plug.host")).foregroundStyle(.secondary)
                        TextField(plugType == "homeassistant" ? "http://homeassistant.local:8123" : "192.168.1.40",
                                  text: $plugHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    if plugType == "homeassistant" {
                        GridRow {
                            Text(shop.words.callIt("plug.entity")).foregroundStyle(.secondary)
                            TextField("switch.printer", text: $plugEntity).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text(shop.words.callIt("plug.token")).foregroundStyle(.secondary)
                            SecureField(existing?.smartPlug?.token?.isEmpty == false
                                        ? shop.words.callIt("common.secret_unchanged") : "",
                                        text: $plugToken).textFieldStyle(.roundedBorder)
                        }
                    }
                    if plugType == "tasmota" {
                        GridRow {
                            Text(shop.words.callIt("plug.user")).foregroundStyle(.secondary)
                            TextField("", text: $plugUser).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text(shop.words.callIt("plug.password")).foregroundStyle(.secondary)
                            SecureField(existing?.smartPlug?.password?.isEmpty == false
                                        ? shop.words.callIt("common.secret_unchanged") : "",
                                        text: $plugPassword).textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        Toggle(shop.words.callIt("plug.auto_off"), isOn: $plugAutoOff)
                            .gridCellColumns(2)
                    }
                    if plugAutoOff {
                        GridRow {
                            Text(shop.words.callIt("plug.delay")).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                TextField("", value: $plugDelay, format: .number.precision(.fractionLength(0)))
                                    .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 60)
                                Text(shop.words.callIt("plug.minutes")).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if plugType != "none" {
                Text(shop.words.callIt("plug.why"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the shop goes looking for when the machine needs attention.
    @ViewBuilder private var upkeepPane: some View {
            // ── WHEN IT IS OUT OF ACTION ─────────────────────────────────
            //
            // OUTSIDE the `polled` block, for every kind of machine: a laser is
            // booked out for a lens change the same way a printer is booked out
            // for a belt, and the band, the scheduler and the delivery promise
            // read these whatever the machine is.
            DowntimeEditor(shop: shop, blocks: $downtime)

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
    }

    private func fill() {
        loadedRows = LoadedRow.rows(for: existing)
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
        downtime = (machine.downtimeBlocks ?? []).map {
            .init(from: $0.from ?? "", to: $0.to ?? "", reason: $0.words)
        }
        plugType = machine.smartPlug?.type.flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        plugHost = machine.smartPlug?.host ?? ""
        plugEntity = machine.smartPlug?.entity ?? ""
        plugUser = machine.smartPlug?.user ?? ""
        plugAutoOff = machine.smartPlug?.autoOff ?? false
        plugDelay = machine.smartPlug?.delayMin ?? 10
        camEnabled = machine.webcam?.enabled ?? false
        camSnapshot = machine.webcam?.snapshotUrl ?? ""
        camRotate = machine.webcam?.rotate ?? 0
        camFlipH = machine.webcam?.flipH ?? false
        camFlipV = machine.webcam?.flipV ?? false
        apiType = machine.printerApi?.type ?? ""
        apiHost = machine.printerApi?.host ?? ""
        apiPort = machine.printerApi?.port ?? 0
        // Whether there IS one, never what it is. Opening a credential to put
        // it in a text field is how a secret ends up in a screenshot.
        hasStoredKey = !(machine.printerApi?.apiKey ?? "").isEmpty
        hasStoredCode = !(machine.printerApi?.accessCode ?? "").isEmpty
        apiSerial = machine.printerApi?.serial ?? ""
        apiSlug = machine.printerApi?.printerSlug ?? ""
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

    /// Look for a camera on this printer, and say what was found.
    ///
    /// ── ONE GUESS IS NOT ENOUGH, AND THAT IS MEASURED ────────────────────
    ///
    /// `webcamCandidates` returns every address a printer of this family might
    /// serve one on, best first, because a Snapmaker U1 on stock firmware
    /// answers nothing at all on the derived `:8080/?action=snapshot` while the
    /// nginx on port 80 does have a `/webcam/` route. Both conventions are
    /// real, and nothing in the printer's answer says which it uses. So each is
    /// tried until one returns an image.
    ///
    /// A camera that answers 204 or 503 COUNTS AS FOUND. PrusaLink documents
    /// those as "no frame yet" and "temporarily unavailable" — a registered
    /// camera warming up is a camera, and refusing it here would tell a shop it
    /// has none.
    private func findCamera() {
        camNote = nil
        camLooking = true
        let host = apiHost.trimmingCharacters(in: .whitespaces)
        let type = apiType
        let typed = apiKey
        let build = shop.source.build
        Task {
            defer { camLooking = false }
            guard let engine = shop.engine, !host.isEmpty else {
                camNote = shop.words.callIt("mac.cam_needs_host"); return
            }
            var api: [String: JSONValue] = ["type": .string(type), "host": .string(host)]
            if apiPort > 0 { api["port"] = .number(Double(apiPort)) }
            // The key as typed if the shop has just entered one, otherwise the
            // stored one opened for this single use. A probe that cannot
            // authenticate reports "no camera" for a camera that is there.
            if !typed.isEmpty {
                api["apiKey"] = .string(typed)
            } else if let sealed = existing?.printerApi?.apiKey, !sealed.isEmpty, let build,
                      let opened = try? await Secrets.open(sealed, for: build) {
                api["apiKey"] = .string(opened)
            }
            let row = JSONValue.object(api)
            guard let candidates = try? await engine.webcamCandidates(printerApi: row),
                  !candidates.isEmpty else {
                camNote = shop.words.callIt("mac.cam_none"); return
            }
            for candidate in candidates {
                if (try? await engine.assertWebcamHost(candidate, printerApi: row)) == nil { continue }
                guard let url = URL(string: candidate) else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 4
                if let headers = try? await engine.webcamAuthHeaders(printerApi: row) {
                    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                }
                guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
                let http = response as? HTTPURLResponse
                let refusal = try? await engine.checkSnapshot(
                    status: http?.statusCode ?? 0,
                    contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                    contentLength: data.count)
                if refusal == nil || refusal == "no_frame_yet" {
                    camSnapshot = candidate
                    camEnabled = true
                    camNote = refusal == "no_frame_yet"
                        ? shop.words.callIt("mac.cam_warming")
                        : shop.words.callIt("mac.cam_found")
                    return
                }
            }
            camNote = shop.words.callIt("mac.cam_none")
        }
    }

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
        let typedCode = accessCode
        let clearingCode = forgetCode
        let serial = apiSerial.trimmingCharacters(in: .whitespaces)
        let slug = apiSlug.trimmingCharacters(in: .whitespaces)
        let wantsCamera = camEnabled
        let still = camSnapshot.trimmingCharacters(in: .whitespaces)
        let turn = camRotate
        let mirrorH = camFlipH, mirrorV = camFlipV
        let windows = downtime
        let loadedNow = kind == "fdm" ? loadedRows.filter(\.on) : nil
        let plugForm: [String: JSONValue] = [
            "type": .string(plugType), "host": .string(plugHost.trimmingCharacters(in: .whitespaces)),
            "entity": .string(plugEntity.trimmingCharacters(in: .whitespaces)),
            "user": .string(plugUser.trimmingCharacters(in: .whitespaces)),
            "autoOff": .bool(plugAutoOff), "delayMin": .number(plugDelay),
        ]
        let typedPlugToken = plugToken, typedPlugPassword = plugPassword
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
            // The identifier each transport addresses a machine by. Sent only
            // for the protocols that use it, so switching a Bambu to Moonraker
            // does not write an empty serial over the one it had.
            if ["bambu", "sdcp"].contains(apiType) { api["serial"] = .string(serial) }
            if apiType == "repetier" { api["printerSlug"] = .string(slug) }
            // A Bambu's access code: sealed here or not written, exactly as the
            // key above — it is the MQTT password and a registered secret path.
            if apiType == "bambu" {
                if clearingCode {
                    api["accessCode"] = .string("")
                } else if !typedCode.isEmpty {
                    guard let build else {
                        await MainActor.run { shop.spendProblem = shop.words.callIt("mac.move_sample") }
                        return
                    }
                    do { api["accessCode"] = .string(try await Secrets.seal(typedCode, for: build)) }
                    catch {
                        await MainActor.run { shop.spendProblem = String(describing: error) }
                        return
                    }
                }
            }
            input["printerApi"] = .object(api)
            // THROUGH THE SHARED RULE, not written as typed. `sanitizeWebcam`
            // makes a path absolute against the printer's host, bounds the
            // rotation to the four it allows, and drops anything that is not an
            // http(s) URL — so a camera saved here is one this app and Khayt
            // will both fetch from, or none at all.
            // Through the shared rule like everything else here: it drops a
            // window that runs backwards or cannot be read, sorts them and caps
            // the list. A row typed wrongly is refused in ONE place rather than
            // by two apps with two opinions.
            input["downtimeBlocks"] = .array(windows.map {
                .object(["from": .string($0.from), "to": .string($0.to),
                         "reason": .string($0.reason)])
            })
            let cam: JSONValue = .object([
                "enabled": .bool(wantsCamera),
                "snapshotUrl": .string(still),
                "rotate": .number(Double(turn)),
                "flipH": .bool(mirrorH), "flipV": .bool(mirrorV),
            ])
            if let engine = shop.engine,
               let clean = try? await engine.sanitizeWebcam(cam, printerApi: .object(api)) {
                input["webcam"] = clean
            }
            // Through the shared rule, which drops a colour it cannot read.
            if let loadedNow {
                input["loaded"] = .array(loadedNow.map {
                    .object(["slot": .number(Double($0.id)),
                             "hex": .string(NSColor($0.colour).hexString ?? ""),
                             "material": .string($0.material.trimmingCharacters(in: .whitespaces))])
                })
            }
            // The plug through the shared rule. A secret goes in SEALED, and only
            // when one was typed: absent keeps what is stored.
            var plug = plugForm
            for (key, typed) in [("token", typedPlugToken), ("password", typedPlugPassword)] where !typed.isEmpty {
                guard let build else { break }
                if let sealed = try? await Secrets.seal(typed, for: build) { plug[key] = .string(sealed) }
            }
            input["smartPlug"] = .object(plug)
            await shop.saveMachine(input, id: id, catalogId: catalogId)
            shop.loadedChanged()
        }
    }
}

/// One head in the sheet's "Loaded now" rows.
struct LoadedRow: Identifiable, Equatable {
    let id: Int
    var on: Bool
    var colour: Color
    var material: String

    /// One row per head: as many as the machine has, or as it has rows for,
    /// with what it last had typed in them.
    static func rows(for machine: Machine?) -> [LoadedRow] {
        let kept = machine?.loadedByHand ?? []
        let heads = min(16, max(1, machine?.maxColors ?? 1, (kept.map(\.slot).max() ?? -1) + 1))
        return (0..<heads).map { slot in
            if let row = kept.first(where: { $0.slot == slot }) {
                return LoadedRow(id: slot, on: true,
                                 colour: Color(nsColor: NSColor(hex: row.hex) ?? .white),
                                 material: row.material)
            }
            return LoadedRow(id: slot, on: false, colour: .white, material: "PLA")
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
    @Binding var serial: String
    @Binding var slug: String
    @Binding var code: String
    @Binding var hasStoredCode: Bool
    @Binding var forgetCode: Bool
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
                    if type == "bambu" || type == "sdcp" {
                        // One field, two meanings, as the other app has it: the
                        // string each transport addresses a machine by.
                        GridRow {
                            Text(shop.words.callIt(type == "bambu" ? "mac.mach_serial" : "mac.mach_mainboard"))
                                .foregroundStyle(.secondary)
                            TextField(type == "bambu" ? "00M00A000000000" : "", text: $serial)
                                .textFieldStyle(.roundedBorder).monospaced()
                                .onChange(of: serial) { _, _ in said = nil }
                        }
                    }
                    if type == "repetier" {
                        GridRow {
                            Text(shop.words.callIt("mac.mach_slug")).foregroundStyle(.secondary)
                            TextField("default", text: $slug)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: slug) { _, _ in said = nil }
                        }
                    }
                    if type == "bambu" {
                        GridRow {
                            Text(shop.words.callIt("mac.mach_access_code")).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    SecureField(hasStoredCode && !forgetCode
                                                ? shop.words.callIt("mach.key_kept") : "", text: $code)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(forgetCode)
                                        .onChange(of: code) { _, _ in said = nil }
                                    if hasStoredCode {
                                        Button(shop.words.callIt(forgetCode ? "common.undo" : "mach.key_forget")) {
                                            forgetCode.toggle()
                                            if forgetCode { code = "" }
                                            said = nil
                                        }
                                        .buttonStyle(.link).font(.caption)
                                    }
                                }
                                // What makes it answer at all, which is the
                                // question every Bambu owner asks first.
                                Text(shop.words.callIt("mac.mach_bambu_hint"))
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    // A Bambu and an Elegoo take no API key: the access code and
                    // nothing at all, respectively. A key field there is one a
                    // shop would fill in for nothing.
                    if type != "bambu" && type != "sdcp" {
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

/// The camera half of the machine sheet.
///
/// Deliberately short. A shop sets a camera up once, and the fields that matter
/// are whether it is on, where it is, and which way up — the rest of what
/// `lib/webcam.js` carries (stream type, timelapse mode, cloud relay) belongs
/// to features this app does not have, and offering them would be asking for
/// answers nothing here reads.
private struct CameraSettings: View {
    let shop: Shop
    @Binding var enabled: Bool
    @Binding var snapshot: String
    @Binding var rotate: Int
    @Binding var flipH: Bool
    @Binding var flipV: Bool
    @Binding var note: String?
    @Binding var looking: Bool
    let find: () -> Void

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(words.callIt("mac.camera"), isOn: $enabled)
                Spacer()
                // A shop should not have to know that its camera lives on
                // `/webcam/?action=snapshot`. This asks the printer.
                Button(words.callIt("mac.cam_find"), action: find)
                    .disabled(looking)
                if looking { ProgressView().controlSize(.small) }
            }

            if enabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text(words.callIt("mac.cam_still")).font(.caption).foregroundStyle(.secondary)
                    // NO PLACEHOLDER. An example address is not English and
                    // not translatable, but it would be the one literal on this
                    // screen that never went through `Words` — and the guard
                    // that catches those is right to be blunt. The shape is in
                    // the caption below, which is a sentence and has an Arabic.
                    TextField("", text: $snapshot)
                        .textFieldStyle(.roundedBorder)
                    // A PATH IS ENOUGH. The shared rule makes it absolute
                    // against the printer's host, which is also the only host it
                    // may ever be fetched from.
                    Text(words.callIt("mac.cam_same_host"))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    Picker(words.callIt("mac.cam_rotate"), selection: $rotate) {
                        ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    Toggle(words.callIt("mac.cam_flip_h"), isOn: $flipH)
                    Toggle(words.callIt("mac.cam_flip_v"), isOn: $flipV)
                }
            }

            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// When a machine is out of action, and why.
///
/// ── THE MAC COULD HONOUR THESE AND NOT SET ONE ───────────────────────────
///
/// The band draws the window, the scheduler counts it against the machine's
/// load, and the delivery promise stops offering those hours — all three read
/// `downtimeBlocks`, and only Khayt could write one. A shop working on the Mac
/// could see that a printer was booked out and had to open the other app to
/// say so.
///
/// ── LOCAL WALL-CLOCK, THE SHAPE KHAYT WRITES ─────────────────────────────
///
/// `YYYY-MM-DDTHH:mm`, no zone, which is what a `datetime-local` input
/// produces. "Thursday 2pm" is what a shop means by a maintenance window, and
/// both apps have to write one shape or a window set here and read there would
/// be a different four hours.
struct DowntimeEditor: View {
    let shop: Shop
    @Binding var blocks: [Shop.DowntimeBlock]

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(words.callIt("mach.downtime")).font(.callout.weight(.medium))
                Spacer()
                Button(words.callIt("mach.downtime_add")) {
                    // Tomorrow morning to tomorrow afternoon: a shape to edit
                    // rather than four empty fields to fill.
                    let start = Calendar.book.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    blocks.append(.init(from: Self.stamp(Self.at(start, hour: 9)),
                                        to: Self.stamp(Self.at(start, hour: 13)),
                                        reason: ""))
                }
            }
            if blocks.isEmpty {
                Text(words.callIt("mac.downtime_none"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(blocks.indices, id: \.self) { at in
                HStack(spacing: 8) {
                    DatePicker("", selection: binding(at, \.from), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                    Text("→").foregroundStyle(.tertiary)
                    DatePicker("", selection: binding(at, \.to), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                    TextField(words.callIt("mach.downtime_reason"), text: reason(at))
                        .textFieldStyle(.roundedBorder).frame(minWidth: 90)
                    Button {
                        blocks.remove(at: at)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(words.callIt("common.delete"))
                }
                // A window that reads backwards is dropped on save by the
                // shared rule, silently — which would be a shop typing
                // something and finding nothing there. It is said here instead,
                // while it can still be corrected.
                if !blocks[at].isReadable {
                    Text(words.callIt("mac.downtime_backwards"))
                        .font(.caption2).foregroundStyle(Khayt.attention)
                }
            }
        }
    }

    private func binding(_ at: Int, _ path: WritableKeyPath<Shop.DowntimeBlock, String>) -> Binding<Date> {
        Binding(
            get: { Self.parse(blocks[at][keyPath: path]) ?? Date() },
            set: { blocks[at][keyPath: path] = Self.stamp($0) })
    }

    private func reason(_ at: Int) -> Binding<String> {
        Binding(get: { blocks[at].reason }, set: { blocks[at].reason = $0 })
    }

    /// `2026-09-10T14:00` — no zone, no seconds, matching Khayt's own field.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: text)
    }

    private static func at(_ day: Date, hour: Int) -> Date {
        Calendar.book.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
}
