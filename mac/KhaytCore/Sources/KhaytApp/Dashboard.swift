import SwiftUI
import KhaytCore

/// The screen a shop opens on.
///
/// Every figure here comes from `lib/dashboard-facts.js` and `lib/kpi.js`,
/// bundled and run. Not one of them is arithmetic written in Swift — a margin
/// this app worked out for itself would be a second answer to a question the
/// shop's other app already answers, and the two would disagree in a way nobody
/// could see until an accountant did.
struct Dashboard: View {
    @Bindable var shop: Shop

    /// The ranges `renderer/analytics.js` offers, in its order.
    static let ranges: [(String, String)] = [
        ("month", "an.range.month"), ("last_month", "an.range.last_month"),
        ("quarter", "an.range.quarter"), ("year", "an.range.year"), ("all", "an.range.all"),
    ]



    /// What the shop is doing and what wants a person. The left column when
    /// there are two, and the top of the screen when there is one.
    @ViewBuilder private var theWork: some View {
        // ── THE FLOOR, FIRST AND DRAWN ────────────────────────────────────
        //
        // The dashboard opened on four stacked lists of words, and the first
        // question a shop has walking in is not a question about words: it is
        // "what is running". `RunningNow` below answers it — but only for the
        // machines that ARE running, so a floor with nothing on it drew
        // nothing at all, and a floor with one printer going said nothing
        // about the other four.
        //
        // This is every machine, always, one tile each, and the state is the
        // drawing rather than the caption.
        if let attention = shop.attention, !attention.items.isEmpty {
            // First, and above the figures. A shop that opens this app is
            // asking "is anything wrong" before it asks "how are we doing", and
            // a late job under a revenue tile is a late job nobody sees.
            NeedsAttention(items: attention.items, shop: shop)
        }
        if let facts = shop.facts {
            // The floor leads when nothing is wrong — which is most mornings.
            Work(facts: facts, shop: shop,
                 leads: (shop.attention?.items.isEmpty ?? true))
        }
        // What the machines are ACTUALLY doing, under the count of how many the
        // book thinks are busy. The tile above is the book's answer; this is
        // the printers'. A shop opening this app to ask "is it still going"
        // should not have to change screens.
        RunningNow(shop: shop)
        // What the queue is about to make late. UNDER the attention panel and
        // above the invoices: "this is already wrong" outranks "this is going
        // to be", which outranks "somebody owes us money".
        RunningOut(shop: shop)
        // And what went wrong while nobody was looking. A notification
        // dismissed while the shop was making coffee is a notification it never
        // had, so the alerts are on the screen as well.
        WentWrong(shop: shop)
        // Money to go after, which is a different question from "is anything
        // wrong" and belongs under it. Both lists are opt-in — the two switches
        // are in Settings → Operations — and the section is absent when neither
        // has anything.
        ToChase(shop: shop)
    }

    /// How the shop is doing. The right column when there are two.
    ///
    /// The split falls exactly where the code already had a seam: these three
    /// were the only sections inside `showsMoney`, so a shop that has turned
    /// the money off loses the whole column rather than half of each screen.
    @ViewBuilder private var theMoney: some View {
        MoneyTiles(shop: shop)
        Goal(shop: shop)
        // After the tiles, because the tiles answer "what is it now" and this
        // answers "is that good" — which is the second question, not the first.
        if let outlook = shop.outlook, outlook.method != "none" {
            Takings(outlook: outlook, shop: shop)
        }
    }

    /// The width at which the screen stops being a column and becomes two.
    ///
    /// Chosen so that each column is still wide enough to be worth having:
    /// below this a split would give the money side about 700 points, and five
    /// tiles across 700 is five tiles nobody can read. A 16-inch laptop
    /// (roughly 1470 points of pane) stays one column deliberately — it is not
    /// a big display, it is a full one.
    private static let twoColumnFrom: CGFloat = 1800

    var body: some View {
        GeometryReader { geo in
            // Money hidden means the right-hand column is empty, and two
            // columns with nothing in one of them is worse than one.
            let showsMoney = shop.facts?.showsMoney != false
            let twoUp = geo.size.width >= Self.twoColumnFrom && showsMoney
            let content = geo.size.width - Metric.screen * 2
            // 58/42. The work side carries the lists — a name at one end and
            // how late it is at the other — and needs the room; the money side
            // is tiles and one big figure, which do not.
            let leftW = (content - 24) * 0.58

            ScrollView {
                Group {
                    if twoUp {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 22) { theWork }
                                .frame(width: leftW, alignment: .leading)
                            VStack(alignment: .leading, spacing: 22) { theMoney }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            theWork
                            if showsMoney { theMoney }
                        }
                    }
                }
                .padding(Metric.screen)
                // ── ONE COLUMN, OR TWO ────────────────────────────────────
                //
                // These sections are lists with a name at one end and a figure
                // at the other, and across a whole wide window that put "Souq
                // stall sign" and "13 days late" fifteen hundred points apart —
                // two halves of one fact, too far apart to read as one. The
                // revenue card had the matching problem from the other side: a
                // figure at the left edge of an otherwise empty panel.
                //
                // A capped column fixes both and then wastes the display, which
                // is its own fault: at 2560 points the dashboard sat in a
                // column with an empty field beside it. So past a point the
                // screen stops being a column and becomes two, and the width a
                // desk display has is spent on showing MORE of the shop at once
                // rather than on stretching the same rows wider.
                //
                // Below that point the cap and the centring still apply, so a
                // laptop is unchanged.
                .frame(maxWidth: twoUp ? .infinity : 1280, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Khayt.ground)
            .overlay {
                if shop.facts == nil {
                    EmptyHere(title: shop.words.callIt("mac.no_figures"), message: shop.words.callIt("mac.no_figures_hint"))
                }
            }
        }
    }
}

