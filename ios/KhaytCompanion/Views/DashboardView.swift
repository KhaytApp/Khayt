import SwiftUI

/// Home — **Shop Pulse**, as `design/ios-v2/` draws it.
///
/// Three counts, the money, the pipeline, the rails that need a person, and the
/// first five jobs of the chosen lane, each swiped forward to advance. Money
/// the book cannot answer is an em-dash captioned "On the Mac" (see
/// `BookReader.pulse`), never a zero.
///
/// One departure from the prototype, on purpose: the header keeps a **+** menu
/// for Quote, Waste, Expense and Add spool. Those ship today and the prototype
/// has not placed them yet ("Left: waste, expense, quote" in its own notes);
/// dropping them from home would take features away to match a design that has
/// not got to them.
struct DashboardView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth
    @EnvironmentObject private var ordersNav: OrdersNavigationState

    @State private var status: ShopStatus?
    @State private var pulse: ShopPulse?
    @State private var queue: [QueueOrder] = []
    @State private var facts: [String: OrderFacts] = [:]
    @State private var openOrder: QueueOrder?
    @State private var lowSpools: [InventorySpool] = []
    @State private var waiting: [WaitingListItem] = []
    @State private var lane: String = "all"
    @State private var updatingId: String?
    @State private var showAddSpool = false
    @State private var showQuote = false
    @State private var showWaste = false
    @State private var showExpense = false
    @State private var showIntake = false

    private static let stages = ["pending", "printing", "post", "qc", "completed"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    counts.padding(.top, 14)
                    section(L10n.tr("pulse.money"))
                    money
                    section(L10n.tr("home.pipeline"), trailing: L10n.tr("pulse.tap_to_filter"))
                    lanes
                    alerts.padding(.top, 16)
                    section(laneTitle, trailing: String(format: L10n.tr("pulse.jobs"), laneJobs.count))
                    jobs
                    Text(L10n.tr("pulse.swipe_hint"))
                        .font(.khayt(11.5, relativeTo: .caption2))
                        .foregroundStyle(KhaytDesign.note)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                }
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showAddSpool) { AddSpoolSheet { Task { await load() } } }
            .sheet(isPresented: $showQuote) { QuoteSheet() }
            .sheet(isPresented: $showWaste) { LogWasteSheet() }
            .sheet(isPresented: $showExpense) { ExpenseSheet() }
            .sheet(isPresented: $showIntake) { IntakeView() }
            .navigationDestination(item: $openOrder) { order in
                OrderDetailPage(order: order, facts: facts[order.id]) { await load() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            HStack(spacing: 11) {
                Image("KhaytMark")
                    .resizable().scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text((settings.shopLabel.isEmpty ? "Khayt" : settings.shopLabel).uppercased())
                        .font(.khayt(11, .bold, relativeTo: .caption2))
                        .tracking(1.1)
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                    Text(L10n.tr("pulse.title"))
                        .font(.khayt(27, .semibold, relativeTo: .largeTitle))
                        .foregroundStyle(KhaytDesign.ink)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button { showQuote = true } label: { Label(L10n.tr("home.action.quote"), systemImage: "tag") }
                Button { showWaste = true } label: { Label(L10n.tr("home.action.waste"), systemImage: "trash") }
                Button { showExpense = true } label: { Label(L10n.tr("home.action.expense"), systemImage: "doc.text.viewfinder") }
                Button { showAddSpool = true } label: { Label(L10n.tr("home.action.add_spool"), systemImage: "cylinder") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(KhaytDesign.ink)
                    .frame(width: 44, height: 44)
                    .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            }
            .accessibilityLabel(L10n.tr("home.quick_actions"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    // MARK: - Counts and money

    private var counts: some View {
        HStack(spacing: 8) {
            countTile(pulse?.inQueue ?? status?.pending, L10n.tr("stat.in_queue"), tint: KhaytDesign.ink, label: KhaytDesign.note, rail: nil)
            countTile(pulse?.printing ?? status?.printing, L10n.tr("pulse.printing"), tint: KhaytDesign.hot, label: KhaytDesign.hot, rail: KhaytDesign.hot)
            countTile(pulse?.doneToday ?? status?.completedToday, L10n.tr("pulse.done_today"), tint: KhaytDesign.done, label: KhaytDesign.note, rail: nil)
        }
        .padding(.horizontal, 16)
    }

    private func countTile(_ value: Int?, _ label: String, tint: Color, label labelTint: Color, rail: Color?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.map(String.init) ?? "—")
                .font(.khayt(34, .semibold, relativeTo: .largeTitle).monospacedDigit())
                .foregroundStyle(value == nil ? KhaytDesign.note : tint)
                .environment(\.layoutDirection, .leftToRight)
            Text(label.uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(labelTint)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.top, 12).padding(.bottom, 11)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if let rail { Rectangle().fill(rail).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var money: some View {
        HStack(spacing: 0) {
            moneyFigure(pulse.map { $0.owed }, L10n.tr("pulse.owed"),
                        note: pulse.map { String(format: L10n.tr("pulse.unpaid"), $0.unpaid) } ?? "",
                        tint: KhaytDesign.attention)
            Rectangle().fill(KhaytDesign.hairline).frame(width: 1)
            moneyFigure(pulse?.thisMonth, L10n.tr("pulse.this_month"), note: currencyNote, tint: KhaytDesign.done)
            Rectangle().fill(KhaytDesign.hairline).frame(width: 1)
            moneyFigure(pulse?.thisYear, L10n.tr("pulse.this_year"), note: currencyNote, tint: KhaytDesign.done)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private var currencyNote: String { pulse?.currency.map(Money.mark) ?? "" }

    /// A figure, or the design's deferred figure: an em-dash in quiet ink,
    /// captioned with where the answer lives. It keeps its slot and size.
    private func moneyFigure(_ value: Double?, _ label: String, note: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                .font(.khayt(25, .semibold, relativeTo: .title).monospacedDigit())
                .foregroundStyle(value == nil ? KhaytDesign.note : tint)
                .lineLimit(1).minimumScaleFactor(0.6)
                .environment(\.layoutDirection, .leftToRight)
            Text(label.uppercased())
                .font(.khayt(9.5, .bold, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(KhaytDesign.note)
                .padding(.top, 6)
            Text(value == nil ? L10n.tr("pulse.on_the_mac") : note)
                .font(.khayt(11, relativeTo: .caption2))
                .foregroundStyle(value == nil ? KhaytDesign.attention : KhaytDesign.note)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

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
                                .tracking(0.8)
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
    }

    // MARK: - Rails that need a person

    @ViewBuilder
    private var alerts: some View {
        let late = queue.filter(\.isOverdue)
        if !late.isEmpty || !lowSpools.isEmpty || !waiting.isEmpty {
            VStack(spacing: 8) {
                if !late.isEmpty {
                    alertRail(tone: KhaytDesign.late,
                              title: L10n.count("pulse.late", late.count),
                              sub: late.map(\.displayTitle).joined(separator: " · ")) {
                        ordersNav.openOrders()
                    }
                }
                if !lowSpools.isEmpty {
                    alertRail(tone: KhaytDesign.attention,
                              title: L10n.count("pulse.low_stock", lowSpools.count),
                              sub: lowSpools.map { spool in
                                  let grams = Int((spool.remainingGrams ?? 0).rounded())
                                  return "\(spool.displayLabel) · \(grams) \(L10n.tr("unit.g"))"
                              }.joined(separator: " · ")) {
                        ordersNav.openLowStock()
                    }
                }
                if !waiting.isEmpty {
                    alertRail(tone: KhaytDesign.attention,
                              title: L10n.count("pulse.waiting", waiting.count),
                              sub: waiting.map(\.displayClient).joined(separator: " · ")) {
                        showIntake = true
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func alertRail(tone: Color, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(tone)
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
            .padding(.vertical, 11).padding(.leading, 16).padding(.trailing, 13)
            .frame(minHeight: 56)
            .background(tone.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            .overlay(alignment: .leading) { Rectangle().fill(tone).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(tone.opacity(0.32), lineWidth: 1))
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
                    JobCard(order: order, facts: facts[order.id], isUpdating: updatingId == order.id) {
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
            Text(title.uppercased())
                .font(.khayt(11, .bold, relativeTo: .caption2))
                .tracking(1.1)
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
    }

    private func advance(_ order: QueueOrder) async {
        guard let next = OrderStatus(rawValue: order.status)?.nextInQueue else { return }
        updatingId = order.id
        defer { updatingId = nil }
        do {
            try await api.updateOrderStatus(orderId: order.id, status: next.rawValue)
            CompanionHaptics.success()
            await load()
        } catch {
            CompanionHaptics.warning()
        }
    }
}
