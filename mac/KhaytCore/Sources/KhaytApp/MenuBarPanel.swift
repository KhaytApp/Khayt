import SwiftUI
import AppKit
import KhaytCore

/// What the menu bar item shows when it is pulled down: ONE print large, the
/// rest of the floor small (design direction C, "hero card", Figma
/// Qqxg4imtKVgC3TfNGcRGOk page 11).
///
/// ── WHY ONE CARD IS LARGE ────────────────────────────────────────────────
///
/// The panel was a list of equal rows, and a list of equal rows asks to be
/// read. The question somebody opens it with is "how is the print doing and
/// when is the printer free", and that is about one machine: the one in a job
/// that finishes soonest (`FloorRead.hero`). It gets a ring big enough to read
/// from across a desk, the time said both ways, and the three things a person
/// does about a running print. Every other machine is one quiet row.
///
/// ── WHAT IT COSTS ────────────────────────────────────────────────────────
///
/// Nothing while it is closed: the status item builds this view on opening and
/// drops it on closing, so the clock below, the ring's easing and the pulse
/// exist only while somebody is looking. NO PRINTER IS ASKED ANYTHING HERE.
/// The figures are the poller's last readings (`FloorRead.lines`); between two
/// of them the time left counts down from the last one (`FloorRead.leftNow`)
/// and says "about" once that reading is old.
///
/// Not private: the snapshot runner renders it through `ImageRenderer`, because
/// a popover is not a window and the window shot cannot see it.
struct FloorPanel: View {
    let shop: Shop
    /// The job each print belongs to. Looked up when the panel opens (`.task`);
    /// handed in by the snapshot runner, which cannot wait for a task.
    @State var jobs: [String: Order] = [:]
    /// The clock the times are read against — fixed by the snapshot. Nil in
    /// the app, where the panel keeps its own while it is open.
    var now: Date? = nil
    /// Machines holding a finished print's green, and until when. Filled when
    /// a print finishes while the panel is open; handed in by the snapshot.
    @State var holds: [String: Date] = [:]
    /// The waiting jobs "Next up" is chosen from. Nil is the book's own; the
    /// snapshot hands in an empty list to photograph "Nothing queued".
    var queue: [Order]? = nil
    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 372
    /// More rows than this scroll, so a farm's panel still fits the screen.
    static let rowsBeforeScrolling = 7

    var body: some View {
        if let now {
            content(now)
        } else {
            // The panel's own clock, ten seconds a beat: the figures are
            // minutes, and a beat is enough for the countdown and for "about"
            // to appear. It stops with the view.
            TimelineView(.periodic(from: .now, by: 10)) { content($0.date) }
        }
    }

    @ViewBuilder private func content(_ now: Date) -> some View {
        let lines = FloorRead.lines(shop)
        let hero = FloorRead.hero(lines)
        let held = lines.filter { holds[$0.id] != nil && $0.isFinished }
        let rest = lines.filter { line in line.id != hero?.id && !held.contains { $0.id == line.id } }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shop.words.callIt("mac.mbh_title")).font(.headline)
                Text(verbatim: FloorRead.headline(lines, now: now, words: shop.words))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .accessibilityElement(children: .combine)

