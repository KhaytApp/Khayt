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



    /// The attention items the screen shows: the site's rows when narrowed.
    private var attentionItems: [DashboardFacts.Item] {
        shop.attention?.items.filter(shop.inSite(attention:)) ?? []
    }

    /// What the shop is doing and what wants a person. The left column when
    /// there are two, and the top of the screen when there is one.
    @ViewBuilder private func theWork(items: [DashboardFacts.Item]) -> some View {
        // First, and above the figures: a late job under a revenue tile is a
        // late job nobody sees.
        if !items.isEmpty { NeedsAttention(items: items, shop: shop) }
        // Every machine on the floor, with what the printing ones are making.
        MachineCards(shop: shop)
        // What the queue is about to make late: under "this is already wrong".
        RunningOut(shop: shop)
        // And what went wrong while nobody was looking.
        WentWrong(shop: shop)
    }

    /// How the shop is doing. Inside `showsMoney`, so a shop that has turned
    /// the money off loses all of it.
    @ViewBuilder private var theMoney: some View {
        MoneyTiles(shop: shop)
        Goal(shop: shop)
        if let outlook = shop.outlook, outlook.method != "none" {
            Takings(outlook: outlook, shop: shop)
        }
    }

    /// The width from which the right column (372 pt) sits beside the work.
    private static let twoColumnFrom: CGFloat = 1120
    /// Below this the four figures wrap to two rows of two.
    private static let fourAcrossFrom: CGFloat = 900

    /// The longest time left on any machine that is printing, if one reports.
    private var latestFinish: Double? {
        shop.siteMachinesInUse.compactMap { machine -> Double? in
            guard let status = shop.printers.readings[machine.id]?.status,
                  PrinterWatch.isPrinting(status.state),
                  let left = status.timeRemaining, left > 0 else { return nil }
            return left
        }.max()
    }

    private func statCards(_ facts: DashboardFacts, showsMoney: Bool,
                           items: [DashboardFacts.Item]) -> [TodayStatCard] {
        let words = shop.words
        var cards: [TodayStatCard] = []
        if showsMoney {
            let overdue = shop.invoicesToChase.count
            cards.append(TodayStatCard(
                label: words.callIt("mac.owed_to_you"),
                value: shop.owedTotal.map { Money.text($0, shop.currency) } ?? "—",
                detail: overdue > 0
                    ? words.callIt("mac.today_overdue", ["n": .number(Double(overdue))]) : nil,
                detailColor: Khayt.late))
            let range = Self.ranges.first { $0.0 == shop.kpiRange }?.1 ?? "an.range.month"
            var change: String?
            var changeColor = Color.secondary
            if let outlook = shop.outlook, outlook.method == "trend", let pct = outlook.trendPct {
                change = (pct >= 0 ? "▲ " : "▼ ")
                    + words.callIt("mac.today_trend", ["pct": .string(Money.figure(abs(pct)))])
                changeColor = pct >= 0 ? Khayt.done : Khayt.late
            }
            _ = range
            // The month's NET, the figure the money strip has always shown
            // (`Shop.monthNet`, TriageModel) — not a second calculation.
            cards.append(TodayStatCard(
                label: shop.monthNetLabel,
                value: shop.monthNet.map { Money.text($0, shop.currency) } ?? "—",
                detail: change ?? shop.monthNetNote, detailColor: change == nil ? .secondary : changeColor))
        }
        cards.append(TodayStatCard(
            label: words.callIt("mac.on_machines"),
            value: words.callIt("mac.n_of_m", ["n": .number(Double(facts.printingCount)),
                                               "m": .number(Double(facts.fleet.total))]),
            detail: latestFinish.map { words.callIt("mac.eta") + " " + PrinterWatch.spell($0, words) }
                ?? fleetNote(facts)))
        let low = items.filter { $0.kind == "stock" }.count
        cards.append(TodayStatCard(
            label: words.callIt("mac.filament_shelf"),
            value: words.numeral(shop.siteSpools.count),
            detail: low > 0 ? words.callIt("mac.today_low", ["n": .number(Double(low))]) : nil,
            detailColor: Khayt.attention))
        return cards
    }

    /// Why machines are not printing: the shop's own Under service, said as
    /// that, apart from the ones that have stopped answering. The fleet count
    /// hands an under-service machine to the shared rule as down
    /// (`Shop.machineFleet`), so "1 not answering" was said of a printer the
    /// shop had switched off on purpose.
    private func fleetNote(_ facts: DashboardFacts) -> String? {
        let words = shop.words
        let service = shop.machines.filter { $0.isUnderService && shop.inSite(machine: $0.id) }.count
        let silent = max(0, facts.fleet.offline - service)
        if silent > 0 { return words.callIt("mac.fleet_offline", ["n": .number(Double(silent))]) }
        if service > 0 { return words.callIt("mac.fleet_service", ["n": .number(Double(service))]) }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            // The shop's figures only for a level that may see them (`analytics`
            // in lib/rbac.js: owner, manager) — what the navy strip always did.
            let showsMoney = shop.facts?.showsMoney != false && shop.lockAllows("analytics", "view")
            let wide = geo.size.width >= Self.twoColumnFrom
            let items = attentionItems
            let due = TodayDue(shop: shop)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let facts = shop.facts {
                        TodayHeader(shop: shop, facts: facts, attention: items.count, dueToday: due.today)
                        let cards = statCards(facts, showsMoney: showsMoney, items: items)
                        if geo.size.width >= Self.fourAcrossFrom || cards.count < 3 {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(Array(cards.enumerated()), id: \.offset) { $1 }
                            }
                        } else {
                            let half = (cards.count + 1) / 2
                            VStack(spacing: 14) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(Array(cards.prefix(half).enumerated()), id: \.offset) { $1 }
                                }
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(Array(cards.dropFirst(half).enumerated()), id: \.offset) { $1 }
                                }
                            }
                        }
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 22) {
                                theWork(items: items)
                                if showsMoney { theMoney }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 22) { sideColumn(due) }
                                .frame(width: 372, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            theWork(items: items)
                            sideColumn(due)
                            if showsMoney { theMoney }
                        }
                    }
                }
                .padding(Metric.screen + 10)
                .frame(maxWidth: 1680, alignment: .leading)
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

    /// Due this week, and the customers it is waiting on.
    @ViewBuilder private func sideColumn(_ due: TodayDue) -> some View {
        DueThisWeek(shop: shop, due: due)
        // Quotes sent and not approved, invoices past their grace: the shop's
        // own chase lists, which are opt-in and absent when empty.
        if shop.lockAllows("analytics", "view"), ToChase(shop: shop).hasRows {
            TodaySection(shop.words.callIt("mac.waiting_customers")) { ToChase(shop: shop) }
        }
    }
}