/// Every machine on the floor, drawn, in one band across the top.
///
/// The layer stack IS the state: laid down and warm while a machine is
/// printing, ghosted while it is idle. A machine Khayt has no protocol for
/// gets its bed drawn instead — a progress bar for a laser cutter would be a
/// picture of something the machine does not do, and `lib/machine-kinds.js`
/// is where that is decided rather than here.
private struct FloorStrip: View {
    let shop: Shop

    var body: some View {
        if !shop.machines.isEmpty {
            Group {
                // ── AN HStack, NOT A LazyVGrid ────────────────────────────
                //
                // The first version used `LazyVGrid(.adaptive(minimum:
                // maximum:))`, and an adaptive grid inside this screen's
                // width-capped ScrollView is a sizing loop: the grid asks how
                // wide it may be, the answer depends on how many columns it
                // chose, and AppKit never settles. It rendered — the dashboard
                // photographed fine — and then hung the app on the NEXT heavy
                // screen, which is the part that made it hard to see.
                //
                // `StatStrip` in Surface.swift has solved this shape already:
                // one HStack, a rule between each pair, no grid. A shop has a
                // handful of machines, not forty, so there is nothing here a
                // grid was buying.
                HStack(spacing: 0) {
                    ForEach(Array(shop.machines.enumerated()), id: \.element.id) { index, machine in
                        if index > 0 {
                            Rectangle().fill(Khayt.layerLine)
                                .frame(width: 1).padding(.vertical, 6)
                        }
                        Tile(machine: machine, shop: shop)
                            .padding(.horizontal, 12)
                    }
                    // A shop with one printer got one tile the width of the
                    // window, and a layer stack sixteen hundred points wide
                    // reads as faint stripes rather than as a print. The
                    // tiles stay tile-sized and the row starts at the left.
                    Spacer(minLength: 0)
                }
                .card(padding: 12)
            }
        }
    }

    private struct Tile: View {
        let machine: Machine
        let shop: Shop
        @State private var hovering = false

