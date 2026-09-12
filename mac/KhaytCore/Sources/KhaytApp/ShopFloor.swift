import SwiftUI
import KhaytCore

/// The machines.
///
/// A card each rather than a table: a shop has a handful of printers, not four
/// hundred, and what you want from a machine — its bed, its nozzle, how many
/// colours — does not line up into columns worth scanning.
struct Machines: View {
    let shop: Shop

    // `alignment: .top` AND `fills: true` on the card, and they are two halves
    // of one thing. A `GridItem` with no alignment centres its cell in the row,
    // so a short card floated in the middle of the gap — the Roland sat a
    // hundred and eighty points below its neighbours and read as a card that
    // had come loose. Top alignment moved it up; it was still short.
    //
    // These cards are not naturally the same height and cannot be made so: a
    // laser cutter has no nozzle, no extruder and no colour count, so its card
    // has three fewer lines in it and nothing should be invented to pad them
    // out. What is wrong is not that one machine has less to say — it is that
    // the BOX around it was drawn to fit. So the surface fills the row and the
    // contents stay at the top, which is four boxes of one size holding four
    // different amounts of information.
    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16, alignment: .top)]

    /// Recomputed when the printers say something new, and once a minute
    /// regardless — the now-line and every gap move with the clock, and a band
    /// five minutes stale is wrong in the one place it must not be.
    @State private var band: KhaytEngine.MachineBand?
    /// Whether the shop can take another job, and when it would start. Here
    /// rather than buried in the reports because that is a decision made at the
    /// machines, usually with somebody on the phone.
    @State private var load: KhaytEngine.Capacity?
    /// Which machine scraps the most of what it prints. Here rather than in the
    /// reports because it is a fact about a machine, and this is the screen a
    /// shop is on when it is deciding what to do about one.
    @State private var scrap: KhaytEngine.MachineReliability?
    @State private var minute = 0
    /// The tallest card on the floor, which every other one is drawn to. See
    /// `CardHeight` — a `LazyVGrid` sizes each ROW on its own, so without this
    /// five printers came out as two tidy rows of two different heights.
    @State private var tallest: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Above the cards, because it answers the question the shop
                // came to this screen with. The cards answer "what is this
                // machine", which is the second question and the rarer one.
                if let band, !shop.machines.isEmpty {
                    MachineBandView(shop: shop, band: band)
                }
                // ── AND WHAT TO PUT ON THE IDLE ONES ──────────────────────
                //
                // FIRST, above the band. The band says what is running; this
                // says what should be. A shop standing here with a machine
                // finishing is asking this question and nothing answered it.
                if !shop.machines.isEmpty {
                    NextUp(shop: shop)
                }
                // A shop that has just plugged a printer in does not know its
                // address, and the number on the printer's own screen is the
                // one thing nobody wants to copy by hand across the room.
                HStack {
                    Button {
                        shop.findingPrinters = true
                    } label: {
                        Label(shop.words.callIt("mac.find_printers"),
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(!shop.canMoveJobs)
                    Spacer()
                }
                // ── AND WHETHER THERE IS ROOM FOR ANOTHER ─────────────────
                //
                // The band says what is running now; this says what is queued
                // behind it and when it clears. A shop asked "can you do this
                // by Thursday" is asking exactly this, and the answer lived
                // nowhere in this app.
                if !shop.machines.isEmpty {
                    CapacityCard(shop: shop, report: load)
                        .card(rail: load?.totals.overbooked == true ? Khayt.late : Khayt.cyan,
                              padding: 14)
                    // Capacity says whether a machine is busy; this says
                    // whether being busy is worth it. The pair is the case for
                    // servicing one printer and selling another.
                    MachineReliabilityCard(shop: shop, report: scrap)
                        .card(rail: (scrap?.totals.scrapRate ?? 0) >= 0.05
                                    ? Khayt.attention : Khayt.cyan,
                              padding: 14)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(shop.machines) { machine in
                        Card(machine: machine, wear: shop.wear[machine.id], shop: shop)
                            .atCardHeight(tallest)
                    }
                }
                .equalCardHeights($tallest)
            }
            .padding(Metric.screen)
        }
        .task(id: "\(shop.bandSignature)#\(minute)") {
            band = await shop.machineBand()
            load = await shop.capacity()
            scrap = await shop.machineReliability()
            // Same signature: the dispatcher's answer is a function of the
            // queue and what the printers just said, so it goes stale at
            // exactly the moment the band does.
            await shop.planDispatch()
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
    /// The stills, refetched on their own timer — see `Camera`.
    @Environment(Camera.self) private var camera
    let machine: Machine
    let wear: NozzleWear?
    let shop: Shop
    @State private var upkeep: KhaytEngine.MaintenanceCard?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            card
            // ── A PRINTER THAT CHANGED ADDRESS ────────────────────────────
            //
            // Only for a machine that has actually gone quiet — the same three
            // failed polls the badge above already calls offline. "Offline" is
            // also what Khayt says when a printer is switched off, and the two
            // have completely different fixes, so this offers the one that
            // applies to a moved lease.
            if shop.looksUnreachable(machine.id) { relocateRow }
        }
        .contextMenu {
                if shop.canMoveJobs {
                    Button(shop.words.callIt("mach.edit")) { shop.editingMachine = machine }
                    // Only where there is a history to read. Klipper keeps one;
                    // the other six protocols do not expose one Khayt can read,
                    // and a menu item that always answers "not this printer" is
                    // an item that teaches people to ignore the menu.
                    //
                    // This asked `notWatched == nil`, which is true for all
                    // THREE protocols this app speaks — so it offered the item
                    // for a Prusa and handed back a 404 from Moonraker's path.
                    // The predicate now says what the comment always said.
                    if PrinterWatch.keepsHistory(machine) {
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

    /// The repair, offered only when this machine has gone quiet.
    ///
    /// Two shapes, because the rule draws a line the screen must not blur: a
    /// MAC or a serial is identity — neither moves with a DHCP lease — and may
    /// be applied on one confirmation. A model match is "strong, and still a
    /// guess", so it is proposed and says so.
    @ViewBuilder private var relocateRow: some View {
        let move = shop.relocations.first { $0.machineId == machine.id }
        VStack(alignment: .leading, spacing: 6) {
            if let move {
                Text(shop.words.callIt("mac.moved_here", ["host": .string(move.to)]))
                    .font(.callout).foregroundStyle(.primary)
                Text(move.why)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !move.isIdentity {
                    Text(shop.words.callIt("mac.moved_maybe"))
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(shop.words.callIt("mac.moved_apply")) {
                    Task { await shop.applyRelocation(move) }
                }
                .controlSize(.small)
                .disabled(!shop.canMoveJobs)
            } else {
                Button(shop.words.callIt(shop.lookingForMoved ? "mac.moved_looking"
                                                              : "mac.moved_find")) {
                    Task { await shop.findMovedPrinters() }
                }
                .controlSize(.small)
                .disabled(shop.lookingForMoved)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── THE CAMERA, FIRST ─────────────────────────────────────────
            //
            // Above the name rather than tucked under the details: a shop
            // glancing at this screen is asking "is it still going and does the
            // plate look right", and the answer is the picture. Only where
            // there is one — a placeholder on every machine would make a screen
            // mostly grey rectangles.
            if machine.hasCamera {
                CameraTile(frame: camera.frames[machine.id] ?? .none, webcam: machine.webcam,
                           words: shop.words)
            }
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

            // What this machine is due for. Only where the shop has set tasks
            // up: a permanent "no tasks" heading on every printer would be
            // noise on the screen a shop looks at most.
            if let upkeep, !upkeep.tasks.isEmpty {
                DetailSection(shop.words.callIt("maint.recurring"),
                              accent: Self.worst(upkeep.tasks)) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(upkeep.tasks) { task in
                            Upkeep(task: task, machine: machine, shop: shop)
                        }
                    }
                }
            }
        }
        .task(id: upkeepInputs) { upkeep = await shop.maintenance(for: machine) }
        .card(rail: running ? Khayt.hot : nil, padding: 14, fills: true)
    }

    private var upkeepInputs: String { shop.maintenanceSignature(for: machine) }

    /// The most urgent status among the tasks, as a colour — or nil when
    /// nothing is asking for attention, so an up-to-date machine is not tinted
    /// for being fine.
    static func worst(_ tasks: [KhaytEngine.MaintenanceCard.Task]) -> Color? {
        if tasks.contains(where: { $0.status == "overdue" }) { return Khayt.late }
        if tasks.contains(where: { $0.status == "due" }) { return Khayt.attention }
        if tasks.contains(where: { $0.status == "warning" }) { return Khayt.note }
        return nil
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

/// One recurring maintenance task, on a machine card.
///
/// The status word and the remaining figure say different things and both
/// earn their place: "due" is what to act on, and "60h ago" is what ranks
/// three overdue printers against each other when there is time to service
/// only one of them.
struct Upkeep: View {
    let task: KhaytEngine.MaintenanceCard.Task
    let machine: Machine
    let shop: Shop
    @State private var working = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name.isEmpty ? shop.words.callIt("mac.unnamed") : task.name)
                    .font(.callout)
                    .foregroundStyle(task.name.isEmpty ? AnyShapeStyle(.secondary)
                                                       : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if let every {
                    Text("\(shop.words.callIt("maint.every")) \(every)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(shop.words.callIt("maint.status_" + task.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colour)
                if let left {
                    Text(left).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            Button(shop.words.callIt("maint.mark_done")) {
                working = true
                Task {
                    await shop.markMaintenanceDone(task.id, on: machine)
                    working = false
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            // A sample book is not the shop's to write to.
            .disabled(working || !shop.canMoveJobs)
        }
    }

    /// Amber and red mean the same here as everywhere else in Khayt, and an
    /// up-to-date task is not coloured for being fine.
    private var colour: Color {
        switch task.status {
        case "overdue": Khayt.late
        case "due":     Khayt.attention
        case "warning": Khayt.note
        default:        .secondary
        }
    }

    /// The interval, in whichever clock drives the task. Both when both do —
    /// a task set to "every 100 hours or 30 days" is due on whichever comes
    /// first, and showing one of them would misstate when that is.
    private var every: String? {
        var parts: [String] = []
        if let h = task.intervalHours { parts.append(Self.amount(h, shop, "common.hours_short")) }
        if let d = task.intervalDays { parts.append(Self.amount(d, shop, "common.days")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How long is left — negative once it is overdue, which is the figure
    /// that ranks three late printers against each other.
    ///
    /// The sign is left on rather than turned into a word. There is no locale
    /// key for "ago", and inventing one would mean nine translations to say
    /// what a minus sign already says; `formatted` places the sign correctly in
    /// Arabic, which a hand-built "-" prefix would not.
    private var left: String? {
        if let h = task.hoursRemaining { return Self.amount(h, shop, "common.hours_short") }
        if let d = task.daysRemaining { return Self.amount(d, shop, "common.days") }
        return nil
    }

    private static func amount(_ v: Double, _ shop: Shop, _ unit: String) -> String {
        let n = v.rounded().formatted(.number.precision(.fractionLength(0)))
        return "\(n) \(shop.words.callIt(unit))"
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
    @State private var needs: [KhaytEngine.ConsumableNeed] = []
    /// The tallest card on the shelf — see `CardHeight`. A spool carrying
    /// "needs drying" and "empty in 14 days" is two lines taller than one that
    /// is simply full, and nine of them came out as two rows of two heights.
    @State private var tallest: CGFloat = 0
    /// What the shelf costs, and whether that has moved. Here rather than in
    /// the reports because it is a fact about the shelf, and this is the screen
    /// a shop is on when it is deciding what to reorder.
    @State private var prices: KhaytEngine.MaterialCost?

    /// Top-aligned for the reason `MachineFloor` gives: an unaligned `GridItem` centres.
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14, alignment: .top)]

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
            // The empty states are about the WHOLE shelf, not the filament on
            // it. Gating them on spools alone hid the consumables list entirely
            // from a shop that keeps glue and bags but buys filament as it goes.
            if shop.spools.isEmpty && needs.isEmpty {
                EmptyHere(title: shop.words.callIt("mac.no_filament"), mark: .filament)
            } else if shown.isEmpty && needs.isEmpty {
                NothingMatched(shop: shop, mark: .filament)
            } else {
                ScrollView {
                    // What is about to run out that is NOT filament. Above the
                    // spools because it is the thing a shop cannot see by
                    // looking at the rack, and only when nothing is being
                    // searched for — the search box filters spools, so a full
                    // consumables list beside three filtered cards describes a
                    // different set from the one on screen.
                    if !needs.isEmpty, shop.search.trimmingCharacters(in: .whitespaces).isEmpty {
                        ConsumablesCard(needs: needs, shop: shop)
                            .card(rail: needs.contains(where: \.low) ? Khayt.attention : nil,
                                  padding: 14)
                            .padding(.bottom, 14)
                    }
                    // ── WHAT IT COSTS, ABOVE WHAT IS ON IT ────────────────
                    //
                    // The cards below say what the shop HAS. This says what it
                    // is paying, and whether that has moved — which is the
                    // question a shop has while looking at a shelf it is about
                    // to reorder from. Only when nothing is being searched for:
                    // a price summary of the whole shelf above three filtered
                    // cards describes a different set from the one on screen.
                    if !shop.spools.isEmpty,
                       shop.search.trimmingCharacters(in: .whitespaces).isEmpty {
                        MaterialCostCard(shop: shop, report: prices)
                            .card(rail: Khayt.cyan, padding: 14)
                            .padding(.bottom, 14)
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shown) { spool in
                            SpoolCard(spool: spool, shop: shop,
                                      low: shop.lowSpools[spool.id] ?? false,
                                      runway: shop.spoolRunway[spool.id],
                                      dryness: shop.spoolDryness[spool.id],
                                      selected: selection == spool.id)
                                .atCardHeight(tallest)
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
                    .equalCardHeights($tallest)
                    .padding(Metric.screen)
                }
                .background(Khayt.ground)
            }
        }
        // Recomputed when the shelf changes. A price is a fact about what was
        // bought, so it moves only when a spool is added or edited.
        .task(id: shop.spools.count) {
            prices = await shop.materialCost()
        }
        // The other shelf moves for a second reason: the usage rate is measured
        // over a trailing window, so what is about to run out changes as jobs
        // finish even when nobody has touched the stock.
        .task(id: shop.consumableSignature) {
            needs = await shop.consumableNeeds()
        }
    }
}

/// What is about to run out that is not filament.
///
/// Glue, IPA, bags, nozzles. A shop can see its filament by looking at the
/// rack; it cannot see that it is two days off running out of mailing bags,
/// and that stops production exactly the same way.
///
/// Every quantity is in the item's own unit. There is no grams figure here on
/// purpose — naming one grams is how "4 boxes" becomes "4 g" on a supplier's
/// order form.
struct ConsumablesCard: View {
    let needs: [KhaytEngine.ConsumableNeed]
    let shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(shop.words.callIt("cons.title")).font(.headline)
                Spacer()
                // How many of them are already out or below their minimum, as
                // against merely forecast to be. The two are different jobs:
                // one is a trip to the shop today.
                let low = needs.filter(\.low).count
                if low > 0 {
                    Text("\(low) \(shop.words.callIt("cons.low"))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Khayt.attention)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(needs) { Need(need: $0, shop: shop) }
            }
        }
    }

    private struct Need: View {
        let need: KhaytEngine.ConsumableNeed
        let shop: Shop

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(need.label.isEmpty ? shop.words.callIt("mac.unnamed") : need.label)
                        .font(.callout)
                        .foregroundStyle(need.label.isEmpty ? AnyShapeStyle(.secondary)
                                                            : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Text(stockLine).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    if need.low {
                        Text(shop.words.callIt("cons.low"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Khayt.attention)
                    } else if let cover {
                        Text(cover).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    // What to buy, where the rule was willing to commit to a
                    // figure. It refuses when there is no rate and no minimum,
                    // and an invented number there lands on a purchase order.
                    if need.suggestQty > 0 {
                        Text("\(shop.words.callIt("reorder.suggest")) \(Self.qty(need.suggestQty)) \(need.unit)")
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
        }

        private var stockLine: String {
            "\(shop.words.callIt("reorder.in_stock")): \(Self.qty(need.stock)) \(need.unit)"
        }

        /// Days of cover, where there is a forecast at all. Nil means nothing is
        /// consuming this — which is not the same as none left, and must not be
        /// drawn as "0 days".
        private var cover: String? {
            guard let days = need.daysLeft else { return nil }
            return "\(Self.qty(days)) \(shop.words.callIt("common.days"))"
        }

        /// Whole units where they are whole. A shop counts bags and gloves, and
        /// "6.0 each" reads like a measurement of something that is not.
        static func qty(_ v: Double) -> String {
            let whole = v.rounded()
            return abs(v - whole) < 0.05
                ? whole.formatted(.number.precision(.fractionLength(0)))
                : v.formatted(.number.precision(.fractionLength(1)))
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
        // Measured before the frame below, so this is the card's own natural
        // height — the number the shelf needs to find its tallest. This card
        // builds its own surface rather than going through `.card()`, so it
        // carries the probe itself; see `CardHeight`.
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: CardHeight.self, value: geo.size.height)
            }
        }
        // Same as the machine cards: the shelf drew five spools in one row with
        // three different bottom edges, because a spool carrying "needs drying"
        // and "empty in 14 days" is two lines taller than one that is simply
        // full. The surface fills the height it is given; the contents stay at
        // the top.
        .frame(maxHeight: .infinity, alignment: .top)
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

    /// WHAT THIS ITEM IS, drawn as the thing it is.
    ///
    /// Every item on the shelf was a spool. A 500 ml bottle of resin was a
    /// spool, a stack of plywood was a spool, and the only thing that said
    /// otherwise was the unit after the number — "340 ml" under a picture of a
    /// reel of filament. The shelf is read by SHAPE and COLOUR before anything
    /// is read as words, which is the whole argument for drawing these at all,
    /// and it was telling the eye the wrong thing about a third of the sample.
    ///
    /// `lib/inventory-units.js` already knows: `mass` is filament, `volume` is
    /// a liquid, `count` is sheet goods. That judgement is not repeated here —
    /// it is asked, and `ItemFace` fails a test if a measure is ever added
    /// without a shape to draw it as.
    ///
    /// All three carry the same two facts the spool always did: what colour it
    /// is, and how much is left. A bottle fills from the bottom, a stack has
    /// fewer sheets in it. Drawing the object but not its state would have been
    /// half the job — that was the bug the wound spool fixed, and it would have
    /// come straight back for the other two.
    @ViewBuilder private var face: some View {
        switch ItemFace.of(measure: unit?.measure) {
        case .bottle: bottle
        case .sheets: sheets
        case .spool:  spoolFace
        // A unit a NEWER Khayt wrote and this build has not learned. No
        // picture, rather than a spool that would state something false about
        // it — the row keeps its name, its quantity and its colour, and a shelf
        // that hides stock it cannot illustrate is worse than one that
        // illustrates only what it understands.
        case nil:     Color.clear.frame(width: 72, height: 72)
        }
    }

    /// A bottle of resin, seen face on and filled to what is left.
    ///
    /// The neck and cap are what make it a bottle rather than a rounded
    /// rectangle — a plain block filled to 68% is a battery meter, and the
    /// shape has to be recognisable before the level means anything.
    private var bottle: some View {
        let bodyW = 40.0, bodyH = 48.0
        let level = spool.fill ?? 1
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return VStack(spacing: 0) {
            // The cap, then the neck. Bare, never coloured: the resin is in the
            // bottle, and colouring the cap would put it outside.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Khayt.bareSpool)
                .frame(width: 19, height: 6)
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Khayt.drawnEdge, lineWidth: 1))
            Rectangle()
                .fill(Khayt.bareSpool)
                .frame(width: 13, height: 8)
                .overlay(Rectangle().strokeBorder(Khayt.drawnEdge, lineWidth: 1))
            shape
                .fill(Khayt.bareSpool)
                .frame(width: bodyW, height: bodyH)
                // FROM THE BOTTOM, which is where a liquid sits. Clipped to the
                // bottle's own shape afterwards so the fill takes the rounded
                // corners rather than squaring them off.
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(colour ?? Color(nsColor: .quaternaryLabelColor))
                        .frame(height: bodyH * level)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Khayt.drawnEdge, lineWidth: 1))
                // A colour nobody recorded is a dashed outline, never a grey
                // that could be mistaken for grey resin. Same rule as the spool.
                .overlay(alignment: .bottom) {
                    if colour == nil {
                        Rectangle()
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .foregroundStyle(.tertiary)
                            .frame(height: bodyH * level)
                    }
                }
        }
        .frame(width: 72, height: 72)
    }

    /// Sheet goods, seen edge on: one drawn sheet per sheet on the rack.
    ///
    /// COUNTED RATHER THAN SCALED, because this is the one unit whose measure
    /// is literally `count` — six sheets of ply is six things you can see from
    /// across the room, and a bar filled to 60% would be a worse picture of it
    /// than the thing itself. Two sheets left is two lines, and that is the
    /// moment `inventory-units.js` calls low.
    ///
    /// Capped at eight, above which the stack stops growing and the figure
    /// underneath carries the number. A rack of forty sheets drawn to scale is
    /// a solid block, which says less than eight lines do.
    private var sheets: some View {
        let count = min(8, max(1, Int((spool.weight ?? 1).rounded())))
        let sheetH = 5.0, gap = 2.0, width = 52.0
        return VStack(spacing: gap) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(colour ?? Color(nsColor: .quaternaryLabelColor))
                    .frame(width: width, height: sheetH)
                    .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .strokeBorder(colour == nil ? AnyShapeStyle(.tertiary)
                                                    : AnyShapeStyle(Khayt.drawnEdge),
                                      lineWidth: 1))
            }
        }
        .frame(width: 72, height: 72, alignment: .bottom)
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
    private var spoolFace: some View {
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

    /// Pause, resume, cancel — and dropping one object from the plate.
    ///
    /// THE MAC APP COULD WATCH SEVEN PROTOCOLS AND TOUCH NONE OF THEM. It knew
    /// a print was failing, it knew which machine, and stopping it meant
    /// walking to the printer or opening the other app.
    ///
    /// Only while something is actually running: a row of dead buttons under an
    /// idle printer is four things that cannot be pressed, every card, all day.
    @ViewBuilder private func controls(_ status: KhaytEngine.PrinterStatus) -> some View {
        let busy = shop.printerBusy.contains(machine.id)
        HStack(spacing: 8) {
            if isPaused(status.state) {
                Button(shop.words.callIt("mac.printer_resume")) {
                    Task { await shop.tell(machine, .resume) }
                }
            } else {
                Button(shop.words.callIt("mac.printer_pause")) {
                    Task { await shop.tell(machine, .pause) }
                }
            }
            // ASKS FIRST. Cancelling throws away however many hours are already
            // in the plate and no printer asks twice. Pause and resume are each
            // other's undo and go straight through.
            Button(shop.words.callIt("mac.printer_cancel")) { shop.confirmingCancel = machine }
                .foregroundStyle(Khayt.late)
            if machine.printerApi?.type == "moonraker" {
                Spacer()
                Button(shop.words.callIt("mac.drop_object") + "\u{2026}") {
                    shop.droppingFrom = machine
                }
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(busy || !shop.canMoveJobs)

        if let problem = shop.printerProblem[machine.id] {
            // The printer's refusal in the vocabulary of somebody who has to
            // act on it — "Bambu requires Bambu Connect for remote job control"
            // is a sentence, not a status code.
            Text(problem)
                .font(.caption).foregroundStyle(Khayt.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isPaused(_ state: String) -> Bool {
        ["paused", "pausing"].contains(state.lowercased())
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
            if isRunning(status.state) || isPaused(status.state) {
                controls(status)
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
