import SwiftUI

/// One job, as `design/ios-v2/` draws it: a PAGE pushed onto the stack — not a
/// sheet — with the job and who it is for, the few facts a shop floor needs,
/// the five stages to put it in directly, and ONE button that moves it on.
///
/// There is no on-hold chip. The design has five stages and so does this page;
/// holding a job is the Mac's.
struct OrderDetailPage: View {
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var order: QueueOrder
    let facts: OrderFacts?
    /// Called after a write, so the screen underneath is current when the page
    /// is popped.
    let onChanged: () async -> Void

    @State private var machines: [MachineInfo] = []
    @State private var isUpdating = false
    @State private var errorMessage: String?

    init(order: QueueOrder, facts: OrderFacts?, onChanged: @escaping () async -> Void) {
        _order = State(initialValue: order)
        self.facts = facts
        self.onChanged = onChanged
    }

    var body: some View {
        ScrollView {
            OrderDetailContent(order: order, facts: facts, isUpdating: isUpdating, machines: machines,
                               errorMessage: errorMessage,
                               onAdvance: { Task { await advance() } },
                               onSetStatus: { st in Task { await setStatus(st) } },
                               onAssignMachine: { id in Task { await assignMachine(id) } })
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            // The design's two-line title: the job's number and who it is for.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(order.displayTitle)
                        .font(.khayt(16, .semibold, relativeTo: .headline))
                        .lineLimit(1)
                        .foregroundStyle(KhaytDesign.ink)
                    Text("#\(order.id) · \(order.displayClient)")
                        .font(.khayt(11.5, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { machines = (try? await api.fetchMachines()) ?? [] }
    }

    private func advance() async {
        guard let next = OrderStatus(rawValue: order.status)?.nextInQueue else { return }
        await setStatus(next.rawValue)
    }

    private func setStatus(_ status: String) async {
        guard status != order.status else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await api.updateOrderStatus(orderId: order.id, status: status)
            CompanionHaptics.success()
            errorMessage = nil
            await refresh(status: status, machineId: order.machineId, machine: order.machine)
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    private func assignMachine(_ machineId: String?) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await api.assignMachine(orderId: order.id, machineId: machineId)
            CompanionHaptics.success()
            errorMessage = nil
            let name = machines.first { $0.id == machineId }?.name
            await refresh(status: order.status, machineId: machineId, machine: machineId == nil ? nil : name)
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    /// The written job, re-read from the queue when it is still in it. A job
    /// moved to Done leaves the queue, so the page keeps what it wrote rather
    /// than going blank under the person who just finished it.
    private func refresh(status: String, machineId: String?, machine: String?) async {
        await onChanged()
        if let fresh = (try? await api.fetchQueue())?.first(where: { $0.id == order.id }) {
            order = fresh
        } else {
            order = QueueOrder(id: order.id, project: order.project, client: order.client, status: status,
                               machine: machine, machineId: machineId, dueDate: order.dueDate,
                               priority: order.priority)
        }
    }
}

/// What the page shows, apart from the page. Its own view so the layout can be
/// rendered and checked on its own — `ImageRenderer` draws no navigation stack.
struct OrderDetailContent: View {
    let order: QueueOrder
    var facts: OrderFacts? = nil
    let isUpdating: Bool
    var machines: [MachineInfo] = []
    var errorMessage: String? = nil
    let onAdvance: () -> Void
    let onSetStatus: (String) -> Void
    var onAssignMachine: ((String?) -> Void)? = nil

    private static let stages: [OrderStatus] = [.pending, .printing, .post, .qc, .completed]

    private var current: OrderStatus? { OrderStatus(rawValue: order.status) }
    private var next: OrderStatus? { current?.nextInQueue }
    private var tone: Color { KhaytDesign.statusColor(for: order.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            fields
            picker
            if let errorMessage {
                Text(errorMessage)
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.late)
            }
            action.padding(.top, 6)
        }
        .padding(16)
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(current?.localizedLabel ?? order.status)
                    .font(.khayt(12, .semibold, relativeTo: .caption))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .foregroundStyle(tone)
                    .background(tone.opacity(0.14), in: Capsule())
                if order.isOverdue {
                    Text(L10n.tr("orders.late"))
                        .font(.khayt(11, .bold, relativeTo: .caption2))
                        .tracking(0.6)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .foregroundStyle(KhaytDesign.late)
                        .background(KhaytDesign.late.opacity(0.14), in: Capsule())
                }
            }
            .padding(.bottom, 11)
            Text(order.displayTitle)
                .font(.khayt(25, .semibold, relativeTo: .title))
                .tracking(-0.5)
                .foregroundStyle(KhaytDesign.ink)
            Text(order.displayClient)
                .font(.khayt(14.5, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
                .padding(.top, 6)
        }
        .padding(.vertical, 16).padding(.leading, 19).padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface)
        .overlay(alignment: .leading) {
            if KhaytDesign.isRailed(order.status) || order.isOverdue {
                Rectangle().fill(order.isOverdue ? KhaytDesign.late : tone).frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    /// Due, Filament, Quantity, Printer, Client — the design's five, less any
    /// the phone does not know. A row with nothing in it is not drawn; a dash
    /// would say the job has no filament, which is not what the phone knows.
    private var fields: some View {
        VStack(spacing: 0) {
            if let due = order.formattedDueDate {
                row(L10n.tr("order.detail.due_date")) {
                    Text(due).foregroundStyle(order.isOverdue ? KhaytDesign.late : KhaytDesign.ink)
                }
                Divider().overlay(KhaytDesign.hairline)
            }
            if let material = facts?.material {
                row(L10n.tr("order.field.filament")) { Text(material).foregroundStyle(KhaytDesign.ink) }
                Divider().overlay(KhaytDesign.hairline)
            }
            if let quantity = facts?.quantity {
                row(L10n.tr("order.field.quantity")) {
                    Text("×\(quantity)").foregroundStyle(KhaytDesign.ink).environment(\.layoutDirection, .leftToRight)
                }
                Divider().overlay(KhaytDesign.hairline)
            }
            printerRow
            Divider().overlay(KhaytDesign.hairline)
            row(L10n.tr("field.client")) { Text(order.displayClient).foregroundStyle(KhaytDesign.ink) }
        }
        .background(KhaytDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var printerRow: some View {
        if let onAssignMachine, !machines.isEmpty {
            Menu {
                Button { onAssignMachine(nil) } label: {
                    Label(L10n.tr("common.unassigned"), systemImage: order.machineId == nil ? "checkmark" : "circle")
                }
                ForEach(machines) { m in
                    Button { onAssignMachine(m.id) } label: {
                        Label(m.name ?? m.id, systemImage: order.machineId == m.id ? "checkmark" : "printer")
                    }
                }
            } label: {
                row(L10n.tr("order.detail.printer")) {
                    HStack(spacing: 6) {
                        Text(order.machine ?? "—").foregroundStyle(KhaytDesign.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2).foregroundStyle(KhaytDesign.note)
                    }
                }
            }
            .disabled(isUpdating)
        } else {
            row(L10n.tr("order.detail.printer")) { Text(order.machine ?? "—").foregroundStyle(KhaytDesign.ink) }
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.khayt(14, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
            Spacer(minLength: 12)
            value()
                .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    /// Any of the five stages, directly — for the job sent back from QC.
    private var picker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("pulse.move_to").uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .tracking(1.05)
                .foregroundStyle(KhaytDesign.note)
                .padding(.horizontal, 2)
            FlowChips(stages: Self.stages, current: current, disabled: isUpdating) { onSetStatus($0.rawValue) }
        }
    }

    /// The one thing most people open this page to do: brand blue, whatever
    /// the stage — the design keeps colour for state, not for buttons.
    @ViewBuilder
    private var action: some View {
        if let next {
            Button(action: onAdvance) {
                HStack(spacing: 9) {
                    if isUpdating {
                        ProgressView().tint(KhaytDesign.onBrand)
                    } else {
                        Text(next == .completed ? L10n.tr("order.detail.mark_done")
                                                : String(format: L10n.tr("order.detail.move_to"), next.localizedLabel))
                        Image(systemName: "arrow.forward")
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                }
                .font(.khayt(17, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.onBrand)
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
        }
    }
}

/// The stage chips, wrapping onto a second line when five do not fit.
private struct FlowChips: View {
    let stages: [OrderStatus]
    let current: OrderStatus?
    let disabled: Bool
    let onPick: (OrderStatus) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { chips }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) { ForEach(stages.prefix(3), id: \.self, content: chip) }
                HStack(spacing: 7) { ForEach(stages.dropFirst(3), id: \.self, content: chip) }
            }
        }
    }

    private var chips: some View { ForEach(stages, id: \.self, content: chip) }

    private func chip(_ stage: OrderStatus) -> some View {
        let on = stage == current
        let tone = KhaytDesign.statusColor(for: stage.rawValue)
        return Button { onPick(stage) } label: {
            Text(stage.localizedLabel)
                .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .frame(minHeight: 44)
                .foregroundStyle(on ? tone : KhaytDesign.note)
                .background(on ? tone.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(on ? tone.opacity(0.5) : KhaytDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled || on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