        private var status: KhaytEngine.PrinterStatus? { shop.printers.readings[machine.id]?.status }
        private var printing: Bool { PrinterWatch.isPrinting(status?.state ?? "") }
        /// Can a machine of this KIND be asked anything at all?
        ///
        /// ── NOT THE SAME QUESTION AS "IS IT CONFIGURED" ───────────────────
        ///
        /// The first version asked `PrinterWatch.notWatched(machine)`, which
        /// answers "has somebody given this machine an address" — and the
        /// sample shop has given none of them one. So all five tiles said
        /// "Khayt cannot ask this machine", including three filament printers
        /// that Khayt speaks four protocols for.
        ///
        /// `lib/machine-kinds.js` answers the question actually being asked:
        /// a laser cutter and a UV flatbed have no protocol in this repo at
        /// all, and that is a fact about the KIND. A filament printer with no
        /// address is simply not set up yet, which is a different sentence and
        /// a fixable one.
        private var askable: Bool { shop.kind(of: machine)?.polled ?? true }
        /// Set up to be asked — an address, and a protocol Khayt speaks.
        private var connected: Bool { PrinterWatch.notWatched(machine) == nil }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(swatch)
                        .frame(width: 3, height: 15)
                    Text(machine.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                // ── AN EMPTY PROGRESS BAR READS AS A SCREEN STILL LOADING ──
                //
                // A machine with no address is not printing and never will be
                // until somebody sets it up, so `LayerProgress` drew its ghost
                // layers at zero: ragged LEFT-ALIGNED lines, which is exactly
                // what `Craft.swift` says reads as a paragraph rather than as a
                // printed object — "centre for art, align for a progress bar".
                // At zero it is not a bar, it is decoration, and on the front
                // door three of them sat under the words "No connection set up"
                // looking like a dashboard that had not finished drawing.
                //
                // A machine Khayt cannot see gets its BED instead: a real
                // drawing of the thing, at its real size against the biggest on
                // the floor. The two sentences stay different — one is not set
                // up yet and the other cannot be asked at all — because those
                // are different facts and only one of them is fixable.
                // ── AND AN IDLE MACHINE IS NOT PRINTING EITHER ─────────────
                //
                // The condition above used to be `!askable || !connected`,
                // which fixed the ghost layers for a machine Khayt cannot see
                // and left them drawn for one it CAN see that simply is not
                // printing. On the real shop's front door that is both
                // machines: two tiles of pale ragged lines under the word
                // "Idle", which is the loading-skeleton look this whole
                // comment was written to get rid of.
                //
                // The bar is only about a print IN PROGRESS. Whether Khayt can
                // reach the machine has nothing to do with it — an idle
                // printer has no progress to draw whether it answers or not.
                // So the test is `printing`, and the three sentences below say
                // WHICH kind of not-printing this is.
                if !printing, let x = machine.bed?.x, let y = machine.bed?.y {
                    BedPlan(x: x, y: y, widest: shop.widestBed, deepest: shop.deepestBed,
                            box: CGSize(width: 74, height: 38))
                    Text(shop.words.callIt(!askable ? "mac.cannot_ask"
                                           : !connected ? "mac.not_connected" : "mac.idle"))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else {
                    LayerProgress(progress: printing ? Double(status?.progress ?? 0) / 100 : 0,
                                  tint: printing ? Khayt.hot : Khayt.cyan,
                                  height: 34)
                    if printing {
                        HStack(spacing: 5) {
                            // The one moving thing on a still floor, and only
                            // when something is actually being made.
                            Circle().fill(Khayt.hot).frame(width: 6, height: 6).alive()
                            Text("\(status?.progress ?? 0)")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(Khayt.hot)
                            Text("%").font(.caption).foregroundStyle(Khayt.hot.opacity(0.7))
                            Spacer(minLength: 0)
                            // The time left is what a shop actually plans
                            // around, so it is beside the figure rather than
                            // on a line of its own to be read.
                            if let left = status?.timeRemaining, left > 0 {
                                Text(PrinterWatch.spell(left))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Text(status?.filename.isEmpty == false
                             ? status!.filename : shop.words.callIt("mac.live"))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(shop.words.callIt(connected ? "mac.idle" : "mac.not_connected"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 260, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Khayt.ground : .clear)
            )
            .liftsOnHover(hovering)
            .onHover { hovering = $0 }
            // ── A TILE THAT LOOKS PRESSABLE HAS TO BE ─────────────────────
            //
            // Every one of these names a machine the shop can open, and until
            // now the only way there was the sidebar. A drawing of a printer
            // that does nothing when clicked teaches people that the drawings
            // are decoration.
            .onTapGesture { shop.shelf = .machines }
            .help(machine.name)
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
}

/// The invoices and quotes the shop said it wanted chasing.
///
/// `lib/payment-reminder.js` and `lib/quote-followup.js` choose the rows —
/// each with its own grace period, cooldown and cap — and both return nothing
/// until the shop turns them on. So this draws nothing on a book that has not
/// asked for it, which is the point: a permanently empty section is a section
/// people stop reading.
private /// Jobs the queue is going to make late, before they are.
///
/// ── A DIFFERENT KIND OF NEWS ───────────────────────────────────────────────
///
/// The attention panel above says a job IS late, which is true and arrives too
/// late to act on. This says a job WILL BE, because of the work in front of it
/// — and a shop told on Tuesday that Friday's job will not make it can move it,
/// split it across two machines, or ring the customer while that is still a
/// courtesy rather than an apology.
///
/// The projection is `lib/schedule.js`'s: the queue's print hours over the
/// shop's own working hours per calendar day. It is an estimate and is worded
/// like one — "expected", not "will be".
///
/// A job already in the attention panel is excluded, in `Shop.willBeLate`.
/// Saying the same job twice in two different words is how a screen teaches
/// somebody to skim it.
struct RunningOut: View {
    @Bindable var shop: Shop

    /// Six, and then a count. The same rule the attention list keeps: a list
    /// that silently stops is a list that misstates how much is wrong.
    private var shown: [Order] { Array(shop.willBeLate.prefix(6)) }
    private var hidden: Int { max(0, shop.willBeLate.count - shown.count) }

    var body: some View {
        if !shop.willBeLate.isEmpty {
            DetailSection(shop.words.callIt("mac.will_be_late"),
                          accent: Khayt.attention, count: shop.willBeLate.count) {
                VStack(spacing: 0) {
                    ForEach(shown) { job in
                        row(job)
                        if job.id != shown.last?.id || hidden > 0 { LayerRule() }
                    }
                    if hidden > 0 {
                        HStack {
                            Text(shop.words.callIt("mac.attn_more",
                                                   ["n": .number(Double(hidden))]))
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                    }
                }
                .card()
            }
        }
    }

    @ViewBuilder
    private func row(_ job: Order) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(job.project.isEmpty ? job.id : job.project)
                .font(.callout).lineLimit(1)
            // The order number, as the attention list and the chase list both
            // show it. Not decoration: the sample book has two jobs called
            // "HVAC duct adapter" — one finished and unpaid, one pending and
            // about to be late — and without the number this section and the
            // chase list below it read as the same job written twice.
            Text(job.id)
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            // Both dates, because the gap is the point: "due the 12th, expected
            // the 15th" says how much trouble it is in, and one date alone does
            // not.
            if let due = job.dueDate, !due.isEmpty, let eta = shop.readyDate(of: job.id) {
                Text(shop.words.callIt("mac.due_expected",
                                       ["due": .string(Self.day(due)),
                                        "eta": .string(Self.day(eta))]))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(Khayt.attention)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        // Open the job, the way every other row on this screen does: the jobs
        // table with it selected, so the inspector beside it answers "why".
        .onTapGesture {
            shop.shelf = .jobs(nil)
            shop.selection = job.id
        }
    }

    /// `2026-09-12` as the shop reads it. The stored form is unambiguous and
    /// nobody wants to read it.
    static func day(_ iso: String) -> String {
        guard let d = DateFormatter.shopDay.date(from: iso) else { return iso }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct ToChase: View {
    let shop: Shop

    /// ── NOT WHAT THE PANEL ABOVE ALREADY SAYS ─────────────────────────────
    ///
    /// A job that is late is in the attention panel, and its invoice is
    /// overdue, so it was in this list too — four of the eight rows here were
    /// four of the six rows eight inches above them. One problem printed twice
    /// is not twice the warning; it is a screen a shop learns to skim.
    ///
    /// So this list is what the panel does NOT already carry. A quote about to
    /// expire and an invoice on a job that was delivered on time are money
    /// questions with nobody late attached, and those are exactly the rows this
    /// section exists for.
    private var alreadyShown: Set<String> {
        Set((shop.attention?.items ?? []).map(\.id))
    }
    private var invoices: [Chase] { shop.invoicesToChase.filter { !alreadyShown.contains($0.id) } }
    private var quotes: [Chase] { shop.quotesToChase.filter { !alreadyShown.contains($0.id) } }

    var body: some View {
        if !invoices.isEmpty || !quotes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !invoices.isEmpty {
                    list(shop.words.callIt("mac.chase_invoices"),
                         "exclamationmark.circle", invoices, overdue: true)
                }
                if !quotes.isEmpty {
                    list(shop.words.callIt("dash.expiring_quotes"),
                         "clock.badge.questionmark", quotes, overdue: false)
                }
            }
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ symbol: String,
                      _ rows: [Chase], overdue: Bool) -> some View {
        DetailSection(title) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: symbol)
                            .foregroundStyle(Khayt.attention)
                            .frame(width: 18)
                        // One line, as the attention list above it. Two lists
                        // of the same shape reading differently is the reader
                        // wondering what the difference means.
                        Text(row.name?.isEmpty == false ? row.name! : row.id).lineLimit(1)
                        Text(row.id).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Text(age(row, overdue: overdue))
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(Khayt.attention)
                    }
                    .padding(.vertical, 3)
                    .frame(minHeight: Metric.row)
                    if row.id != rows.last?.id { LayerRule() }
                }
            }
            .padding(.horizontal, 12)
            .card(padding: 0)
        }
    }

    /// The module's own figure, said the right way round for each list:
    /// `daysOverdue` counts up from a due date, `daysUntilExpiry` counts down
    /// to one — and a quote whose day has come is neither "in 0 days" nor
    /// overdue, it has expired.
    private func age(_ row: Chase, overdue: Bool) -> String {
        guard let days = row.days else { return "" }
        if overdue { return shop.words.callIt("mac.chase_days_over", ["n": .number(Double(days))]) }
        if days <= 0 { return shop.words.callIt("mac.chase_expired") }
        return shop.words.callIt("mac.chase_days_left", ["n": .number(Double(days))])
    }
}

/// This month against the target the shop set.
///
/// Nothing at all when the target is zero, which `dash.goal_hint` states is
/// how you switch it off. The figure is `kpis` for the month, so it is the
/// same revenue the tiles above show when the period is This month — not a
/// second opinion about what counts.
private struct Goal: View {
    let shop: Shop

    var body: some View {
        let goal = Shop.plainNumber(shop.settingsDict["monthlyGoal"]) ?? 0
        if goal > 0 {
            let done = shop.thisMonthRevenue
            DetailSection(shop.words.callIt("dash.goal")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Money.text(done, shop.currency)).monospacedDigit()
                        Text("/").foregroundStyle(.tertiary)
                        Text(Money.text(goal, shop.currency))
                            .monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((done / goal * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(done >= goal ? AnyShapeStyle(Khayt.done)
                                                          : AnyShapeStyle(.secondary))
                    }
                    ProgressView(value: min(1, done / goal))
                        .tint(done >= goal ? Khayt.done : Khayt.cyan)
                }
                .card(padding: 12)
            }
        }
    }
}

/// What is late, wrong, or about to be.
/// The words `lib/attention.js` emits, named once.
///
/// ── THEY WERE COMPARED AGAINST A WORD NOTHING PRODUCES ────────────────────
///
/// The panel below asked `severity == "bad"`, and the module emits `crit` and
/// `warn` — never "bad". The comparison was false on every row that has ever
/// been drawn: the rail stayed amber with a printer down, and a machine that
/// had stopped looked exactly like a nozzle reminder. Nothing threw, no test
/// failed, and the module's distinction between "something has broken" and
/// "something merely wants a person" was thrown away one line before the
/// screen.
///
/// A string compared against a value its producer never emits is silent by
/// construction, so `SeverityTests` asks the producer.
enum NeedsAttentionSeverity {
    static let critical = "crit"
    static let warning = "warn"
}

/// What a row of the attention panel offers to do about itself.
enum NeedsAttentionAction {
    /// Each kind gets its own mark, so the list is scannable before it is read.
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "machine": "printer.dotmatrix"
        case "nozzle": "wrench.adjustable"
        case "stock": "circle.dashed"
        default: "clock.badge.exclamationmark"
        }
    }

