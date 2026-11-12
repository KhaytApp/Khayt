import SwiftUI

/// Home — **Needs you** first (Figma R9W19Jakt19nKs1yM5GEde 38:3, the shared
/// rules on the Mac's 91:1156).
///
/// The greeting says how many kinds of thing need the owner, and the list under
/// it has one row per kind with the action that deals with it (`NeedsYou`).
/// Then the figures — Owed, On the machines, the month's money — and the open
/// jobs due this week, each swiped forward to advance. A figure the phone
/// cannot work out is not drawn; the counts and the pipeline live in Orders.
///
/// The header's **+** opens the redesign's New sheet (`NewSheet`): a new job,
/// a file to quote, a spool, the calculator, an expense, waste, and below them
/// the rest of what the old + menu held.
struct DashboardView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var printers: LivePrinters
    @EnvironmentObject private var health: ConnectionHealth
    @EnvironmentObject private var ordersNav: OrdersNavigationState

    @State private var pulse: ShopPulse?
    @State private var queue: [QueueOrder] = []
    @State private var facts: [String: OrderFacts] = [:]
    @State private var openOrder: QueueOrder?
    @ObservedObject private var feed = ShopFeed.shared
    @State private var spools: [InventorySpool] = []
    @State private var waiting: [WaitingListItem] = []
    @State private var quotes: [OrderLogEntry]?
    /// Whether the first load has come back: until it has, the greeting says
    /// only hello, rather than "nothing needs you" about a book not yet read.
    @State private var loaded = false
    @State private var updatingId: String?
    @State private var moveNotes: [String] = []
    /// Why the queue could not be read, when it could not: Home said "Queue
    /// clear" for a failed read (F3). Nil once a read succeeds.
    @State private var queueError: String?
    @State private var showAddSpool = false
    @State private var showQuote = false
    @State private var showLibrary = false
    @State private var showCatalogue = false
    @State private var showEndOfDay = false
    @State private var showWaste = false
    @State private var showExpense = false
    @State private var showIntake = false
    @State private var pickingModel = false
    @State private var quotingFile: QuotedFile?
    @State private var scanningLabel = false
    @State private var scannedSpool: InventorySpool?
    @State private var labelProblem: String?
    @State private var showSettings = false
    /// The New sheet, and what was picked in it — presented once it closes.
    @State private var showNew = false
    @State private var newChoice: NewSheet.Choice?
    @State private var showNewOrder = false
    @State private var machines: [MachineInfo] = []
    /// Settings is a sidebar-only tab (see `MainTabView`). Where there is no
    /// sidebar — compact width: an iPhone, iPhone Duo's outer display — it
    /// opens from here.
    @Environment(\.horizontalSizeClass) private var widthClass
    @State private var fold: FoldGap?

    private var needs: NeedsYou.Summary {
        NeedsYou.summary(queue: queue, spools: spools, waiting: waiting, quotes: quotes)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    // Regular width — iPhone Duo's inner display — puts the
                    // shop's figures beside its work: the same sections, in the
                    // same order, rearranged into two columns where there is
                    // room (Apple's iPhone Duo design talk: a stacked layout
                    // "that rearranges itself into a two-column layout").
                    // Partly folded, the two columns meet at the fold rather
                    // than straddling it (see `FoldGap`).
                    if widthClass == .regular {
                        FoldColumns(fold: fold) {
                            VStack(alignment: .leading, spacing: 0) { attention }
                                .frame(maxWidth: .infinity, alignment: .top)
                            VStack(alignment: .leading, spacing: 0) { figures }
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                        .readsFold($fold)
                    } else {
                        attention
                        figures
                    }
                }
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .moveNotes($moveNotes)
            .refreshable { await load() }
            .task { await load() }
            .watchesPrinters(when: queue.contains { $0.status == "printing" && $0.machineId != nil })
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNew, onDismiss: openNewChoice) {
                NewSheet(holdsBook: api.holdsBook) { newChoice = $0 }
            }
            .sheet(isPresented: $showNewOrder) {
                NewOrderSheet(machines: machines) { Task { await load() } }
            }
            .sheet(isPresented: $showAddSpool) { AddSpoolSheet { Task { await load() } } }
            .sheet(isPresented: $showQuote) { CalculatorScreen(asSheet: true) }
            .sheet(isPresented: $showLibrary) { LibraryView() }
            .sheet(isPresented: $showCatalogue) { CatalogueView() }
            .sheet(isPresented: $showEndOfDay) { NavigationStack { EndOfDayView() } }
            .sheet(isPresented: $showWaste) { LogWasteSheet() }
            .sheet(isPresented: $showExpense) { ExpenseSheet() }
            .sheet(isPresented: $showIntake) { IntakeView() }
            .fileImporter(isPresented: $pickingModel, allowedContentTypes: QuoteFileSheet.types) { result in
                if case .success(let url) = result, let copy = QuotedFile.copy(url) { quotingFile = copy }
            }
            .sheet(item: $quotingFile) { QuoteFileSheet(file: $0.url) }
            .onChange(of: ordersNav.quoteFileRequest) { _, f in if let f { quotingFile = f; ordersNav.quoteFileRequest = nil } }
            .sheet(isPresented: $scanningLabel) {
                LabelScanner { code in Task { await follow(code) } }
            }
            .navigationDestination(item: $scannedSpool) { SpoolDetailPage(spool: $0) { await load() } }
            .alert(labelProblem ?? "", isPresented: Binding(get: { labelProblem != nil }, set: { if !$0 { labelProblem = nil } })) {
                Button(L10n.tr("common.close"), role: .cancel) {}
            }
            .navigationDestination(item: $openOrder) { order in
                OrderDetailPage(order: order, facts: facts[order.id]) { await load() }
            }
        }
    }

    /// What the New sheet chose, once it has closed.
    private func openNewChoice() {
        guard let choice = newChoice else { return }
        newChoice = nil
        switch choice {
        case .job:
            Task {
                if machines.isEmpty { machines = (try? await api.fetchMachines()) ?? [] }
                showNewOrder = true
            }
        case .quoteFile: pickingModel = true
        case .spool: showAddSpool = true
        case .calculator: showQuote = true
        case .expense: showExpense = true
        case .waste: showWaste = true
        case .scanLabel: scanningLabel = true
        case .library: showLibrary = true
        case .catalogue: showCatalogue = true
        case .endOfDay: showEndOfDay = true
        }
    }

    // MARK: - The two halves of Home

    /// What needs the owner: the list under the greeting, or one calm line.
    @ViewBuilder private var attention: some View {
        if queue.isEmpty, let queueError {
            // The queue could not be read: that is not "nothing needs you".
            LoadFailedView(message: queueError) { await load() }
                .padding(.horizontal, 16)
        } else if needs.isCalm {
            if loaded {
                Text(L10n.tr("needs.calm"))
                    .font(.khayt(14, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        } else {
            section(L10n.tr("needs.title"))
            needsList
        }
    }

    /// The shop's figures, then the work due this week.
    @ViewBuilder private var figures: some View {
        tiles
        money
        dueWeek
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                // Today's date as a mono eyebrow, Gregorian.
                Text(dateLine)
                    .font(L10n.usesArabicLayout ? .khayt(12, .semibold, relativeTo: .caption) : .khaytMono(11, .medium))
                    .khaytTracking(0.8)
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                headerButtons
            }
            // The greeting carries the count: "Good morning. 3 things need you."
            Text(greeting)
                .font(.khaytDisplay(30, .bold, relativeTo: .largeTitle))
                .tracking(-0.6)
                .foregroundStyle(KhaytDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var greeting: String {
        let hello = L10n.tr(NeedsYou.greetingKey(hour: Calendar(identifier: .gregorian).component(.hour, from: Date())))
        guard loaded, !(queue.isEmpty && queueError != nil) else { return hello }
        return hello + "\n" + (needs.isCalm ? L10n.tr("needs.none") : L10n.count("needs.count", needs.total))
    }

    @ViewBuilder private var headerButtons: some View {
        if widthClass == .compact {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(KhaytDesign.ink)
                    .frame(width: 44, height: 44)
                    .background(KhaytDesign.surface, in: Circle())
                    .overlay(Circle().strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            }
            .accessibilityLabel(L10n.tr("tab.settings"))
        }
        // The bell, with how many are unread.
        NavigationLink {
            NotificationsView()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(KhaytDesign.ink)
                    .frame(width: 44, height: 44)
                    .background(KhaytDesign.surface, in: Circle())
                    .overlay(Circle().strokeBorder(KhaytDesign.hairline, lineWidth: 1))
                if feed.unreadCount > 0 {
                    Text("\(min(feed.unreadCount, 99))")
                        .font(.khayt(10, .bold, relativeTo: .caption2).monospacedDigit())
                        .foregroundStyle(KhaytDesign.ground)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(KhaytDesign.late, in: Capsule())
                        .offset(x: 2, y: -2)
                }
            }
        }
        .accessibilityLabel(L10n.tr("feed.title"))
        .accessibilityValue(feed.unreadCount > 0 ? L10n.format("feed.unread_count", feed.unreadCount) : "")
        Button { showNew = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(KhaytDesign.onBrand)
                .frame(width: 44, height: 44)
                .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(L10n.tr("new.title"))
    }

    /// "TUESDAY 3 NOVEMBER" — Gregorian whatever the phone's calendar, as the
    /// book is. The shop's name stays off it: beside three buttons it cut the
    /// date short.
    private var dateLine: String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: L10n.locale,
                                     calendar: Calendar(identifier: .gregorian))
            .weekday(.wide).day().month(.wide)
        style.timeZone = .current
        let date = Date().formatted(style)
        return L10n.usesArabicLayout ? date : date.uppercased()
    }

    // MARK: - Needs you

    /// Steel: waiting on someone else.
    private static let steel = Color(light: 0x5E6C84, dark: 0xA9B8CF)

    private func color(_ tone: NeedsYou.Tone) -> Color {
        switch tone {
        case .late: return KhaytDesign.late
        case .today: return KhaytDesign.thread
        case .waitingOnOthers: return Self.steel
        }
    }

    /// One row per kind, each with the action that deals with it.
    private var needsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(needs.shown.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                needsRow(row)
            }
            if needs.more > 0 {
                Rectangle().fill(KhaytDesign.hairline).frame(height: 1)
                Text(L10n.count("needs.more", needs.more))
                    .font(.khayt(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private func title(_ row: NeedsYou.Row) -> String {
        switch row.kind {
        case .late: return L10n.count("needs.late", row.count)
        case .lowStock: return L10n.tr("needs.low.title")
        case .waiting: return L10n.count("pulse.waiting", row.count)
        case .quotes: return L10n.count("needs.quotes", row.count)
        }
    }

    private func actionTitle(_ kind: NeedsYou.Kind) -> String {
        switch kind {
        case .late: return L10n.tr("needs.late.action")
        case .lowStock: return L10n.tr("needs.low.action")
        case .waiting: return L10n.tr("needs.waiting.action")
        case .quotes: return L10n.tr("needs.quotes.action")
        }
    }

    /// Where a row goes: the filtered list it names.
    private func open(_ kind: NeedsYou.Kind) {
        switch kind {
        case .late: ordersNav.openOverdue()
        case .lowStock: ordersNav.openLowStock()
        case .waiting: showIntake = true
        case .quotes: ordersNav.openOrders(filter: .quote)
        }
    }

    private func needsRow(_ row: NeedsYou.Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The row itself opens the list; the button says what it does.
            Button { open(row.kind) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(color(row.tone)).frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(row))
                            .font(.khayt(16, .semibold, relativeTo: .body))
                            .foregroundStyle(KhaytDesign.ink)
                        Text(row.detail)
                            .font(.khayt(13, relativeTo: .footnote))
                            .foregroundStyle(KhaytDesign.note)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(actionTitle(row.kind))
            Button { open(row.kind) } label: {
                Text(actionTitle(row.kind))
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Figures

    /// Owed and On the machines. A figure this phone cannot work out is not
    /// drawn — no dashes.
    @ViewBuilder private var tiles: some View {
        let machinesFigure = NeedsYou.onTheMachines(machines, queue: queue)
        if pulse != nil || machinesFigure != nil {
            HStack(alignment: .top, spacing: 10) {
                if let pulse {
                    NavigationLink { OwedView() } label: {
                        tile(L10n.tr("tile.owed"), value: amount(pulse.owed),
                             sub: L10n.format("pulse.unpaid", pulse.unpaid))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.tr("owed.open.hint"))
                }
                if let m = machinesFigure {
                    Button { ordersNav.openMachines() } label: {
                        tile(L10n.tr("tile.machines"),
                             value: L10n.format("tile.machines.value", m.busy, m.of),
                             sub: L10n.tr("tile.machines.sub"))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private func tile(_ label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.khayt(13, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.note)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(value)
                .font(.khaytDisplay(26, .bold, relativeTo: .title).monospacedDigit())
                .foregroundStyle(KhaytDesign.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(sub)
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func amount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale))
    }

    private var currencyNote: String { pulse?.currency.map(Money.mark) ?? "" }

    /// The money, compact: this month large, then the year and what is owed on
    /// one line that opens who owes it. Not drawn when the phone has no pulse.
    @ViewBuilder private var money: some View {
        if let pulse {
            NavigationLink { OwedView() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.usesArabicLayout ? L10n.tr("pulse.this_month") : L10n.tr("pulse.this_month").uppercased())
                        .font(L10n.usesArabicLayout ? .khayt(12, .semibold, relativeTo: .caption) : .khaytMono(11, .medium))
                        .khaytTracking(0.8)
                        .foregroundStyle(KhaytDesign.onBrand.opacity(0.75))
                    if let month = pulse.thisMonth {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(amount(month))
                                .font(.khaytDisplay(36, .bold, relativeTo: .largeTitle).monospacedDigit())
                                .tracking(-1)
                                .lineLimit(1).minimumScaleFactor(0.5)
                            Text(currencyNote).font(.khaytMono(13, .medium))
                        }
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(maxWidth: .infinity, alignment: L10n.usesArabicLayout ? .trailing : .leading)
                    } else {
                        // Older than this phone's window: the Mac has it.
                        Text(L10n.tr("pulse.on_the_mac"))
                            .font(.khayt(17, .semibold, relativeTo: .headline))
                    }
                    HStack(spacing: 4) {
                        Text(moneyLine(pulse))
                            .font(.khayt(13, relativeTo: .footnote))
                            .lineLimit(2)
                        Image(systemName: "chevron.forward").font(.system(size: 10, weight: .bold))
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(KhaytDesign.onBrand.opacity(0.85))
                }
                .foregroundStyle(KhaytDesign.onBrand)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(L10n.tr("owed.open.hint"))
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    /// "550 this year · 515 owed · 5 unpaid" — the year only when the phone
    /// holds all of it.
    private func moneyLine(_ pulse: ShopPulse) -> String {
        var parts: [String] = []
        if let year = pulse.thisYear { parts.append(L10n.format("needs.this_year", amount(year))) }
        parts.append(L10n.format("needs.owed", amount(pulse.owed)))
        parts.append(L10n.format("pulse.unpaid", pulse.unpaid))
        return parts.joined(separator: " · ")
    }

    // MARK: - Due this week

    @ViewBuilder private var dueWeek: some View {
        let due = NeedsYou.dueThisWeek(queue)
        if !due.isEmpty {
            section(L10n.tr("needs.due_week"))
            VStack(spacing: 8) {
                ForEach(due.prefix(8)) { order in
                    JobCard(order: order, facts: facts[order.id], live: printers.reading(for: order.machineId), isUpdating: updatingId == order.id) {
                        Task { await advance(order) }
                    } onOpen: {
                        openOrder = order
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func section(_ title: String) -> some View {
        Text(L10n.usesArabicLayout ? title : title.uppercased())
            .font(L10n.usesArabicLayout ? .khayt(12, .bold, relativeTo: .caption2) : .khaytMono(11, .medium, relativeTo: .caption2))
            .khaytTracking(0.9)
            .foregroundStyle(KhaytDesign.note)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Loading and advancing

    private func load() async {
        async let queueTask: Result<[QueueOrder], Error> = {
            do { return .success(try await api.fetchQueue()) } catch { return .failure(error) }
        }()
        async let inventoryTask = try? api.fetchInventory()
        async let waitingTask = try? api.fetchWaitingList()
        async let pulseTask = api.fetchPulse()
        async let factsTask = api.fetchOrderFacts()
        async let machinesTask = try? api.fetchMachines()
        // Quotes only where the phone can see them: the native Mac serves no
        // `/api/orders`, and an unknown is not "no quotes".
        async let quotesTask = openQuotes()
        switch await queueTask {
        case .success(let jobs):
            queue = jobs
            queueError = nil
        case .failure(let error):
            // Keep what was last shown; say why it is not fresh.
            queueError = error.localizedDescription
        }
        spools = await inventoryTask ?? []
        waiting = await waitingTask ?? []
        pulse = await pulseTask
        facts = await factsTask
        machines = await machinesTask ?? []
        quotes = await quotesTask
        loaded = true
        // Spotlight and Siri find the jobs this phone holds.
        Task { await JobSearch.index() }
        // A sheet an App Intent asked for (Siri, Shortcuts, a Control).
        switch PendingAction.take() {
        case "waste": showWaste = true
        case "addspool": showAddSpool = true
        case "calculator": showQuote = true
        default: break
        }
        #if DEBUG
        for (name, show) in [("quote", { showQuote = true }), ("waste", { showWaste = true }),
                             ("expense", { showExpense = true }), ("addspool", { showAddSpool = true }),
                             ("intake", { showIntake = true }), ("settings", { showSettings = true }), ("new", { showNew = true }),
                             ("library", { showLibrary = true }), ("catalogue", { showCatalogue = true })] as [(String, () -> Void)] {
            if KhaytCompanionApp.ScreenshotOpen.take(name) != nil { show() }
        }
        if let id = KhaytCompanionApp.ScreenshotOpen.take("order:") {
            // An open job from the queue; a finished one from the recent jobs.
            openOrder = queue.first { $0.id == id }
            if openOrder == nil, let done = (try? await api.fetchRecentOrders(limit: 200))?.first(where: { $0.id == id }) {
                openOrder = QueueOrder(entry: done)
            }
        }
        #endif
    }

    /// The open quotes, or nil where this phone cannot see them.
    private func openQuotes() async -> [OrderLogEntry]? {
        guard api.holdsBook else { return nil }
        return try? await api.fetchRecentOrders(limit: 200, status: OrderStatus.quote.rawValue)
    }

    /// A scanned label: open the job or the spool it names, or say why not.
    private func follow(_ code: String) async {
        switch await api.followLabel(code) {
        case .order(let o): openOrder = o
        case .spool(let s): scannedSpool = s
        case .refused(let why): labelProblem = why
        }
    }

    private func advance(_ order: QueueOrder) async {
        guard let next = OrderStatus(rawValue: order.status)?.nextInQueue else { return }
        updatingId = order.id
        defer { updatingId = nil }
        do {
            moveNotes = try await api.updateOrderStatus(orderId: order.id, status: next.rawValue)
            CompanionHaptics.success()
            await load()
        } catch {
            // A failed move used to be a haptic and nothing else (F4).
            moveNotes = [error.localizedDescription]
            CompanionHaptics.warning()
        }
    }
}
