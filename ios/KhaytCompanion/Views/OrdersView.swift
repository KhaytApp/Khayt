import SwiftUI

/// The shop's orders, as `design/ios-v2/` draws them: Active and History as a
/// segmented pair, stage chips beneath, and a list of cards — each swiped
/// forward to move the job on, and tapped to open its page.
///
/// History is WINDOWED. The phone holds every unfinished order and the newest
/// finished ones, so the list ends with a line saying how many of how many it
/// shows, and where the rest are. Without it the list simply stops, and a shop
/// that scrolls to the bottom concludes it has done two hundred jobs in its
/// life.
struct OrdersView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var printers: LivePrinters
    @EnvironmentObject private var ordersNav: OrdersNavigationState

    enum Segment: String, CaseIterable, Identifiable {
        case active
        case history
        var id: String { rawValue }
        var title: String { L10n.tr(self == .active ? "orders.active" : "orders.history") }
    }

    /// A chip. `.overdue` is not one of the design's: it appears only when Home's
    /// late alert sent you here, so the list you land on is the one it named.
    enum Chip: Hashable {
        case all
        case stage(OrderStatus)
        case overdue
    }

    @State private var segment: Segment = .active
    @State private var chip: Chip = .all
    @State private var queue: [QueueOrder] = []
    @State private var history: [OrderLogEntry] = []
    @State private var facts: [String: OrderFacts] = [:]
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var updatingId: String?
    @State private var openOrder: QueueOrder?
    @State private var showIntake = false
    @State private var showNewOrder = false
    @State private var machines: [MachineInfo] = []
    @State private var loadGeneration = 0

    private var chips: [Chip] {
        switch segment {
        case .active:
            var ids: [Chip] = [.all] + [OrderStatus.pending, .printing, .post, .qc].map(Chip.stage)
            if chip == .overdue { ids.append(.overdue) }
            return ids
        case .history:
            return [.all, .stage(.completed)]
        }
    }

    private static let finished: Set<String> = ["completed", "delivered", "shipped", "cancelled"]

    private var rows: [QueueOrder] {
        // History is finished work. The book's list holds every order, open
        // ones included, and those are on the Active side already.
        let pool = segment == .active ? queue
            : history.filter { Self.finished.contains($0.status) }.map(QueueOrder.init(entry:))
        switch chip {
        case .all: return pool
        case .stage(let st): return pool.filter { $0.status == st.rawValue }
        case .overdue: return pool.filter(\.isOverdue)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    segmentPicker
                    chipRow
                    list
                    if segment == .history, let window = api.historyWindow {
                        windowLine(window)
                    }
                }
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .khaytScreen(title: L10n.tr("tab.orders"))
            .background(KhaytDesign.ground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showIntake = true } label: { Image(systemName: "tray.and.arrow.down") }
                        .accessibilityLabel(L10n.tr("intake.title"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewOrder = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L10n.tr("order.new.title"))
                }
            }
            .sheet(isPresented: $showIntake) { IntakeView() }
            .sheet(isPresented: $showNewOrder) {
                NewOrderSheet(machines: machines) { Task { await load() } }
            }
            .navigationDestination(item: $openOrder) { order in
                OrderDetailPage(order: order, facts: facts[order.id]) { await load() }
            }
            .refreshable { await load() }
            .task(id: segment) { await load() }
            .watchesPrinters(when: segment == .active
                             && queue.contains { $0.status == "printing" && $0.machineId != nil })
            .onAppear { applyExternalFilters() }
            .onChange(of: ordersNav.pendingStatusFilter) { _, _ in applyExternalFilters() }
            .onChange(of: ordersNav.ordersTabRequest) { _, _ in applyExternalFilters() }
        }
    }

    private func applyExternalFilters() {
        if let pending = ordersNav.pendingStatusFilter {
            if pending == .completed {
                segment = .history
                chip = .stage(.completed)
            } else {
                segment = .active
                chip = .stage(pending)
            }
            ordersNav.pendingStatusFilter = nil
            Task { await load() }
        } else if UserDefaults.standard.string(forKey: "khayt.orders.filter") == "orders_overdue" {
            segment = .active
            chip = .overdue
            UserDefaults.standard.removeObject(forKey: "khayt.orders.filter")
        }
    }

    // MARK: - Parts

    private var segmentPicker: some View {
        HStack(spacing: 3) {
            ForEach(Segment.allCases) { s in
                let on = s == segment
                Button {
                    segment = s
                    chip = .all
                } label: {
                    Text(s.title)
                        .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? KhaytDesign.ink : KhaytDesign.note)
                        .background(on ? KhaytDesign.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(chips, id: \.self) { c in
                    let on = c == chip
                    let tone = self.tone(c)
                    Button { chip = c } label: {
                        Text(title(c))
                            .font(.khayt(13, .semibold, relativeTo: .subheadline))
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .foregroundStyle(on ? tone : KhaytDesign.note)
                            .background(on ? tone.opacity(0.16) : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? tone.opacity(0.5) : KhaytDesign.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 14)
    }

    private func title(_ c: Chip) -> String {
        switch c {
        case .all: return L10n.tr("orders.filter.all")
        case .stage(let st): return st.localizedLabel
        case .overdue: return L10n.tr("orders.overdue")
        }
    }

    private func tone(_ c: Chip) -> Color {
        switch c {
        case .all: return KhaytDesign.brand
        case .stage(let st): return KhaytDesign.statusColor(for: st.rawValue)
        case .overdue: return KhaytDesign.late
        }
    }

    @ViewBuilder
    private var list: some View {
        if !loaded && errorMessage == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 44)
        } else if rows.isEmpty {
            VStack(spacing: 5) {
                Text(emptyTitle)
                    .font(.khayt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(errorMessage ?? emptyBody)
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44).padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(rows) { order in
                    JobCard(order: order, facts: facts[order.id], live: printers.reading(for: order.machineId), layout: .full,
                            isUpdating: updatingId == order.id) {
                        Task { await advance(order) }
                    } onOpen: {
                        openOrder = order
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyTitle: String {
        L10n.tr(segment == .history ? "orders.no_completed" : "orders.queue_clear")
    }

    private var emptyBody: String {
        L10n.tr(segment == .history ? "orders.no_completed.sub" : "orders.queue_clear.sub")
    }

    /// The design's window line: a count, then where the rest of it is.
    private func windowLine(_ window: HeldWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: L10n.tr("orders.window.count"),
                        window.sent.formatted(), window.available.formatted()))
                .font(.khayt(12.5, .semibold, relativeTo: .footnote).monospacedDigit())
                .foregroundStyle(KhaytDesign.ink)
            Text(String(format: L10n.tr("orders.window.body"), window.sent.formatted()))
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    // MARK: - Loading and writing

    private func load() async {
        let generation = loadGeneration + 1
        loadGeneration = generation
        errorMessage = nil
        if machines.isEmpty {
            machines = (try? await api.fetchMachines()) ?? []
        }
        async let factsTask = api.fetchOrderFacts()
        do {
            switch segment {
            case .active:
                let data = try await api.fetchQueue()
                guard generation == loadGeneration else { return }
                queue = data
            case .history:
                let data = try await api.fetchRecentOrders(limit: 200)
                guard generation == loadGeneration else { return }
                history = data
            }
        } catch {
            guard generation == loadGeneration else { return }
            if segment == .active { queue = [] } else { history = [] }
            errorMessage = error.localizedDescription
        }
        facts = await factsTask
        loaded = true
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
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}

/// The red "late" tag beside a job.
struct LateBadge: View {
    var body: some View {
        Text(L10n.tr("orders.late"))
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .tracking(0.6)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(KhaytDesign.late)
            .background(KhaytDesign.late.opacity(0.14), in: Capsule())
    }
}