    /// The word on the button, per kind. A single "Open" on all four would be
    /// honest and useless: the value is in saying what pressing it does before
    /// it is pressed.
    static func forKind(_ kind: String) -> String {
        switch kind {
        case "machine": "mac.attn_go_machine"
        case "nozzle": "mac.attn_go_nozzle"
        case "stock": "mac.attn_go_stock"
        default: "mac.attn_go_job"
        }
    }
}

private struct NeedsAttention: View {
    let items: [DashboardFacts.Item]
    let shop: Shop

    /// How many rows before the panel stops being a list and becomes a wall.
    ///
    /// The module returns everything, correctly — it is a selector, not a
    /// display. On the sample shop that is eight rows, and a shop with twenty
    /// late jobs would get a dashboard that is nothing but this panel, which is
    /// the same failure as a band with twenty machines on it. Six fit above the
    /// fold on the smallest window this app opens at; the rest are counted and
    /// one press away.
    private static let atMost = 6

    private var shown: ArraySlice<DashboardFacts.Item> { items.prefix(Self.atMost) }
    private var hidden: Int { max(0, items.count - Self.atMost) }

    /// Red when something has actually failed, amber when something merely
    /// wants a person. The severity is the module's own — this is not a second
    /// opinion about how worried to be.
    private var worst: Color {
        items.contains { $0.severity == NeedsAttentionSeverity.critical }
            ? Khayt.late : Khayt.attention
    }