/// The top of the screen: the day, what needs the owner, and the shop in a line.
private struct TodayHeader: View {
    let shop: Shop
    let facts: DashboardFacts
    let attention: Int
    let dueToday: Int

    var body: some View {
        let words = shop.words
        HeaderLine {
            VStack(alignment: .leading, spacing: 10) {
                // Weekday and time, re-read each minute.
                TimelineView(.everyMinute) { context in
                    TodayEyebrow(words.say(context.date, .dateTime.weekday(.wide))
                                 + " · " + words.say(context.date, Date.FormatStyle(date: .omitted, time: .shortened)))
                }
                Text(title)
                    .font(.system(size: 30, weight: .bold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Text(words.callIt("mac.today_summary", [
                "open": .number(Double(facts.activeCount)),
                "printing": .number(Double(facts.printingCount)),
                "due": .number(Double(dueToday)),
            ]))
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
    }

    private var title: String {
        let words = shop.words
        let hour = Calendar.book.component(.hour, from: Date())
        let greeting = words.callIt(hour < 12 ? "mac.today_morning"
                                    : hour < 18 ? "mac.today_afternoon" : "mac.today_evening")
        let rest = attention > 0 ? words.counting(attention, "mac.today_needs")
                                 : words.callIt("mac.today_clear")
        // Japanese and Chinese put no space between sentences.
        let gap = ["ja", "zh"].contains(words.language) ? "" : " "
        return greeting + gap + rest
    }
}

/// A leading block and a trailing one on a line, bottom-aligned. A plain
/// HStack: `ViewThatFits` would build both candidates on every draw.
private struct HeaderLine<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) { content }
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
    /// The site's, when the shop is looking at one.
    private var late: [Order] { shop.willBeLate.filter(shop.inSite) }
    private var shown: [Order] { Array(late.prefix(6)) }
    private var hidden: Int { max(0, late.count - shown.count) }

    var body: some View {
        if !late.isEmpty {
            TodaySection(shop.words.callIt("mac.will_be_late") + " · " + shop.words.numeral(late.count)) {
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
                                       ["due": .string(Self.day(due, shop.words)),
                                        "eta": .string(Self.day(eta, shop.words))]))
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
    /// TAKES THE SHOP'S WORDS, because a `static` has no shop to ask and the
    /// system locale is the Mac's rather than the book's — which is how an
    /// Arabic front door came to read its dates in English.
    static func day(_ iso: String, _ words: Words) -> String {
        guard let d = DateFormatter.shopDay.date(from: iso) else { return iso }
        return words.say(d, .dateTime.day().month(.abbreviated))
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
    /// What the attention panel above actually SHOWS — narrowed to the site
    /// like it. Built from every attention row, a late job at another site
    /// was hidden there AND left out here, and its overdue invoice showed
    /// nowhere on the dashboard. Money is the shop's, so it shows here.
    private var alreadyShown: Set<String> {
        Set((shop.attention?.items ?? []).filter(shop.inSite(attention:)).map(\.id))
    }
    private var invoices: [Chase] { shop.invoicesToChase.filter { !alreadyShown.contains($0.id) } }
    private var quotes: [Chase] { shop.quotesToChase.filter { !alreadyShown.contains($0.id) } }

    /// Whether there is anything to chase, so a caller can leave out its heading.
    var hasRows: Bool { !invoices.isEmpty || !quotes.isEmpty }

    var body: some View {
        if hasRows {
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
        TodaySection(title) {
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
        if overdue { return shop.words.counting(days, "mac.chase_days_over") }
        if days <= 0 { return shop.words.callIt("mac.chase_expired") }
        return shop.words.counting(days, "mac.chase_days_left")
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
    /// Swept on arrival, moved on a new reading, still on a redraw — the shape
    /// `WearGauge` established. Copied rather than reinvented: a second answer
    /// for "a gauge reaching its reading" is how a motion system drifts.
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let goal = Shop.plainNumber(shop.settingsDict["monthlyGoal"]) ?? 0
        if goal > 0 {
            let done = shop.thisMonthRevenue
            TodaySection(shop.words.callIt("dash.goal")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Money.text(done, shop.currency)).monospacedDigit()
                        Text("/").foregroundStyle(.tertiary)
                        Text(Money.text(goal, shop.currency))
                            .monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: shop.words.numeral(Int((done / goal * 100).rounded())) + "%")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(done >= goal ? AnyShapeStyle(Khayt.done)
                                                          : AnyShapeStyle(.secondary))
                    }
                    ProgressView(value: shown)
                        .tint(done >= goal ? Khayt.done : Khayt.brand)
                        .onAppear {
                            let now = min(1, done / goal)
                            guard !reduced else { shown = now; return }
                            withAnimation(Motion.gauge) { shown = now }
                        }
                        .onChange(of: done) { _, fresh in
                            withAnimation(Motion.of(Motion.gauge, unless: reduced)) {
                                shown = min(1, fresh / goal)
                            }
                        }
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
    /// The rest are counted and one press away.
    private static let atMost = 6

    private var shown: ArraySlice<DashboardFacts.Item> { items.prefix(Self.atMost) }
    private var hidden: Int { max(0, items.count - Self.atMost) }

    var body: some View {
        TodaySection(shop.words.callIt("mac.needs_attention") + " · " + shop.words.numeral(items.count)) {
            VStack(spacing: 0) {
                ForEach(shown) { item in
                    Row(item: item, shop: shop)
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
                    .padding(.vertical, 8)
                }
            }
            .todayCard(padding: 12)
        }
    }

    private struct Row: View {
        let item: DashboardFacts.Item
        let shop: Shop

        /// The tile's colour by KIND: a late job is late, a thin shelf wants
        /// attention, a machine is the shop's own business.
        private var tint: Color {
            switch item.kind {
            case "stock": Khayt.attention
            case "machine", "nozzle": Khayt.brand
            default: Khayt.late
            }
        }

        /// The text colour of the figure that says how bad: the module's own
        /// severity, not a second opinion.
        private var ink: Color {
            item.severity == NeedsAttentionSeverity.critical ? Khayt.late : Khayt.attention
        }

        var body: some View {
            HStack(spacing: 12) {
                TodayTile(symbol: NeedsAttentionAction.symbol(item.kind), tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? item.id)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(subtitle).monospacedDigit().foregroundStyle(.secondary)
                        if let late = item.daysLate, late > 0 {
                            // Said in words, not by colour alone.
                            Text(shop.words.counting(late, "mac.days_late"))
                                .monospacedDigit().foregroundStyle(ink)
                        } else if let grams = item.grams {
                            Text(Quantity.say(grams, shop.inventoryUnits[item.id], shop.words))
                                .monospacedDigit().foregroundStyle(ink)
                        }
                    }
                    .font(.system(size: 12.5)).lineLimit(1)
                }
                Spacer(minLength: 8)
                // And the thing that fixes it: every row knows which screen.
                Button(shop.words.callIt(NeedsAttentionAction.forKind(item.kind))) { go() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.vertical, 8)
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
            TodaySection(shop.words.callIt("mac.printer_trouble")) {
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
                            Text(shop.words.say(notice.at, Date.FormatStyle(date: .omitted, time: .shortened)))
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
        TodaySection(shop.words.callIt("mac.money"), accent: Khayt.brand, symbol: "banknote.fill") {
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
                        .foregroundStyle(Khayt.brand)
                    BigFigure(value: Money.figure(k.revenue), unit: Money.mark(shop.currency))
                    HStack(spacing: 5) {
                        Text(Money.short(k.grossProfit, shop.currency))
                            .monospacedDigit()
                        Text(shop.words.callIt("mac.gross").lowercased())
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        // No revenue, no margin: the rule answers 0 there, and
                        // "0% margin" beside a loss reads as breaking even.
                        Text(k.revenue > 0 ? "\(Money.figure(k.grossMargin))%" : "—")
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
                .card(rail: Khayt.brand, padding: 14)

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
                         value: Money.quantity(Double(k.orderCount), decimals: 0), mark: .jobs),
                    // Nothing to judge against is "—", not 100%. A shop with no
                    // due dates has not delivered everything on time; it has
                    // promised nothing.
                    Stat(label: shop.words.callIt("mac.on_time"),
                         value: k.onTimePct.map { "\(Money.figure($0))%" } ?? "—",
                         symbol: "checkmark.circle"),
                    Stat(label: shop.words.callIt("queue.completed"),
                         value: Money.quantity(Double(k.completedCount), decimals: 0), symbol: "checkmark.seal"),
                    Stat(label: shop.words.callIt("mac.library"),
                         value: Money.quantity(Double(shop.files.count), decimals: 0), mark: .library),
                ])
            }
            }   // hasNotTradedYet
        }
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
        TodaySection(shop.words.callIt("mac.takings")) {
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
                                         ["month": .string(Self.monthName(month.key, shop.words)),
                                          "amount": .string(Money.short(month.revenue, shop.currency))])
            }
            if let last, let best, best.key == last.key, best.revenue > 0 {
                return shop.words.callIt("mac.takings_best",
                                         ["month": .string(Self.monthName(last.key, shop.words))])
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
                        .fill(Khayt.brand.opacity(strength))
                        .frame(height: height)
                    Text(Self.monthName(month.key, shop.words))
                        .font(.caption2)
                        .foregroundStyle(lit ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .frame(maxWidth: 64)
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? month.key : (hovered == month.key ? nil : hovered) }
                .accessibilityElement()
                .accessibilityLabel(shop.words.callIt("mac.takings_month",
                                                      ["month": .string(Self.monthName(month.key, shop.words)),
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
    /// AND IT TAKES THE SHOP'S WORDS NOW. The comment above has claimed since
    /// it was written that "Arabic gets Arabic month names rather than a
    /// transliteration" — and `Date.formatted` with no locale takes the Mac's,
    /// so it never did. The sentence was true about the intent and false about
    /// the code, which is the hardest kind of comment to disbelieve.
    static func monthName(_ key: Int, _ words: Words) -> String {
        var components = DateComponents()
        components.year = key / 12
        components.month = key % 12 + 1
        components.day = 1
        guard let date = Calendar.book.date(from: components) else { return "" }
        return words.say(date, .dateTime.month(.abbreviated))
    }
}
