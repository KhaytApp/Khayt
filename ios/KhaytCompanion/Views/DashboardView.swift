import SwiftUI

/// Home — **Shop Pulse**, as `design/ios-v2/` draws it.
///
/// Three counts, the money, the pipeline, the rails that need a person, and the
/// first five jobs of the chosen lane, each swiped forward to advance. Money
/// the book cannot answer is an em-dash captioned "On the Mac" (see
/// `BookReader.pulse`), never a zero.
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

    @State private var status: ShopStatus?
    @State private var pulse: ShopPulse?
    @State private var queue: [QueueOrder] = []
    @State private var facts: [String: OrderFacts] = [:]
    @State private var openOrder: QueueOrder?
    @ObservedObject private var feed = ShopFeed.shared
    @State private var lowSpools: [InventorySpool] = []
    @State private var waiting: [WaitingListItem] = []
    @State private var lane: String = "all"
    @State private var updatingId: String?
    @State private var moveNotes: [String] = []
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

    private static let stages = ["pending", "printing", "post", "qc", "completed"]

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
                            VStack(alignment: .leading, spacing: 0) { figures }
                                .frame(maxWidth: .infinity, alignment: .top)
                            VStack(alignment: .leading, spacing: 0) { work.padding(.top, 14) }
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                        .readsFold($fold)
                    } else {
                        figures
                        work
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

    /// The shop's numbers: counts, money and the pipeline.
    @ViewBuilder private var figures: some View {
        money.padding(.top, 14)
        counts.padding(.top, 10)
        section(L10n.tr("home.pipeline"), trailing: L10n.tr("pulse.tap_to_filter"))
        lanes
    }

    /// What needs doing: the alerts and the jobs in the chosen lane.
    @ViewBuilder private var work: some View {
        alerts.padding(.top, 16)
        section(laneTitle, trailing: L10n.format("pulse.jobs", laneJobs.count))
        jobs
        Text(L10n.tr("pulse.swipe_hint"))
            .font(.khayt(11.5, relativeTo: .caption2))
            .foregroundStyle(KhaytDesign.note)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 14)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                // The redesign's header: today's date as a mono eyebrow over
                // the title, with the shop's name after it when it has one.
                Text(dateLine)
                    .font(L10n.usesArabicLayout ? .khayt(12, .semibold, relativeTo: .caption) : .khaytMono(11, .medium))
                    .khaytTracking(0.8)
                    .foregroundStyle(KhaytDesign.note)
                    // At the largest text sizes it shrank to "WEDNESDAY, 4 NOV…".
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(L10n.tr("pulse.title"))
                    .font(.khaytDisplay(30, .bold, relativeTo: .largeTitle))
                    .tracking(-0.6)
                    .foregroundStyle(KhaytDesign.ink)
                    // One line beside the buttons: it shrinks a little
                    // before it would wrap.
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
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
            // The design's bell, with how many are unread.
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
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
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

    // MARK: - Counts and money

    private var counts: some View {
        HStack(spacing: 8) {
            countTile(pulse?.inQueue ?? status?.pending, L10n.tr("stat.in_queue"), tint: KhaytDesign.ink, label: KhaytDesign.note, rail: nil)
            countTile(pulse?.printing ?? status?.printing, L10n.tr("pulse.printing"), tint: KhaytDesign.live, label: KhaytDesign.live, rail: KhaytDesign.live)
            countTile(pulse?.doneToday ?? status?.completedToday, L10n.tr("pulse.done_today"), tint: KhaytDesign.done, label: KhaytDesign.note, rail: nil)
        }
        .padding(.horizontal, 16)
    }

    private func countTile(_ value: Int?, _ label: String, tint: Color, label labelTint: Color, rail: Color?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.map { $0.formatted(.number.locale(L10n.locale)) } ?? "—")
                .font(.khayt(34, .semibold, relativeTo: .largeTitle).monospacedDigit())
                .foregroundStyle(value == nil ? KhaytDesign.note : tint)
                .environment(\.layoutDirection, .leftToRight)
            Text(L10n.usesArabicLayout ? label : label.uppercased())
                .font(L10n.usesArabicLayout ? .khayt(11, .bold, relativeTo: .caption2) : .khaytMono(10.5, .medium, relativeTo: .caption2))
                .khaytTracking(0.6)
                .foregroundStyle(labelTint)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.top, 12).padding(.bottom, 11)
        // The redesign's tile: a plain card, the live count marked by a
        // stroke in its colour rather than a rail.
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(rail.map { $0.opacity(0.45) } ?? KhaytDesign.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// The redesign's hero: this month's takings large on the brand blue,
    /// this year and what is owed beneath it. Owed still opens who owes it.
    private var money: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.usesArabicLayout ? L10n.tr("pulse.this_month") : L10n.tr("pulse.this_month").uppercased())
                .font(L10n.usesArabicLayout ? .khayt(12, .semibold, relativeTo: .caption) : .khaytMono(11, .medium))
                .khaytTracking(0.8)
                .foregroundStyle(KhaytDesign.onBrand.opacity(0.75))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(pulse?.thisMonth.map { $0.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale)) } ?? "—")
                    .font(.khaytDisplay(44, .bold, relativeTo: .largeTitle).monospacedDigit())
                    .tracking(-1.2)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(pulse?.thisMonth == nil ? L10n.tr("pulse.on_the_mac") : currencyNote)
                    .font(.khaytMono(13, .medium))
            }
            .foregroundStyle(KhaytDesign.onBrand)
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxWidth: .infinity, alignment: L10n.usesArabicLayout ? .trailing : .leading)
            .padding(.top, 4)
            Rectangle().fill(KhaytDesign.onBrand.opacity(0.18)).frame(height: 1).padding(.vertical, 12)
            HStack(spacing: 0) {
                heroFigure(pulse?.thisYear, L10n.tr("pulse.this_year"), note: currencyNote)
                NavigationLink { OwedView() } label: {
                    heroFigure(pulse.map { $0.owed }, L10n.tr("pulse.owed"),
                               note: pulse.map { L10n.format("pulse.unpaid", $0.unpaid) } ?? "", chevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pulse == nil)
                .accessibilityHint(L10n.tr("owed.open.hint"))
            }
        }
        .padding(18)
        .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func heroFigure(_ value: Double?, _ label: String, note: String, chevron: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(L10n.usesArabicLayout ? label : label.uppercased())
                    .font(L10n.usesArabicLayout ? .khayt(11, .semibold, relativeTo: .caption2) : .khaytMono(10, .medium, relativeTo: .caption2))
                    .khaytTracking(0.6)
                if chevron {
                    Image(systemName: "chevron.forward").font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(KhaytDesign.onBrand.opacity(0.75))
            Text(value.map { $0.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale)) } ?? "—")
                .font(.khaytDisplay(20, .semibold, relativeTo: .title3).monospacedDigit())
                .foregroundStyle(KhaytDesign.onBrand)
                .lineLimit(1).minimumScaleFactor(0.6)
                .environment(\.layoutDirection, .leftToRight)
            Text(value == nil ? L10n.tr("pulse.on_the_mac") : note)
                .font(.khayt(11.5, relativeTo: .caption2))
                .foregroundStyle(KhaytDesign.onBrand.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var currencyNote: String { pulse?.currency.map(Money.mark) ?? "" }

    // MARK: - Pipeline

    private func count(_ stage: String) -> Int {
        switch stage {
        case "all": return queue.count
        case "completed": return pulse?.doneToday ?? status?.completedToday ?? 0
        default: return queue.filter { $0.status == stage }.count
        }
    }

    private var lanes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(["all"] + Self.stages, id: \.self) { id in
                    let tone = id == "all" ? KhaytDesign.brand : KhaytDesign.statusColor(for: id)
                    let on = lane == id
                    let n = count(id)
                    Button {
                        if id == "completed" {
                            ordersNav.openOrders(filter: .completed)
                        } else {
                            lane = id
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text("\(n)")
                                .font(.khayt(21, .semibold, relativeTo: .title3).monospacedDigit())
                            Text(id == "all" ? L10n.tr("orders.filter.all") : L10n.tr("stage.short.\(id)"))
                                .font(.khayt(9.5, .bold, relativeTo: .caption2))
                                .khaytTracking(0.8)
                        }
                        .foregroundStyle(on ? tone : (n > 0 || id == "all" ? KhaytDesign.ink : KhaytDesign.note))
                        .frame(minWidth: 60, minHeight: 64)
                        .padding(.horizontal, 8)
                        .background(on ? tone.opacity(0.16) : KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(on ? tone.opacity(0.55) : KhaytDesign.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .clipShape(Rectangle())
    }

    // MARK: - Rails that need a person

    @ViewBuilder
    private var alerts: some View {
        let late = queue.filter(\.isOverdue)
        if !late.isEmpty || !lowSpools.isEmpty || !waiting.isEmpty {
            VStack(spacing: 0) {
                if !late.isEmpty {
                    alertRail(tone: KhaytDesign.late, icon: "clock.badge.exclamationmark",
                              title: L10n.count("pulse.late", late.count),
                              sub: late.map(\.displayTitle).joined(separator: " · ")) {
                        ordersNav.openOrders()
                    }
                }
                if !lowSpools.isEmpty {
                    if !late.isEmpty { KhaytThreadDivider().padding(.leading, 64) }
                    alertRail(tone: KhaytDesign.attention, icon: "cylinder.split.1x2",
                              title: L10n.count("pulse.low_stock", lowSpools.count),
                              sub: lowSpools.map { spool in
                                  let grams = Int((spool.remainingGrams ?? 0).rounded())
                                  return "\(spool.displayLabel) · \(L10n.grams(grams))"
                              }.joined(separator: " · ")) {
                        ordersNav.openLowStock()
                    }
                }
                if !waiting.isEmpty {
                    if !late.isEmpty || !lowSpools.isEmpty { KhaytThreadDivider().padding(.leading, 64) }
                    alertRail(tone: KhaytDesign.brand, icon: "tray.and.arrow.down",
                              title: L10n.count("pulse.waiting", waiting.count),
                              sub: waiting.map(\.displayClient).joined(separator: " · ")) {
                        showIntake = true
                    }
                }
            }
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            .padding(.horizontal, 16)
        }
    }

    /// A "needs you" row: the tone in a soft tile, the words in ink.
    private func alertRail(tone: Color, icon: String, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone)
                    .frame(width: 38, height: 38)
                    .background(tone.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.khayt(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.ink)
                    Text(sub)
                        .font(.khayt(12.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KhaytDesign.note)
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Jobs

    private var laneJobs: [QueueOrder] {
        lane == "all" ? queue : queue.filter { $0.status == lane }
    }

    private var laneTitle: String {
        lane == "all" ? L10n.tr("tab.orders") : L10n.tr("stage.short.\(lane)")
    }

    @ViewBuilder
    private var jobs: some View {
        if laneJobs.isEmpty {
            VStack(spacing: 5) {
                Text(L10n.tr("orders.queue_clear")).font(.khayt(15, .semibold, relativeTo: .headline)).foregroundStyle(KhaytDesign.ink)
                Text(L10n.tr("orders.queue_clear.sub")).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        } else {
            VStack(spacing: 8) {
                ForEach(laneJobs.prefix(5)) { order in
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

    private func section(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.usesArabicLayout ? title : title.uppercased())
                .font(L10n.usesArabicLayout ? .khayt(12, .bold, relativeTo: .caption2) : .khaytMono(11, .medium, relativeTo: .caption2))
                .khaytTracking(0.9)
                .foregroundStyle(KhaytDesign.note)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Loading and advancing

    private func load() async {
        async let statusTask = try? api.fetchStatus()
        async let queueTask = try? api.fetchQueue()
        async let inventoryTask = try? api.fetchInventory()
        async let waitingTask = try? api.fetchWaitingList()
        async let pulseTask = api.fetchPulse()
        async let factsTask = api.fetchOrderFacts()
        status = await statusTask
        queue = await queueTask ?? []
        lowSpools = (await inventoryTask ?? []).filter(\.isLowStock)
        waiting = await waitingTask ?? []
        pulse = await pulseTask
        facts = await factsTask
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
        if let id = KhaytCompanionApp.ScreenshotOpen.take("order:") { openOrder = queue.first { $0.id == id } }
        #endif
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
            CompanionHaptics.warning()
        }
    }
}