    var body: some View {
        // THE LEAD, whenever there is anything in it. This is the reason
        // somebody opened the screen, and it used to say so in the same 10pt
        // grey as "MONEY".
        DetailSection(shop.words.callIt("mac.needs_attention"),
                      accent: worst, symbol: "exclamationmark.triangle.fill",
                      lead: true, count: items.count) {
            VStack(spacing: 0) {
                ForEach(shown) { item in
                    Row(item: item, shop: shop,
                        ink: item.severity == NeedsAttentionSeverity.critical
                             ? Khayt.late : Khayt.attention)
                    if item.id != shown.last?.id || hidden > 0 { LayerRule() }
                }
                if hidden > 0 {
                    // Counted, not hidden. A list that silently stops at six is
                    // a list that says the shop has six problems.
                    HStack {
                        Text(shop.words.callIt("mac.attn_more", ["n": .number(Double(hidden))]))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(shop.words.callIt("mac.attn_see_all")) {
                            shop.shelf = .jobs(nil)
                        }
                        .buttonStyle(.borderless).font(.callout)
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(.horizontal, 12)
            .card(rail: worst, padding: 0)
        }
    }

    private struct Row: View {
        let item: DashboardFacts.Item
        let shop: Shop
        let ink: Color

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: NeedsAttentionAction.symbol(item.kind))
                    .foregroundStyle(ink)
                    .frame(width: 18)
                // ONE LINE, not two. This list is read at a glance and its job
                // is to be complete on the screen: stacking the order number
                // under the name doubled the height of every row, so six late
                // jobs filled the window and a seventh was below the fold —
                // which is the one thing a list of what is wrong must not do.
                Text(item.name ?? item.id).lineLimit(1)
                Text(subtitle).font(.caption2).monospacedDigit()
                    .foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 8)
                if let late = item.daysLate, late > 0 {
                    // Said in words, not by colour alone. This is the line that
                    // decides whether someone gets a phone call today.
                    Text(shop.words.callIt(late == 1 ? "mac.days_late_one" : "mac.days_late",
                                           ["n": .number(Double(late))]))
                        .font(.callout).monospacedDigit().foregroundStyle(ink)
                } else if let grams = item.grams {
                    // In the item's OWN unit. The shelf learned to count in
                    // sheets and millilitres; this screen was still writing the
                    // gram after everything.
                    Text(Quantity.say(grams, shop.inventoryUnits[item.id], shop.words))
                        .font(.callout).monospacedDigit().foregroundStyle(ink)
                }
                // ── AND THE THING THAT FIXES IT ───────────────────────────
                //
                // A list of problems with nothing to press is a list you read
                // and then go looking for the screen it is about. Every row
                // knows which screen that is, so it takes you there.
                // `.borderless`, not `.link`: a link button paints itself
                // `NSColor.linkColor` and ignores the environment tint, so
                // every one of these came out system blue in an app whose own
                // colour is cyan — and would have stayed blue for someone who
                // had chosen a different accent in System Settings, which is
                // the one case the tint exists to honour.
                Button(shop.words.callIt(NeedsAttentionAction.forKind(item.kind))) { go() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            // 28pt rows. A ruled list can be this tight; a striped one cannot,
            // which is half the reason the rules are lines.
            .padding(.vertical, 3)
            .frame(minHeight: Metric.row)
            .contentShape(Rectangle())
            .onTapGesture { go() }
        }

        /// What is wrong, in the fewest characters that say it: the order
        /// number for a job, the shop's own colour for a spool, the state for a
        /// machine, the figure it went past for a nozzle.
        private var subtitle: String {
            switch item.kind {
            case "stock": return item.variant ?? ""
            case "machine":
                return item.state.map { shop.words.callIt("mac.attn_state_\($0)") } ?? ""
            case "nozzle":
                guard let threshold = item.threshold else { return "" }
                return shop.words.callIt("mac.attn_nozzle_of", ["n": .number(threshold)])
            default: return item.id
            }
        }

        private func go() {
            switch item.kind {
            case "stock": shop.shelf = .inventory
            case "machine", "nozzle": shop.shelf = .machines
            default:
                shop.shelf = .jobs(nil)
                shop.selection = item.id
            }
        }
    }
}

/// What the shop is doing.
private struct Work: View {
    let facts: DashboardFacts
    let shop: Shop

    /// The floor leads on a morning when nothing is wrong.
    ///
    /// A screen answers "what should I look at" by saying one thing louder than
    /// the rest, and which thing that is depends on the day. With something in
    /// the attention panel, this is supporting; with nothing there, this is the
    /// answer and it says so.
    let leads: Bool

