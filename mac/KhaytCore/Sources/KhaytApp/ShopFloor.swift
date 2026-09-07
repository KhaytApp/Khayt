import SwiftUI
import KhaytCore

/// The machines.
///
/// A card each rather than a table: a shop has a handful of printers, not four
/// hundred, and what you want from a machine — its bed, its nozzle, how many
/// colours — does not line up into columns worth scanning.
struct Machines: View {
    let shop: Shop

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(shop.machines) { machine in
                    Card(machine: machine, wear: shop.wear[machine.id], shop: shop)
                }
            }
            .padding(16)
        }
        .background(Khayt.ground)
        .overlay {
            if shop.machines.isEmpty {
                ContentUnavailableView(shop.words.callIt("mac.no_machines"),
                                       systemImage: "printer",
                                       description: Text(shop.words.callIt("mac.no_machines_hint")))
            }
        }
        .toolbar {
            ToolbarItem {
                Button(shop.words.callIt("mach.add"), systemImage: "plus") { shop.addingMachine = true }
                    .disabled(!shop.canMoveJobs)
            }
        }
    }
}

private struct Card: View {
    let machine: Machine
    let wear: NozzleWear?
    let shop: Shop

    var body: some View {
        card
            .contextMenu {
                if shop.canMoveJobs {
                    Button(shop.words.callIt("mach.edit")) { shop.editingMachine = machine }
                    // Only where there is a history to read. Klipper keeps one;
                    // the other six protocols do not expose one Khayt can read,
                    // and a menu item that always answers "not this printer" is
                    // an item that teaches people to ignore the menu.
                    if PrinterWatch.notWatched(machine) == nil {
                        Button(shop.words.callIt("mac.read_history")) {
                            Task { await shop.importPrinterHistory(machine) }
                        }
                        .disabled(shop.importingHistory != nil)
                    }
                }
            }
    }

