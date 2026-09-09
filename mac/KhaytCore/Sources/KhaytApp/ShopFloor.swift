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

    /// Recomputed when the printers say something new, and once a minute
    /// regardless — the now-line and every gap move with the clock, and a band
    /// five minutes stale is wrong in the one place it must not be.
    @State private var band: KhaytEngine.MachineBand?
    @State private var minute = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Above the cards, because it answers the question the shop
                // came to this screen with. The cards answer "what is this
                // machine", which is the second question and the rarer one.
                if let band, !shop.machines.isEmpty {
                    MachineBandView(shop: shop, band: band)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(shop.machines) { machine in
                        Card(machine: machine, wear: shop.wear[machine.id], shop: shop)
                    }
                }
            }
            .padding(Metric.screen)
        }
        .task(id: "\(shop.bandSignature)#\(minute)") {
            band = await shop.machineBand()
        }
        .task {
            // Not a display timer: this drives an engine call, so it ticks at
            // the resolution the band is drawn to and no faster.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                minute &+= 1
            }
        }
        .background(Khayt.ground)
        .overlay {
            if shop.machines.isEmpty {
                EmptyHere(title: shop.words.callIt("mac.no_machines"), message: shop.words.callIt("mac.no_machines_hint"), mark: .machines)
            }
        }
        .toolbar {
            ToolbarItem {
                // Only where there is something to place. A button that always
                // opens a panel saying "nothing to assign" is a button that
                // teaches a shop to stop pressing it.
                Button(shop.words.callIt("sched.suggest_btn"),
                       systemImage: "wand.and.stars") {
                    shop.forgetSchedule()
                    shop.schedulingWork = true
                }
                .disabled(shop.schedulableRows.isEmpty || shop.machines.isEmpty)
            }
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

    /// What kind of machine this is. Nil only for the instant before the book
    /// has loaded, and `shows` treats that as a filament printer — which every
    /// machine in every book written before this existed genuinely is.
    private var kind: KhaytEngine.MachineKind? { shop.kind(of: machine) }
    private func shows(_ field: String) -> Bool { kind?.shows(field) ?? true }

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
                    // NOT WHEN IT IS THE NAME AGAIN. Most shops call a printer
                    // after its model, so "Snapmaker U1" sat under "Snapmaker
                    // U1" on two cards out of three — a caption that says
                    // nothing still costs a line and makes the row of cards
                    // ragged. It earns its place on the third: "Bambu X1C" is
                    // the shop's name for a Bambu Lab X1 Carbon.
                    if !machine.model.isEmpty, !machine.model.caseInsensitiveEquals(machine.name) {
                        Text(machine.model).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // Only when there is something under it. A section header with
            // nothing beneath it reads as a screen that failed to load.
            if hasSpecs {
            DetailSection(shop.words.callIt("mac.the_machine")) {
                // ── THE BED, DRAWN ────────────────────────────────────────
                //
                // "270 × 270 × 270 mm" is a fact a shop compares against the
                // next card by reading both and doing the arithmetic. Drawn
                // against the biggest bed on the floor it is compared by
                // looking, which is what somebody standing in front of the
                // bench actually wants to know.
                if let bed = machine.bedSize, let x = machine.bed?.x, let y = machine.bed?.y {
                    HStack(alignment: .center, spacing: 12) {
                        BedPlan(x: x, y: y, widest: shop.widestBed, deepest: shop.deepestBed)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shop.words.callIt("mac.bed"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(bed).font(.callout.weight(.semibold)).monospacedDigit()
                            // The dashed rectangle needs naming, or a small
                            // square inside a big one reads as a rendering
                            // fault rather than as a comparison.
                            Text(shop.words.callIt("mac.bed_against",
                                 ["w": .string("\(Int(shop.widestBed))"), "d": .string("\(Int(shop.deepestBed))")]))
                                .font(.caption2).foregroundStyle(.tertiary)
                                // It wrapped to one truncated line — "dashed:
                                // the largest bed…" says nothing at all.
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 2)
                }
                // ── ONLY WHAT THIS KIND OF MACHINE HAS ───────────────────
                //
                // A laser cutter has no nozzle, no extruder and no colour
                // count, and this screen gave it all three: the field was on
                // the record, so it was drawn. `lib/machine-kinds.js` says
                // which specs belong to which kind, and this asks it.
                if let d = machine.nozzleDiameter, shows("nozzleDiameter") {
                    DetailLine(shop.words.callIt("mac.nozzle"), "\(Money.figure(d)) mm")
                }
                if let n = machine.maxColors, shows("maxColors") {
                    DetailLine(shop.words.callIt("mac.colours"), "\(n)")
                }
                if let e = machine.extruderType, shows("extruderType") {
                    DetailLine(shop.words.callIt("mac.extruder"), e)
                }
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
                    // ── THE RING IS THE FIGURE ────────────────────────────
                    //
                    // This was a `ProgressView`, and a stock capsule has one
                    // flaw that matters here: it stops at full. A nozzle at 99%
                    // and a nozzle at 140% drew the same bar, and only the word
                    // beside it said which. `WearGauge` draws the overshoot
                    // outside the ring.
                    //
                    // The figure is still `lib/nozzle-wear.js`'s — it weights
                    // an abrasive kilo differently from a plain one, and this
                    // shows its answer rather than grams over threshold.
                    HStack(alignment: .center, spacing: 11) {
                        WearGauge(pct: wear.pct)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(wear.wear)) / \(Int(wear.threshold)) \(shop.words.callIt("common.grams"))")
                                .font(.callout).monospacedDigit()
                            if wear.over {
                                Text(shop.words.callIt("mac.nozzle_due"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Khayt.attention)
                            }
                        }
                        Spacer(minLength: 0)
                    }
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
                EmptyHere(title: shop.words.callIt("mac.no_filament"), mark: .filament)
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: shop.search)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shown) { spool in
                            SpoolCard(spool: spool, shop: shop,
                                      low: shop.lowSpools[spool.id] ?? false,
                                      runway: shop.spoolRunway[spool.id],
                                      dryness: shop.spoolDryness[spool.id],
                                      selected: selection == spool.id)
                                .onTapGesture { selection = spool.id }
                                .onTapGesture(count: 2) {
                                    if shop.canMoveJobs { shop.editingSpool = spool }
                                }
                                .contextMenu {
                                    // Labelling is not a write, so it does not
                                    // wait on `canMoveJobs` the way editing
                                    // does — a read-only book can still print
                                    // a sheet for the rack it is describing.
                                    Button(shop.words.callIt("mac.print_labels")) {
                                        Task { await shop.askForShelfLabels([spool.id]) }
                                    }
                                    Divider()
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
                    .padding(Metric.screen)
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
    /// How long this one has got, or nil when nothing has been printed from it
    /// in the window — an unknown future, which the card says nothing about
    /// rather than guessing at.
    var runway: KhaytEngine.Runway?
    /// Whether it has gone damp. Nil, and `unknown`, are the same silence: a
    /// spool nobody has recorded drying is not a spool that is wet.
    var dryness: KhaytEngine.Dryness?
    var selected = false

    /// Only for a spool with two months or less in it.
    ///
    /// A shelf that annotates every card annotates none of them: the line is
    /// there to be noticed, and a roll with a year left is not news. Nil is
    /// also the answer for a spool nothing has been printed from — see
    /// `Shop.spoolRunway` — and for one already at nought, which the weight
    /// above says better than a countdown to today would.
    private var endsSoon: Double? {
        guard let d = runway?.daysLeft, d <= 60 else { return nil }
        return d
    }

    private var colour: Color? {
        Swatch.rgb(fromHex: spool.color).map { Color(red: $0.r, green: $0.g, blue: $0.b) }
    }

    /// What this item is counted in. Nil for the instant before the book has
    /// loaded, and `Quantity.say` reads that as grams — which every item
    /// written before this existed genuinely is.
    private var unit: KhaytEngine.InventoryUnit? { shop.unit(of: spool) }

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
                // In the item's OWN unit. A bottle of resin said "500 g" and a
                // stack of ply said "6 g", because the only unit this screen
                // knew was the only unit anything could be recorded in.
                Text(spool.weight.map { Quantity.say($0, unit, shop.words) } ?? "—")
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
            // Per KILO for filament, per LITRE for resin, per SHEET for ply.
            // This was the one place the gram assumption was load bearing
            // rather than cosmetic: a 500 ml bottle at 180 came out as "360.00
            // / kg", which is a figure about a different quantity wearing the
            // wrong name.
            if let rate = unit?.rate {
                Text(Money.text(rate, shop.currency) + " / "
                     + shop.words.callIt(unit?.rateKey ?? "unit.per_kg"))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            } else if let cost = spool.cost {
                Text(Money.text(cost, shop.currency))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            // How long it has got. Amber only once it is inside a fortnight —
            // the colour is the app's "wants a person", and a spool with six
            // weeks in it does not.
            if let days = endsSoon {
                // DECIDED ON THE NUMBER THAT IS PRINTED, not the one behind it.
                // The ASA spool had 14.2 days, which rounds to "empty in 14
                // days" and failed a `<= 14` test — so the card said fourteen
                // in the colour that means "no hurry". A reader cannot see the
                // .2, and a figure that argues with its own colour is worse
                // than either alone.
                let shown = Int(days.rounded())
                Text(shown < 1
                     ? shop.words.callIt("mac.empty_now")
                     : shop.words.callIt("mac.empty_in") + " "
                       + shop.words.counting(shown, "mac.days_word"))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(shown <= 14 ? AnyShapeStyle(Khayt.attention)
                                                 : AnyShapeStyle(.tertiary))
            }
            // Damp filament prints badly, and the shelf is where somebody is
            // standing when they could do something about it. Only the two
            // states that are news: `good` is quiet and `unknown` — which is
            // most of a real shelf — says nothing at all, because a spool
            // nobody has recorded drying is not a spool that is wet.
            if let state = dryness?.state, state == "overdue" || state == "due" {
                Text(shop.words.callIt(state == "overdue" ? "mac.dry_overdue" : "mac.dry_due"))
                    .font(.caption2)
                    .foregroundStyle(state == "overdue" ? AnyShapeStyle(Khayt.attention)
                                                        : AnyShapeStyle(.tertiary))
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
    ///
    /// ── AND IT IS WOUND TO WHAT IS LEFT ───────────────────────────────────
    ///
    /// The picture used to be full on every card. A spool down to its last
    /// 120 g was drawn exactly like an untouched kilo, and a number underneath
    /// said otherwise — so the biggest, first thing the eye landed on was the
    /// one part of the card that was not true.
    ///
    /// Filament sits between the hub and the flange, and the wound diameter
    /// shrinks toward the hub as it goes. So that is what shrinks here: the
    /// flange stays, the colour winds down to the hub, and a nearly-empty spool
    /// LOOKS nearly empty from across the room. It is the same information the
    /// grams give, in the shape a shop already reads it in.
    ///
    /// A spool with no record of what it weighed new keeps the old full ring —
    /// see `Spool.fill`. Drawing a guess would put a wrong picture at the top of
    /// the card, which is worse than the honest one that only says what colour.
    private var face: some View {
        // Hub 22pt across on a 72pt face, so the filament winds between r=11 and
        // r=36. An empty spool is bare flange with the hub's ring on it.
        let outer = 36.0, hub = 11.0
        let wound = spool.fill.map { hub + (outer - hub) * $0 } ?? outer
        return ZStack {
            // The bare flange, showing wherever the filament no longer reaches.
            Circle().fill(Khayt.bareSpool)
            Circle().strokeBorder(Khayt.drawnEdge, lineWidth: 1)

            Circle()
                .fill(colour ?? Color(nsColor: .quaternaryLabelColor))
                .overlay(
                    // A hint of depth, so a black spool is not a black hole and
                    // a white one is not a gap in the page. Theme-aware, or it
                    // is only true of one of the two themes — see `drawnEdge`.
                    Circle().strokeBorder(Khayt.drawnEdge, lineWidth: 1)
                )
                .frame(width: wound * 2, height: wound * 2)

            Circle().fill(.background).frame(width: hub * 2, height: hub * 2)
            Circle().strokeBorder(Khayt.drawnEdge, lineWidth: 1)
                .frame(width: hub * 2, height: hub * 2)
            // A colour nobody recorded is a dashed outline, never a grey that
            // could be mistaken for grey filament.
            if colour == nil {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(.tertiary)
                    .frame(width: wound * 2, height: wound * 2)
            }
        }
        .frame(width: outer * 2, height: outer * 2)
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
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        if !status.filename.isEmpty {
                            Text(status.filename).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(status.progress)%").monospacedDigit()
                    }
                    .font(.caption)
                    // A BAR, BUT THE RIGHT ONE.
                    //
                    // What a printer is doing is laying layers, and how far
                    // through it is, is how many of them are down. So the
                    // progress is drawn as the stack itself, filling from the
                    // bed upward — the app's own subject, in the one place on
                    // any screen where the subject is literally what is being
                    // measured.
                    //
                    // The first attempt put this motif behind a dashboard
                    // tile's label and number, where at that size it read as
                    // skeleton-loading bars — a screen that had not finished
                    // drawing. Only the screenshot said so. Here it has room,
                    // it sits under its own caption, and it means something.
                    ZStack(alignment: .leading) {
                        LayerLinesShape()
                            .fill(Khayt.hot.opacity(0.16))
                        LayerLinesShape(progress: Double(status.progress) / 100)
                            .fill(Khayt.hot)
                    }
                    .frame(height: 26)
                    .accessibilityElement()
                    .accessibilityLabel("\(status.progress)%")
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
    static func isPrinting(_ raw: String) -> Bool { PrinterWatch.isPrinting(raw) }

}