    var body: some View {
        DetailSection(shop.words.callIt("mac.the_floor"),
                      accent: leads ? Khayt.cyan : nil,
                      symbol: leads ? "printer.fill" : nil,
                      lead: leads) {
            // ONE CARD, RULED — not four. These four figures are one thing: the
            // state of the floor right now. Drawn as four separate cards they
            // spent almost all their ink on borders.
            // The machines themselves, above the count of them. "Printing 0"
            // is the book's answer; the tiles are the printers'.
            FloorStrip(shop: shop)
            StatStrip(stats: [
                // Amber only when something IS printing. A colour that means
                // "being made right now" sitting on a zero says the opposite of
                // what it means, and a dashboard where the warm colour is
                // always on is a dashboard where it stops being noticed.
                Stat(label: shop.words.callIt("queue.printing"),
                     value: "\(facts.printingCount)",
                     symbol: "printer",
                     tint: facts.printingCount > 0 ? Khayt.hot : Color.secondary,
                     alive: facts.printingCount > 0),
                Stat(label: shop.words.callIt("mac.open_count"),
                     value: "\(facts.activeCount)", mark: .jobs),
                Stat(label: shop.words.callIt("mac.late_tile"),
                     value: "\(facts.lateCount)",
                     mark: .clock,
                     tint: facts.lateCount > 0 ? Khayt.attention : Color.secondary),
                Stat(label: shop.words.callIt("mac.machines_online"),
                     value: "\(facts.fleet.live)/\(facts.fleet.total)",
                     working: facts.fleet.offline > 0
                         ? shop.words.callIt("mac.fleet_offline",
                                             ["n": .number(Double(facts.fleet.offline))]) : nil,
                     mark: .machines),
            ])
        }
    }
}

/// What the printers are doing, in one line each.
///
/// Only the ones that are actually running: a list of idle machines is the
/// machines screen, and this is the answer to "is it still going". Nothing at
/// all when nothing is printing, because an empty section under a heading reads
/// as a screen that failed to load.
private struct RunningNow: View {
    let shop: Shop

    private var running: [(Machine, KhaytEngine.PrinterStatus)] {
        shop.machines.compactMap { machine in
            // The one predicate, not a fourth spelling of it. This file, the
            // machine card and two properties on `Shop` each had their own,
            // and two of the four forgot to lowercase.
            guard let status = shop.printers.readings[machine.id]?.status,
                  PrinterWatch.isPrinting(status.state) else { return nil }
            return (machine, status)
        }
    }

    var body: some View {
        if !running.isEmpty {
            DetailSection(shop.words.callIt("mac.live")) {
                VStack(spacing: 10) {
                    ForEach(running, id: \.0.id) { machine, status in
                        Line(machine: machine, status: status, shop: shop)
                    }
                }
            }
        }
    }

    private struct Line: View {
        let machine: Machine
        let status: KhaytEngine.PrinterStatus
        let shop: Shop

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(machine.name).font(.body.weight(.semibold)).lineLimit(1)
                    if !status.filename.isEmpty {
                        Text(status.filename)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    if let left = status.timeRemaining, left > 0 {
                        Text(shop.words.callIt("mac.eta") + " " + PrinterWatch.spell(left))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text("\(status.progress)%")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Khayt.hot)
                        .frame(width: 46, alignment: .trailing)
                }
                // THE ONE WARM THING ON THE SCREEN, and the app's own reason
                // for having a warm colour at all: the icon's drop of filament
                // is exactly this moment. Everything else on the dashboard is a
                // number about the past; this is the machine, now.
                //
                // Drawn as the LAYERS it has laid, not as a capsule filling up.
                // The shape has been in `Craft.swift` for months and appeared on
                // exactly one surface — a picture in the snapshot runner that
                // nothing shipped — while the screen a shop actually leaves open
                // used the stock bar, which is the same bar as every other app
                // on the machine.
                LayerProgress(progress: Double(status.progress) / 100)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What has gone wrong with a printer, since the app opened.
///
/// The alerts are `lib/printer-alerts.js`'s — its thresholds, its cooldowns,
/// its stall clock. This is only where they are put once raised, and it exists
/// because a macOS notification is gone the moment somebody swipes it away.
private struct WentWrong: View {
    let shop: Shop

    var body: some View {
        let notices = shop.printers.notices.raised
        if !notices.isEmpty {
            DetailSection(shop.words.callIt("mac.printer_trouble")) {
                VStack(spacing: 0) {
                    ForEach(notices.prefix(5)) { notice in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: notice.kind == "stall"
                                  ? "pause.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle(Khayt.attention)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(notice.title).font(.body)
                                if !notice.body.isEmpty {
                                    Text(notice.body).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 12)
                            Text(notice.at.formatted(date: .omitted, time: .shortened))
                                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        if notice.id != notices.prefix(5).last?.id { Divider() }
                    }
                }
            }
        }
    }
}

/// The money, when this shop deals in money.
///
/// Every figure comes from the shared modules — `order-money` for what an order
/// earned and what is owed on it, `kpi-rows` for which orders count, `kpi` for
/// the totals. The margin shown here is the margin the Electron app shows,
/// because it is the same three functions.
///
/// This screen showed zeros for ten minutes once, because `computeKpis` was
/// handed raw orders and answered politely. The figures came back only after
/// those rules were lifted out of `renderer/analytics.js` into `lib/`.
private struct MoneyTiles: View {
    @Bindable var shop: Shop

