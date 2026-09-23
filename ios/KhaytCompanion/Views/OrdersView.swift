import SwiftUI

/// Active production queue + recent order history.
struct OrdersView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var ordersNav: OrdersNavigationState

    enum Segment: String, CaseIterable, Identifiable {
        case active
        case recent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .active: return L10n.tr("orders.active")
            case .recent: return L10n.tr("orders.recent")
            }
        }
    }

    enum ActiveFilter: Equatable {
        case all
        case status(OrderStatus)
        case overdue
    }

    @State private var segment: Segment = .active
    @State private var queue: [QueueOrder] = []
    @State private var recent: [OrderLogEntry] = []
    @State private var activeFilter: ActiveFilter = .all
    @State private var recentStatusFilter: String?
    @State private var errorMessage: String?
    @State private var updatingId: String?
    @State private var selectedOrder: QueueOrder?
    @State private var showIntake = false
    @State private var showNewOrder = false
    @State private var machines: [MachineInfo] = []
    @State private var loadGeneration = 0

    private var filteredQueue: [QueueOrder] {
        switch activeFilter {
        case .all: return queue
        case .status(let st): return queue.filter { $0.status == st.rawValue }
        case .overdue: return queue.filter(\.isOverdue)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Orders", selection: $segment) {
                    ForEach(Segment.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if segment == .active {
                    activeContent
                } else {
                    recentContent
                }
            }
            .khaytScreen(title: L10n.tr("tab.orders"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showIntake = true } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewOrder = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { ConnectionBadge() }
            }
            .sheet(isPresented: $showIntake) { IntakeView() }
            .sheet(isPresented: $showNewOrder) {
                NewOrderSheet(machines: machines) { Task { await load() } }
            }
            .refreshable { await load() }
            .task(id: segment) { await load() }
            .onAppear { applyExternalFilters() }
            .onChange(of: ordersNav.pendingStatusFilter) { _, _ in applyExternalFilters() }
            .onChange(of: ordersNav.ordersTabRequest) { _, _ in applyExternalFilters() }
            .sheet(item: $selectedOrder) { order in
                OrderDetailSheet(
                    order: order,
                    isUpdating: updatingId == order.id,
                    machines: machines,
                    onAdvance: { Task { await advance(order) } },
                    onSetStatus: { status in Task { await setStatus(order, status: status) } },
                    onAssignMachine: { machineId in Task { await assignMachine(order, machineId: machineId) } }
                )
            }
        }
    }

    private func applyExternalFilters() {
        if let pending = ordersNav.pendingStatusFilter {
            if pending == .completed {
                segment = .recent
                recentStatusFilter = OrderStatus.completed.rawValue
                activeFilter = .all
            } else {
                activeFilter = .status(pending)
                segment = .active
                recentStatusFilter = nil
            }
            ordersNav.pendingStatusFilter = nil
            Task { await load() }
        } else if UserDefaults.standard.string(forKey: "khayt.orders.filter") == "orders_overdue" {
            activeFilter = .overdue
            segment = .active
            recentStatusFilter = nil
            UserDefaults.standard.removeObject(forKey: "khayt.orders.filter")
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        if !queue.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: L10n.tr("orders.filter.all"), count: queue.count,
                               tint: KhaytDesign.brand, selected: activeFilter == .all) { activeFilter = .all }
                    ForEach([OrderStatus.pending, .printing, .post, .qc], id: \.self) { st in
                        FilterChip(title: st.localizedLabel,
                                   count: queue.filter { $0.status == st.rawValue }.count,
                                   tint: KhaytDesign.statusColor(for: st.rawValue),
                                   dot: true,
                                   selected: activeFilter == .status(st)) {
                            activeFilter = .status(st)
                        }
                    }
                    // Not a stage, so it goes last — but it is the one filter a
                    // shop reaches for when the dashboard says something is late.
                    let late = queue.filter(\.isOverdue).count
                    if late > 0 || activeFilter == .overdue {
                        FilterChip(title: L10n.tr("orders.overdue"), count: late,
                                   tint: KhaytDesign.danger, selected: activeFilter == .overdue) { activeFilter = .overdue }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 4)
        }

        Group {
            if queue.isEmpty && errorMessage == nil && segment == .active {
                ProgressView()
            } else if filteredQueue.isEmpty {
                ContentUnavailableView(
                    errorMessage == nil ? L10n.tr("orders.queue_clear") : L10n.tr("tab.orders"),
                    systemImage: errorMessage == nil ? "checkmark.circle" : "tray",
                    description: Text(errorMessage ?? L10n.tr("orders.queue_clear.sub"))
                )
            } else {
                List(filteredQueue) { order in
                    Button {
                        selectedOrder = order
                    } label: {
                        QueueOrderRow(order: order, isUpdating: updatingId == order.id)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(KhaytDesign.surface)
                    .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 16))
                    // `khayt-orders.jsx` SwipeRow: swipe left to move the job on.
                    // The action is named and coloured for the stage it moves TO,
                    // so a swipe says where the job is going before it goes. It is
                    // the same write the detail sheet's Advance makes, offline
                    // included, and VoiceOver reads it as a custom action.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if let next = OrderStatus(rawValue: order.status)?.nextInQueue {
                            Button {
                                Task { await advance(order) }
                            } label: {
                                Label(next.localizedLabel, systemImage: "arrow.right")
                            }
                            .tint(KhaytDesign.statusColor(for: next.rawValue))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 56)
            }
        }
    }

    @ViewBuilder
    private var recentContent: some View {
        Group {
            if recent.isEmpty && errorMessage == nil {
                ProgressView()
            } else if recent.isEmpty {
                ContentUnavailableView(
                    errorMessage == nil ? L10n.tr("orders.no_completed") : L10n.tr("orders.recent"),
                    systemImage: "clock",
                    description: Text(errorMessage ?? L10n.tr("orders.no_completed.sub"))
                )
            } else {
                List {
                    ForEach(recent) { entry in
                        recentRow(entry)
                    }
                    // Where the rest of it is. Without this the list simply
                    // stops, and a shop that scrolls to the bottom concludes it
                    // has done two hundred jobs in its life.
                    if let window = api.historyWindow {
                        Text(String(format: L10n.tr("orders.history.windowed"),
                                    window.sent, window.available))
                            .font(.caption)
                            .foregroundStyle(KhaytDesign.textMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 56)
            }
        }
    }

    /// `khayt-orders.jsx` RecentRow: a status tile, the job, and its date.
    private func recentRow(_ entry: OrderLogEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: CompanionTheme.statusIcon(for: entry.status))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(KhaytDesign.statusColor(for: entry.status))
                .frame(width: 36, height: 36)
                .background(KhaytDesign.statusSoft(for: entry.status),
                            in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KhaytDesign.text)
                    .lineLimit(1)
                Text([entry.displayClient, entry.id].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(KhaytDesign.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let date = entry.date ?? entry.dueDate {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(KhaytDesign.textMuted)
                }
                if entry.isOverdue { LateBadge() }
            }
        }
        .accessibilityElement(children: .combine)
        .listRowBackground(KhaytDesign.surface)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func load() async {
        let generation = loadGeneration + 1
        loadGeneration = generation
        errorMessage = nil
        if machines.isEmpty {
            machines = (try? await api.fetchMachines()) ?? []
        }
        do {
            switch segment {
            case .active:
                let data = try await api.fetchQueue()
                guard generation == loadGeneration else { return }
                queue = data
            case .recent:
                let data = try await api.fetchRecentOrders(limit: 40, status: recentStatusFilter)
                guard generation == loadGeneration else { return }
                recent = data
                recentStatusFilter = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            if segment == .active { queue = [] } else { recent = [] }
            errorMessage = error.localizedDescription
        }
    }

    private func setStatus(_ order: QueueOrder, status: String) async {
        updatingId = order.id
        defer { updatingId = nil }
        do {
            try await api.updateOrderStatus(orderId: order.id, status: status)
            CompanionHaptics.success()
            await load()
            if let id = selectedOrder?.id,
               let updated = queue.first(where: { $0.id == id }) {
                selectedOrder = updated
            }
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    private func advance(_ order: QueueOrder) async {
        guard let current = OrderStatus(rawValue: order.status),
              let next = current.nextInQueue else { return }
        await setStatus(order, status: next.rawValue)
    }

    private func assignMachine(_ order: QueueOrder, machineId: String?) async {
        updatingId = order.id
        defer { updatingId = nil }
        do {
            try await api.assignMachine(orderId: order.id, machineId: machineId)
            CompanionHaptics.success()
            await load()
            if let id = selectedOrder?.id,
               let updated = queue.first(where: { $0.id == id }) {
                selectedOrder = updated
            }
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}

/// `khayt-orders.jsx` FilterChips: tinted by the stage it filters, with a count.
private struct FilterChip: View {
    let title: String
    var count: Int = 0
    var tint: Color = KhaytDesign.brand
    var dot = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if selected && dot {
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16)
                        .background(selected ? tint : KhaytDesign.surface3, in: Capsule())
                        .foregroundStyle(selected ? Color.white : KhaytDesign.textMuted)
                }
            }
            .font(.caption.bold())
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? tint.opacity(0.16) : KhaytDesign.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.32) : KhaytDesign.sep, lineWidth: 1.5))
            .foregroundStyle(selected ? tint : KhaytDesign.textDim)
            // A 32pt pill, touched anywhere in a 44pt band around it.
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The red "late" tag beside a job's name.
struct LateBadge: View {
    var body: some View {
        Text(L10n.tr("orders.late"))
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(KhaytDesign.danger)
            .background(KhaytDesign.dangerSoft, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// `khayt-orders.jsx` OrderRow: a stage strip, the job, who it is for, and
/// its stage and due date. Moving it on is a swipe (see `activeContent`),
/// not a button in every row — that is what made each row three times taller
/// than the mockup's.
private struct QueueOrderRow: View {
    let order: QueueOrder
    let isUpdating: Bool

    private var subtitle: String {
        // Which printer a job is on is worth more on a shop floor than its id,
        // which the detail sheet shows anyway.
        let second = (order.machine?.isEmpty == false) ? order.machine! : order.id
        return [order.displayClient, second].joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(KhaytDesign.statusColor(for: order.status))
                .frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(order.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KhaytDesign.text)
                        .lineLimit(1)
                    if order.isOverdue { LateBadge() }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(KhaytDesign.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                if isUpdating {
                    ProgressView().controlSize(.small)
                } else {
                    CompanionStatusBadge(status: order.status, compact: true)
                }
                if let due = order.formattedDueDate {
                    Text(due)
                        .font(.caption2)
                        .foregroundStyle(order.isOverdue ? KhaytDesign.danger : KhaytDesign.textMuted)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