            // Retired printers are not on the floor any more (`machinesInUse`).
            if lines.isEmpty {
                Divider()
                Text(shop.words.callIt("mac.no_machines"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(14)
            } else {
                VStack(spacing: 8) {
                    if let hero {
                        HeroCard(line: hero, shop: shop, job: job(for: hero), now: now)
                    }
                    ForEach(held) { line in
                        FinishCard(line: line, shop: shop, job: job(for: line))
                    }
                    if hero == nil && held.isEmpty {
                        EmptyFloor(shop: shop, lines: lines, next: next(now))
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)

                if !rest.isEmpty {
                    Divider()
                    if rest.count > Self.rowsBeforeScrolling {
                        ScrollView { rows(rest, now: now) }.frame(height: 360)
                    } else {
                        rows(rest, now: now)
                    }
                }
            }

            Divider()

            // What a person would go to the app FOR, rather than a list of
            // everything the app can do.
            VStack(spacing: 1) {
                MenuLine(text: shop.words.callIt("mac.mb_open_khayt"), key: "⌘0") {
                    openWindow(id: "shop")
                    NSApp.activate(ignoringOtherApps: true)
                }
                // Planning the floor is editing jobs; and nothing that opens a
                // sheet over the sign-in screen (alpha.62 re-check).
                if !shop.schedulableRows.isEmpty && !shop.workingMachines.isEmpty
                    && shop.lockAllows("orders", "edit") {
                    MenuLine(text: shop.words.callIt("sched.suggest_btn"), key: nil) {
                        openWindow(id: "shop")
                        NSApp.activate(ignoringOtherApps: true)
                        shop.shelf = .machines
                        shop.forgetSchedule()
                        shop.schedulingWork = true
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .frame(width: Self.width)
        .task {
            guard jobs.isEmpty else { return }
            jobs = await FloorRead.jobs(shop, lines: FloorRead.lines(shop))
        }
        // A print finished while the panel is open: its card holds green for a
        // few seconds (`FloorRead.justFinished`), then settles to a row.
        .onChange(of: lines) { old, new in
            let just = FloorRead.justFinished(previous: old, current: new, now: Date())
            if !just.isEmpty { holds.merge(just) { _, new in new } }
        }
        .task(id: holds) {
            guard let next = holds.values.min() else { return }
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            let now = Date()
            holds = holds.filter { $0.value > now }
        }
    }

    @ViewBuilder private func rows(_ lines: [FloorLine], now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(lines) { line in
                FleetRow(line: line, shop: shop, job: job(for: line), now: now) {
                    FloorStatus.shared.open(machine: line.id)
                }
                if line.id != lines.last?.id { Divider() }
            }
        }
    }

    /// The job a line belongs to: the one looked up for a print in progress,
    /// or the one the finish seam named for a print that has ended. Nothing
    /// for somebody who may not see jobs (`FloorRead.jobs` asks the same).
    private func job(for line: FloorLine) -> Order? {
        if let job = jobs[line.id] { return job }
        guard line.isFinished, shop.goToKinds.contains(.job),
              let id = shop.lastPrintEnded[line.id]?.orderId else { return nil }
        return shop.orders.first { $0.id == id }
    }

    private func next(_ now: Date) -> FloorRead.NextJob? {
        guard shop.goToKinds.contains(.job) else { return nil }
        return FloorRead.nextUp(queue ?? shop.orders,
                                proposed: shop.dispatch?.proposals.map(\.orderId) ?? [], today: now)
    }

    /// One line saying where the shop stands, chosen so it is never a zero.
    /// What VoiceOver reads for the status item itself (`FloorStatus.refresh`).
    static func summary(_ shop: Shop) -> String {
        let printing = shop.printingNow
        if printing == 0 { return shop.words.callIt("mac.nothing_printing") }
        guard let soonest = shop.soonestFinish else {
            return shop.words.counting(printing, "mac.printing_count")
        }
        return shop.words.counting(printing, "mac.printing_count")
             + " · " + shop.words.callIt("mac.next_free") + " " + PrinterWatch.spell(soonest, shop.words)
    }
}

/// How a machine's state is drawn: one colour by meaning from the shared
/// palette, and ALWAYS its word beside it.
///
/// AMBER IS NEVER TEXT. `Khayt.thread` on white is about 2:1, so it is a ring
/// and a wash and nothing else; every word and figure beside it is ordinary
/// ink. The same holds for the other four: the colour is a dot or a ring, the
/// word is ink.
@MainActor
enum FloorLook {
    static func tint(_ line: FloorLine) -> Color {
        switch line.attention {
        case .runout, .fault: return Khayt.late
        case .paused: return Khayt.hold
        case .bedNotClear: return Khayt.done
        case nil: break
        }
        if line.printing { return Khayt.thread }
        if line.finished { return Khayt.done }
        return Color(nsColor: .tertiaryLabelColor)
    }

    /// The word for a line that is not simply printing, or nil when it is.
    static func word(_ line: FloorLine, _ words: Words) -> String? {
        if let attention = line.attention, attention != .bedNotClear { return words.callIt(attention.wordKey) }
        if line.isFinished { return words.callIt("mac.mbh_finished") }
        if line.printing { return nil }
        return line.rank == .idle && line.quiet == nil ? words.callIt("mac.idle") : nil
    }

    static func wash(_ line: FloorLine) -> Color {
        line.printing && line.attention == nil ? Khayt.threadWash : tint(line).opacity(0.13)
    }

    /// The job's name as a person says it: the project, else the file the
    /// printer is running.
    static func jobName(_ job: Order?, _ line: FloorLine) -> String {
        if let job, !job.project.isEmpty { return job.project }
        return line.filename
    }
}

/// A wash behind a card. With Increase Contrast it is an outline instead: a
/// tinted fill is exactly the kind of low-contrast surface that setting is
/// switched on to be rid of.
private struct Wash: ViewModifier {
    let fill: Color
    let edge: Color
    var radius: CGFloat = 14
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: radius).strokeBorder(edge, lineWidth: 1.5)
            } else {
                RoundedRectangle(cornerRadius: radius).fill(fill)
            }
        }
    }
}