    var body: some View {
        DetailSection(shop.words.callIt("mac.money"), accent: Khayt.cyan, symbol: "banknote.fill") {
            // Which period, said next to the figures rather than assumed. An
            // owner reading "revenue" needs to know whether that is this month
            // or all time before the number means anything.
            // NOT WHEN THERE IS NOTHING TO PICK A PERIOD OF. Every option gives
            // the same nothing, so it is a control that invites a press and
            // answers identically five times.
            if !shop.hasNotTradedYet {
                Picker("", selection: $shop.kpiRange) {
                    ForEach(Dashboard.ranges, id: \.0) { key, word in
                        Text(shop.words.callIt(word)).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.bottom, 2)
            }

            // A SHOP THAT HAS NOT TRADED YET IS NOT A SHOP WITH ZERO REVENUE.
            //
            // Every figure below is over completed jobs, so a book with none
            // has nothing to state: 0.00 revenue, 0.00 gross, 0.00% margin,
            // 0.00 average, "—" on time. Eight zeros and a dash, drawn full
            // size, on the first screen this app ever shows anybody. Every
            // other screen in the app draws something when it is empty; the
            // front door totalled nothing and reported it.
            //
            // The floor above stays: how many machines are online is true on
            // day one and is the thing a new shop set up first.
            if shop.hasNotTradedYet {
                EmptyHere(title: shop.words.callIt("mac.no_money_yet"),
                          message: shop.words.callIt("mac.no_money_yet_hint"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {

            if let k = shop.kpis {
                // ── THE ONE FIGURE ────────────────────────────────────────
                //
                // Revenue was the first of eight identical tiles, which said
                // that the shop's takings and the number of files in its
                // library are equally worth looking at. They are not. This is
                // the figure somebody opens this screen for, so it is drawn
                // like it — and the two numbers that qualify it, profit and
                // margin, sit under it rather than beside it as rivals.
                //
                // No trend arrow here, deliberately. The only trend this app
                // has is `outlook.trendPct`, which is month-over-month; the
                // picker above can say "year", and an arrow that means
                // something other than the figure it is attached to is the
                // exact trap the comment further down was written about.
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.words.callIt("mac.revenue"))
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase).tracking(0.6)
                        .foregroundStyle(Khayt.cyan)
                    BigFigure(value: Money.figure(k.revenue), unit: Money.mark(shop.currency))
                    HStack(spacing: 5) {
                        Text(Money.short(k.grossProfit, shop.currency))
                            .monospacedDigit()
                        Text(shop.words.callIt("mac.gross").lowercased())
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(Money.figure(k.grossMargin))%")
                            .monospacedDigit()
                        Text(shop.words.callIt("mac.margin").lowercased())
                            .foregroundStyle(.secondary)
                        // THE DIVISOR, BESIDE THE FIGURE IT DIVIDES.
                        //
                        // Every number in this section is over COMPLETED rows —
                        // revenue, cost, margin, the average, on-time — and the
                        // "Jobs" tile below is over every row in the period. So
                        // the screen showed 1,243.08 revenue, 4 jobs and a
                        // 621.54 average, and the obvious arithmetic gives
                        // 310.77. Both figures were right and together they
                        // were not: `avgOrderValue` divides by the count that
                        // is now printed here.
                        Text("·").foregroundStyle(.tertiary)
                        Text(shop.words.counting(k.completedCount, "mac.jobs_word"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .lineLimit(1)
                }
                .card(rail: Khayt.cyan, padding: 14)

                // ONE CARD, RULED. Five separate cards for five figures is
                // five borders, five corner radii and five paddings carrying
                // five numbers — and they are one thing: how the period went.
                StatStrip(stats: [
                    // WITH ITS DIVISOR. "Average job 540.46" is a figure you
                    // either trust or do not; "1,080.93 ÷ 2" underneath is one
                    // you can check while you read it.
                    Stat(label: shop.words.callIt("mac.avg_order"),
                         value: Money.short(k.avgOrderValue, shop.currency),
                         working: k.completedCount > 0
                             ? "\(Money.figure(k.revenue)) ÷ \(k.completedCount)" : nil,
                         mark: .reports),
                    // NOT "Owed" here. `kpi` scopes outstanding to the rows in
                    // the period, and the toolbar shows what the whole book is
                    // owed, unscoped and always visible. Two figures under one
                    // word, inches apart, differing by an order of magnitude —
                    // the same trap this section was rewritten to remove once
                    // already.
                    Stat(label: shop.words.callIt("mac.jobs_count"),
                         value: "\(k.orderCount)", mark: .jobs),
                    // Nothing to judge against is "—", not 100%. A shop with no
                    // due dates has not delivered everything on time; it has
                    // promised nothing.
                    Stat(label: shop.words.callIt("mac.on_time"),
                         value: k.onTimePct.map { "\(Money.figure($0))%" } ?? "—",
                         symbol: "checkmark.circle"),
                    Stat(label: shop.words.callIt("queue.completed"),
                         value: "\(k.completedCount)", symbol: "checkmark.seal"),
                    Stat(label: shop.words.callIt("mac.library"),
                         value: "\(shop.files.count)", mark: .library),
                ])
            }
            }   // hasNotTradedYet
        }
    }
}

/// A figure worth reading from across the room.
private struct Tile: View {
    let value: String
    let label: String
    /// The arithmetic that produced the value, on the tiles where there is
    /// one. A shop that can check one derived figure trusts the other forty.
    var working: String?
    let symbol: String
    let tint: Color
    /// Set on the one tile that is describing something happening RIGHT NOW.
    var alive = false

    /// Somebody who has asked the system for less movement gets none.
    ///
    /// The HIG: "Make motion optional. Not everyone can or wants to experience
    /// the motion in your app." The symbol still turns amber and the number
    /// still counts, so nothing is only said by the movement.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                // ONE piece of motion in the whole app, on the one thing that
                // is actually moving. The HIG asks for motion that is
                // purposeful and brief and warns against adding it to anything
                // frequent; a printer laying down plastic is neither frequent
                // nor decorative, and a shop glancing across the room should be
                // able to tell from here that the machine is still going.
                .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                              isActive: alive && !reduceMotion)
            Text(value)
                // Rounded to match `BigFigure`, and stepped down from it: the
                // hero above is 34pt, so a supporting tile at the old 24 was
                // close enough to argue with it. 19 reads as "also a number,
                // and not the one".
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            // The arithmetic, tied to the figure by a tick the way a dimension
            // on a drawing is tied to what it measures.
            if let working {
                HStack(spacing: 5) {
                    Rectangle().fill(Khayt.hairline).frame(width: 1, height: 9)
                    Text(working).font(.caption2).monospacedDigit()
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .card(rail: alive ? Khayt.hot : nil, padding: 10)
    }
}


/// Six months of takings, and a sentence saying what they add up to.
///
/// ── WHY A CHART AT ALL ────────────────────────────────────────────────────
///
/// The dashboard was eight tiles and then two thirds of a window of nothing.
/// Tiles answer "what is it now"; none of them answers "is that good", which is
/// the question a shop actually opens this screen with. Six bars answer it in
/// the time it takes to look.
///
/// The HIG asks for a chart to carry descriptive text — "brief descriptive text
/// that serves as a headline or summary for a chart, helping people grasp
/// essential information at a glance" — so the headline is a sentence, not the
/// word "Revenue" over an axis. Weather's "Chance of light rain in the next
/// hour" is the model.
///
/// ── AND WHY IT MIGHT NOT BE HERE ─────────────────────────────────────────
///
/// `method == "none"` means the shop has nothing to draw a trend through, and
/// the chart is absent rather than showing six flat zeros with a confident line
/// across them. A forecast from two points is a decoration that looks like
/// information.
private struct Takings: View {
    let outlook: KhaytEngine.RevenueOutlook
    let shop: Shop

    /// The bar the mouse is on, if any. Nil is the resting state and the
    /// headline is what shows then.
    @State private var hovered: Int?

    private var best: KhaytEngine.RevenueMonth? { outlook.history.max { $0.revenue < $1.revenue } }
    private var last: KhaytEngine.RevenueMonth? { outlook.history.last }

    var body: some View {
        DetailSection(shop.words.callIt("mac.takings")) {
            VStack(alignment: .leading, spacing: 10) {
                headline
                chart
            }
        }
    }

    /// What the six months say, in one line.
    ///
    /// Three sentences rather than one with a number swapped in, because "up
    /// 8%" and "your best month" are different pieces of news and a shop should
    /// be told the more interesting one.
    @ViewBuilder private var headline: some View {
        let text: String = {
            if let hovered, let month = outlook.history.first(where: { $0.key == hovered }) {
                return shop.words.callIt("mac.takings_month",
                                         ["month": .string(Self.monthName(month.key)),
                                          "amount": .string(Money.short(month.revenue, shop.currency))])
            }
            if let last, let best, best.key == last.key, best.revenue > 0 {
                return shop.words.callIt("mac.takings_best",
                                         ["month": .string(Self.monthName(last.key))])
            }
            if let pct = outlook.trendPct, outlook.method == "trend" {
                let key = pct >= 0 ? "mac.takings_up" : "mac.takings_down"
                return shop.words.callIt(key, ["pct": .number(abs(pct)),
                                               "amount": .string(Money.short(outlook.nextMonth, shop.currency))])
            }
            return shop.words.callIt("mac.takings_flat")
        }()
        Text(text)
            .font(.callout)
            // The headline changes as the pointer moves along the bars, so it
            // must not resize the section under it — a chart that jumps while
            // you read it is worse than one with no headline.
            .frame(height: 20, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(hovered == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .animation(.none, value: hovered)
    }

    private var chart: some View {
        // Deliberately NOT Swift Charts. This is six bars; the framework's
        // axes, marks and gesture handling are a great deal of machinery for a
        // shape that is a rounded rectangle scaled by a number, and it draws
        // nothing at all in the offline bitmap the snapshot runner uses — which
        // would mean the one screen nobody could review is the one that was
        // just redesigned.
        let peak = max(outlook.history.map(\.revenue).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(outlook.history) { month in
                let lit = month.key == hovered
                // FULL COLOUR AT REST, and the others step back when one is
                // picked out. Written the other way first — everything muted
                // until hovered — which made the resting state, the one the
                // shop actually sees, the washed-out one. A chart is dimmed
                // relative to the thing being pointed at, not relative to
                // nothing.
                let strength: Double = hovered == nil ? 1 : (lit ? 1 : 0.35)
                // A month that earned nothing still gets a hairline, so six
                // months read as six months rather than as four.
                let height: CGFloat = max(2, 78 * month.revenue / peak)
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Khayt.cyan.opacity(strength))
                        .frame(height: height)
                    Text(Self.monthName(month.key))
                        .font(.caption2)
                        .foregroundStyle(lit ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .frame(maxWidth: 64)
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? month.key : (hovered == month.key ? nil : hovered) }
                .accessibilityElement()
                .accessibilityLabel(shop.words.callIt("mac.takings_month",
                                                      ["month": .string(Self.monthName(month.key)),
                                                       "amount": .string(Money.short(month.revenue, shop.currency))]))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 100, alignment: .bottom)
    }

    /// A month name in the reader's language, from the module's `key`.
    ///
    /// The module labels months `2026-08`, which is a sortable key and not a
    /// thing to show somebody. `key` is `year * 12 + month`, so the name is
    /// formatted here — where the locale is known, and where Arabic gets Arabic
    /// month names rather than a transliteration.
    static func monthName(_ key: Int) -> String {
        var components = DateComponents()
        components.year = key / 12
        components.month = key % 12 + 1
        components.day = 1
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated))
    }
}