    /// Amber down the leading edge while this machine is laying down plastic.
    ///
    /// `Palette.swift` reserves that colour for exactly this — "the one thing
    /// on any of these screens worth looking up at" — and the screen that
    /// shows the printers was the one screen not using it.
    ///
    /// Only `printing`, not `paused`. A paused machine is not being made on,
    /// and lighting it the same amber would make the colour mean "a job is
    /// attached" rather than "it is running now".
    private var running: Bool {
        Live.isPrinting(shop.printers.readings[machine.id]?.status?.state ?? "")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // The colour the shop gave this machine, which is how it is
                // recognised on every other screen in Khayt.
                RoundedRectangle(cornerRadius: 3)
                    .fill(swatch)
                    .frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.name).font(.title3.weight(.semibold)).lineLimit(1)
                        // The name is the handle: clicking it opens the printer,
                        // the way clicking a job's name opens the job.
                        .onTapGesture(count: 2) {
                            if shop.canMoveJobs { shop.editingMachine = machine }
                        }
                    if !machine.model.isEmpty {
                        Text(machine.model).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // Only when there is something under it. A section header with
            // nothing beneath it reads as a screen that failed to load.
            if hasSpecs {
            DetailSection(shop.words.callIt("mac.the_machine")) {
                if let bed = machine.bedSize { DetailLine(shop.words.callIt("mac.bed"), bed) }
                if let d = machine.nozzleDiameter {
                    DetailLine(shop.words.callIt("mac.nozzle"), "\(Money.figure(d)) mm")
                }
                if let n = machine.maxColors { DetailLine(shop.words.callIt("mac.colours"), "\(n)") }
                if let e = machine.extruderType { DetailLine(shop.words.callIt("mac.extruder"), e) }
                if let w = machine.powerDraw { DetailLine(shop.words.callIt("mac.power"), "\(Int(w)) W") }
                if let address = machine.address {
                    // The address, never the key. The store keeps that encrypted
                    // and this screen has no business opening it to say where a
                    // printer lives.
                    DetailLine(shop.words.callIt("mac.address"), address, dim: true)
                }
            }
            }

            Live(machine: machine, shop: shop)

            if let wear, let nozzle = machine.nozzle {
                DetailSection(shop.words.callIt("mac.nozzle_wear")) {
                    // The bar is the figure. `lib/nozzle-wear.js` weights an
                    // abrasive kilo differently from a plain one, and this shows
                    // its answer rather than grams over threshold.
                    ProgressView(value: min(1, wear.pct / 100)) {
                        HStack {
                            Text("\(Int(wear.wear)) / \(Int(wear.threshold)) \(shop.words.callIt("common.grams"))")
                                .monospacedDigit()
                            Spacer()
                            if wear.over {
                                Text(shop.words.callIt("mac.nozzle_due")).foregroundStyle(Khayt.attention)
                            } else {
                                Text("\(Int(wear.pct))%").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                    .tint(wear.over ? Khayt.attention : .accentColor)
                    if let installed = nozzle.installedAt, let day = Order.day(installed) {
                        DetailLine(shop.words.callIt("mac.installed"),
                                   day.formatted(date: .abbreviated, time: .omitted), dim: true)
                    }
                    if let material = nozzle.material {
                        DetailLine(shop.words.callIt("plib.material"), material, dim: true)
                    }
                    // WHERE THE FIGURE CAME FROM. The counter reads completed
                    // orders unless the machine's own history has been read,
                    // and the two answers can differ by a factor of six — this
                    // printer has run 133 jobs and sold nineteen. A number
                    // whose source is not stated is a number nobody can check.
                    if machine.hasPrinterHistory {
                        Text(shop.words.callIt("mac.wear_from_printer"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            if let materials = machine.compatMaterials, !materials.isEmpty {
                DetailSection(shop.words.callIt("mac.takes")) {
                    Text(materials.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card(rail: running ? Khayt.hot : nil, padding: 14)
    }

    private var hasSpecs: Bool {
        machine.bedSize != nil || machine.nozzleDiameter != nil || machine.maxColors != nil
            || machine.extruderType != nil || machine.powerDraw != nil || machine.address != nil
    }

    private var swatch: Color {
        guard var hex = machine.color?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else {
            return .secondary
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return .secondary }
        return Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

/// The filament on the shelf, drawn as a shelf.
///
/// ── WHY THIS IS NOT A TABLE ───────────────────────────────────────────────
///
/// It was one, and the shop's six spools came back as six rows of grey text
/// over a twelve-pixel colour chip, followed by a dozen empty striped rows that
/// made a stocked shelf look like a broken screen. A filament shelf is read by
/// COLOUR first — it is how a spool is picked off a rack in a workshop — and
/// colour was the one thing the table had almost none of.
///
/// So the colour is the row now: a spool seen face on, at the size a colour has
/// to be before it can be told from its neighbour. Everything else a shop asks
/// of this screen is arranged around it — what it is, how much is left, whether
/// it is about to run out, and what a kilo of it costs.
///
/// The grid stops where the spools stop. A shelf with six spools on it shows
/// six spools.
struct Inventory: View {
    @Bindable var shop: Shop
    @State private var selection: Spool.ID?

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)]

    private var shown: [Spool] {
        let term = shop.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return shop.spools }
        return shop.spools.filter {
            $0.material.lowercased().contains(term)
                || ($0.colourVariant ?? "").lowercased().contains(term)
        }
    }

    var body: some View {
        Group {
            if shop.spools.isEmpty {
                ContentUnavailableView(shop.words.callIt("mac.no_filament"), systemImage: "circle.dashed")
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: shop.search)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shown) { spool in
                            SpoolCard(spool: spool, shop: shop,
                                      low: shop.lowSpools[spool.id] ?? false,
                                      selected: selection == spool.id)
                                .onTapGesture { selection = spool.id }
                                .onTapGesture(count: 2) {
                                    if shop.canMoveJobs { shop.editingSpool = spool }
                                }
                                .contextMenu {
                                    if shop.canMoveJobs {
                                        Button(shop.words.callIt("mac.edit_spool")) {
                                            shop.editingSpool = spool
                                        }
                                        Button(shop.words.callIt("common.delete"), role: .destructive) {
                                            Task { await shop.deleteSpool(spool.id) }
                                        }
                                    }
                                }
                        }
                    }
                    .padding(16)
                }
                .background(Khayt.ground)
            }
        }
    }
}

/// One spool, face on.
struct SpoolCard: View {
    let spool: Spool
    let shop: Shop
    let low: Bool
    var selected = false

    private var colour: Color? {
        Swatch.rgb(fromHex: spool.color).map { Color(red: $0.r, green: $0.g, blue: $0.b) }
    }

    var body: some View {
        VStack(spacing: 8) {
            face
            VStack(spacing: 2) {
                Text(spool.material.isEmpty ? "—" : spool.material)
                    .font(.callout.weight(.medium)).lineLimit(1)
                // The shop's own name for the colour, which is what it is
                // called out loud. Absent for a spool nobody has named.
                if let variant = spool.colourVariant, !variant.isEmpty {
                    Text(variant).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Text(spool.weight.map { "\(Int($0)) \(shop.words.callIt("common.grams"))" } ?? "—")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(low ? Khayt.attention : .primary)
                if low {
                    // The word, not only a colour: a shop reading this at a
                    // glance in a bright workshop should not have to know that
                    // amber means anything.
                    Chip(text: shop.words.callIt("cons.low"), tint: Khayt.attention)
                }
            }
            // Per kilo where it is KNOWN, the purchase price where it is not.
            //
            // A rate needs what the spool weighed when it arrived, and only
            // spools bought since `spool-edit.js` started recording that have
            // it. Dividing by what is left instead made the figure climb as the
            // roll emptied, which is why the old one was deleted rather than
            // fixed. An older spool shows what it cost — a fact — rather than a
            // rate worked out from the wrong number.
            if let perKilo = spool.costPerKilo {
                Text(Money.text(perKilo, shop.currency) + " / "
                     + shop.words.callIt("common.kg"))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            } else if let cost = spool.cost {
                Text(Money.text(cost, shop.currency))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        // The app's card rather than `.quinary`, which is a translucent grey:
        // over the new ground it read as a recess punched into the screen, so
        // six spools looked like six holes. A low one keeps its amber ring
        // instead of taking a rail — the content of this card is centred and a
        // bar down one edge of centred content reads as a stray mark.
        .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(Khayt.surface),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(low ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(Khayt.hairline),
                          lineWidth: low ? 1.5 : 1))
        .help(spool.material)
    }

    /// A spool seen face on: the filament, and the hole through the middle.
    ///
    /// Drawn rather than photographed, and drawn as a RING because that is the
    /// shape being looked for on a rack. A flat square of colour is a swatch; a
    /// ring is a spool, and the difference is what makes the shelf scannable.
    private var face: some View {
        ZStack {
            Circle()
                .fill(colour ?? Color(nsColor: .quaternaryLabelColor))
                .overlay(
                    // A hint of depth, so a black spool is not a black hole and
                    // a white one is not a gap in the page.
                    Circle().strokeBorder(.black.opacity(0.14), lineWidth: 1)
                )
            Circle().fill(.background).frame(width: 22, height: 22)
            Circle().strokeBorder(.black.opacity(0.10), lineWidth: 1)
                .frame(width: 22, height: 22)
            // A colour nobody recorded is a dashed outline, never a grey that
            // could be mistaken for grey filament.
            if colour == nil {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 72, height: 72)
    }
}

private struct Live: View {
    let machine: Machine
    let shop: Shop

    var body: some View {
        // A machine this app cannot ask says so. A card that silently shows
        // nothing looks broken, and a shop would go back to the other app
        // without knowing why.
        switch PrinterWatch.notWatched(machine) {
        case .noConnection:
            EmptyView()   // nothing is configured; there is nothing to report
        case .otherProtocol(let name):
            DetailSection(shop.words.callIt("mac.live")) {
                Text(shop.words.callIt("mac.not_polled", ["protocol": .string(name)]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case nil:
            DetailSection(shop.words.callIt("mac.live")) { reading }
        }
    }

    @ViewBuilder private var reading: some View {
        if let seen = shop.printers.readings[machine.id] {
            if let status = seen.status {
                printing(status)
            } else if let problem = seen.problem {
                // In the vocabulary of the person who has to fix it, not the
                // socket's. `explainPrinterHttp` exists for the same reason.
                Text(problem)
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(shop.words.callIt("mac.asking"))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func printing(_ status: KhaytEngine.PrinterStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(state(status.state)).font(.callout.weight(.semibold))
                Spacer()
                if let left = status.timeRemaining, left > 0 {
                    Text(shop.words.callIt("mac.eta") + " " + PrinterWatch.spell(left))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if isRunning(status.state) {
                ProgressView(value: Double(status.progress) / 100) {
                    HStack {
                        if !status.filename.isEmpty {
                            Text(status.filename).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(status.progress)%").monospacedDigit()
                    }
                    .font(.caption)
                }
                // WHICH SIGNAL the percentage came from, because bytes are not
                // work: on a relief whose detail is all in its upper layers,
                // file position read 0.7% when the job was 19% done. A shop
                // deciding whether to wait is owed that distinction.
                //
                // Only where there IS a distinction. Moonraker is the one
                // adapter that chooses between two signals; the others report a
                // percentage their own server computed, and captioning that
                // "by file position" would be a claim about somebody else's
                // firmware.
                if let source = status.progressSource {
                    Text(shop.words.callIt(source == "layers" ? "mac.by_layers" : "mac.by_bytes"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 14) {
                if let nozzle = status.tempNozzle {
                    Label(PrinterWatch.degrees(nozzle), systemImage: "thermometer.medium")
                        .help(shop.words.callIt("mac.nozzle_temp"))
                }
                if let bed = status.tempBed {
                    Label(PrinterWatch.degrees(bed), systemImage: "rectangle.fill")
                        .help(shop.words.callIt("mac.bed_temp"))
                }
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// Klipper's own words, in the shop's language where Khayt has one.
    private func state(_ raw: String) -> String {
        switch raw.lowercased() {
        case "printing": return shop.words.callIt("mach.live_printing")
        case "standby", "ready", "complete": return shop.words.callIt("mach.live_idle")
        case "paused": return shop.words.callIt("rec.paused")
        case "error": return shop.words.callIt("mach.live_error")
        default: return raw
        }
    }

    /// Is there a job on this machine — running or held part-way through?
    /// This is the question the progress bar asks, and a paused print still
    /// has a percentage worth showing.
    private func isRunning(_ raw: String) -> Bool {
        Self.isPrinting(raw) || raw.lowercased() == "paused"
    }

    /// Is it laying down plastic RIGHT NOW? A narrower question than the one
    /// above and a different answer for a paused machine, which is why they
    /// are two functions. Static because the card around this view asks it
    /// too, and one spelling of the state means one place to change when a
    /// protocol calls it something else.
    static func isPrinting(_ raw: String) -> Bool { raw.lowercased() == "printing" }

}