/// A state's word in ink, beside a dot of its colour.
private struct StatePill: View {
    let text: String
    let tint: Color
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(verbatim: text).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background {
            if contrast == .increased { Capsule().strokeBorder(tint, lineWidth: 1) }
            else { Capsule().fill(tint.opacity(0.15)) }
        }
        .fixedSize()
    }
}

/// The one print the panel is about.
private struct HeroCard: View {
    let line: FloorLine
    let shop: Shop
    let job: Order?
    let now: Date

    private var machine: Machine? { shop.machines.first { $0.id == line.id } }
    private var stopped: Bool { line.attention != nil }
    private var live: FloorRead.LeftNow? {
        guard line.printing, let left = line.left else { return nil }
        return FloorRead.leftNow(left: left, readAt: line.readAt, now: now)
    }

    var body: some View {
        let tint = FloorLook.tint(line)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        ProgressRing(value: Double(line.progress) / 100, tint: tint, size: 92, line: 9,
                                     pulses: line.printing && !stopped)
                        Text(verbatim: shop.words.callIt("mac.mbp_pct", ["pct": .string(shop.words.numeral(line.progress))]))
                            .font(.system(size: 26, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.7).lineLimit(1)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: line.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(verbatim: FloorLook.jobName(job, line).isEmpty ? line.name : FloorLook.jobName(job, line))
                            .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            .lineLimit(2).truncationMode(.middle)
                        if let customer {
                            Text(verbatim: customer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let word = FloorLook.word(line, shop.words), stopped {
                            StatePill(text: word, tint: tint).padding(.top, 2)
                        } else if let live {
                            // Said twice, the two ways people ask.
                            (Text(verbatim: FloorRead.leftPhrase(live, words: shop.words)).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                             + Text(verbatim: " · " + FloorRead.finishes(live.seconds, now: now, words: shop.words))
                                .foregroundStyle(.secondary))
                                .font(.callout).monospacedDigit()
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 9) {
                    // The model's picture when the job is linked to one in the
                    // library; otherwise the plate drawing `Thumbnail` falls
                    // back to. Never an empty grey box.
                    Thumbnail(source: job.flatMap { shop.modelThumbnail(for: $0) }, pixels: 128)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if let layer = line.layer, let total = line.totalLayers {
                        Text(verbatim: shop.words.callIt("mac.layer_of", [
                            "layer": .string(Figure.isolated(shop.words.numeral(layer))),
                            "total": .string(Figure.isolated(shop.words.numeral(total)))]))
                            .font(.callout).monospacedDigit().foregroundStyle(.primary).lineLimit(1)
                    }
                    if !line.loaded.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(line.loaded.prefix(6).enumerated()), id: \.offset) { _, hex in
                                Circle().fill(Self.colour(hex))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.75))
                                    .frame(width: 9, height: 9)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            // One sentence for VoiceOver, then the actions below as buttons.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FloorRead.spoken(line, job: FloorLook.jobName(job, line), now: now, words: shop.words))

            actions
        }
        .padding(14)
        .modifier(Wash(fill: FloorLook.wash(line), edge: tint))
        .task(id: machine?.printerApi?.type ?? "") {
            await shop.learnPrinterVerbs(machine?.printerApi?.type ?? "")
        }
    }

    /// The customer, only for somebody who may see customers, and never an
    /// erased one (`FloorRead.jobLine` keeps the same rule).
    private var customer: String? {
        guard let job, shop.goToKinds.contains(.customer), !job.clientErased, !job.client.isEmpty else { return nil }
        return job.client
    }

    /// ── ONLY WHAT WORKS, AND THE ONE THAT RESOLVES IT FIRST ───────────────
    ///
    /// Camera only when this printer has one. Pause or Resume only when its
    /// protocol can take it, through `Shop.printStep` and `Shop.tell` — the
    /// machine card's own offer, gate and press, not a second way to stop a
    /// printer. Open job whenever the book names the job (and it is looked up
    /// only for somebody who may see jobs).
    ///
    /// A running print's primary is Open job. A STOPPED one leads with what
    /// gets it going again: Resume for a pause or a runout, the machine's own
    /// card for a fault, where the printer's words and Cancel are.
    @ViewBuilder private var actions: some View {
        let step: Shop.PrintStep? = machine.flatMap { machine in
            line.printing || line.attention == .paused || line.attention == .runout
                ? shop.printStep(machine, paused: !line.printing) : nil
        }
        let camera = machine.map { $0.hasCamera && $0.inService } ?? false
        let resolves = stopped && step != nil
        HStack(spacing: 8) {
            if stopped {
                if let step, let machine {
                    Button(shop.words.callIt(step.wordKey)) { Task { await shop.tell(machine, step.verb) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!step.enabled)
                } else {
                    Button(shop.words.callIt("mac.mbh_open_machine")) { FloorStatus.shared.open(machine: line.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer(minLength: 0)
            if camera {
                // The picture is on the machine's card in the main window; the
                // panel does not start a second stream of stills.
                Button(shop.words.callIt("mac.camera")) { FloorStatus.shared.open(machine: line.id) }
                    .buttonStyle(.borderless)
            }
            if !stopped, let step, let machine {
                Button(shop.words.callIt(step.wordKey)) { Task { await shop.tell(machine, step.verb) } }
                    .buttonStyle(.bordered)
                    .disabled(!step.enabled)
            }
            if let job {
                if stopped {
                    Button(shop.words.callIt("mac.attn_go_job")) { FloorStatus.shared.open(job: job.id) }
                        .buttonStyle(.bordered)
                } else {
                    Button(shop.words.callIt("mac.attn_go_job")) { FloorStatus.shared.open(job: job.id) }
                        .buttonStyle(.borderedProminent)
                }
            } else if !stopped || resolves {
                // The book cannot say which job without guessing: the machine.
                Button(shop.words.callIt("mac.mbh_open_machine")) { FloorStatus.shared.open(machine: line.id) }
                    .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
    }

    static func colour(_ hex: String) -> Color {
        guard let (r, g, b) = CalculatorModel.rgb(hex) else { return Color(nsColor: .tertiaryLabelColor) }
        return Color(red: r, green: g, blue: b)
    }
}

/// A print that has just finished, for the few seconds it holds its green.
private struct FinishCard: View {
    let line: FloorLine
    let shop: Shop
    let job: Order?

    var body: some View {
        let name = FloorLook.jobName(job, line)
        HStack(spacing: 12) {
            ProgressRing(value: 1, tint: Khayt.done, size: 40, line: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name.isEmpty ? shop.words.callIt("mac.mbh_finished")
                                            : shop.words.callIt("mac.mbh_done_title", ["job": .string(Figure.isolated(name))]))
                    .font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(verbatim: line.name + " · " + shop.words.callIt("mac.mbh_finished"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .modifier(Wash(fill: Khayt.done.opacity(0.14), edge: Khayt.done))
        .accessibilityElement(children: .combine)
    }
}

/// Nothing is in a job: what could start, not just that nothing is.
private struct EmptyFloor: View {
    let shop: Shop
    let lines: [FloorLine]
    let next: FloorRead.NextJob?

    /// Every machine answered and has nothing on it. A machine that is not
    /// set up, not answering or still holding a finished print is not a free
    /// plate, and counting it as one would be a promise.
    private var allFree: Bool {
        lines.allSatisfy { $0.rank == .idle && $0.quiet == nil && !$0.isFinished }
    }

    var body: some View {
        VStack(spacing: 6) {
            PlateDrawing().frame(width: 132, height: 64).padding(.top, 6).padding(.bottom, 4)
            Text(verbatim: title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            if let next {
                Text(verbatim: FloorRead.nextUpLine(next, words: shop.words))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button(shop.words.callIt("mac.mbh_start_next")) { FloorStatus.shared.open(job: next.id) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .padding(.top, 6)
            } else {
                Text(shop.words.callIt("mac.mbh_nothing_queued"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var title: String {
        guard allFree else { return shop.words.callIt("mac.nothing_printing") }
        return lines.count == 1
            ? shop.words.callIt("mac.mbh_plate_free")
            : shop.words.callIt("mac.mbh_plates_free", ["n": .string(shop.words.numeral(lines.count))])
    }
}

/// An empty build plate with the thread above it, waiting.
private struct PlateDrawing: View {
    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Khayt.thread).frame(width: 2, height: 24)
            Ellipse().fill(Khayt.well)
                .overlay(Ellipse().strokeBorder(Color.primary.opacity(0.28),
                                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(height: 40)
        }
        .accessibilityHidden(true)
    }
}

/// One of the other machines: a small ring by state, its name, what it is
/// doing, and on the trailing side the percentage or the state's word.
private struct FleetRow: View {
    let line: FloorLine
    let shop: Shop
    let job: Order?
    let now: Date
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                ProgressRing(value: ringValue, tint: FloorLook.tint(line), size: 26, line: 3.5,
                             pulses: line.printing && line.attention == nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: line.name).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if !second.isEmpty {
                        Text(verbatim: second).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                trailing
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(hovered ? Color.accentColor.opacity(0.10) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FloorRead.spoken(line, job: FloorLook.jobName(job, line), now: now, words: shop.words))
        .accessibilityHint(shop.words.callIt("mac.mbp_open_machine", ["machine": .string(line.name)]))
        .accessibilityAddTraits(.isButton)
    }

    /// A finished plate is a closed ring; an idle one is the track alone.
    private var ringValue: Double {
        if line.isFinished { return 1 }
        return line.midPrint ? Double(line.progress) / 100 : 0
    }

    @ViewBuilder private var trailing: some View {
        if let word = FloorLook.word(line, shop.words) {
            StatePill(text: word, tint: FloorLook.tint(line))
        } else if line.printing {
            // Ordinary ink: the amber is the ring's, never a figure's.
            Text(verbatim: shop.words.callIt("mac.mbp_pct", ["pct": .string(shop.words.numeral(line.progress))]))
                .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
        }
    }

    /// "Museum replica: Kings · 3h 40m left", the job a stopped or finished
    /// print belongs to, "Free since 9:10 am", or why there is no print.
    private var second: String {
        let name = FloorLook.jobName(job, line)
        if line.printing {
            guard let left = line.left else { return name }
            let phrase = FloorRead.leftPhrase(FloorRead.leftNow(left: left, readAt: line.readAt, now: now),
                                              words: shop.words)
            return name.isEmpty ? phrase : Figure.isolated(name) + " · " + phrase
        }
        if line.midPrint || line.isFinished {
            if line.attention == .bedNotClear, name.isEmpty { return shop.words.callIt("mac.mbp_attn_bed") }
            return name
        }
        if line.attention == .fault { return name }
        if let quiet = line.quiet {
            // Why there is no print, rather than a blank that reads as broken:
            // the same sentences the front door's tiles use (`Shop.quiet`).
            if quiet == .notAnswering, let problem = shop.printers.readings[line.id]?.problem { return problem }
            return shop.words.callIt(quiet == .noProtocol ? "mac.cannot_ask" : quiet.wordKey)
        }
        if let ended = line.endedAt {
            return shop.words.callIt("mac.mbh_free_since",
                                     ["time": .string(shop.words.say(ended, .dateTime.hour().minute()))])
        }
        return ""
    }
}
