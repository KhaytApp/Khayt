import SwiftUI

/// One job, as `design/iOS UI/khayt-orders.jsx` OrderDetailContent draws it: a
/// bottom sheet with the job and who it is for, where it sits among the five
/// stages, the few facts a shop floor needs, and ONE button that moves it on —
/// named and coloured for the stage it moves to.
///
/// Setting any status directly is still here, below, for the correction that
/// is not "next": a job sent back from QC, or put on hold.
struct OrderDetailSheet: View {
    let order: QueueOrder
    let isUpdating: Bool
    var machines: [MachineInfo] = []
    let onAdvance: () -> Void
    let onSetStatus: (String) -> Void
    var onAssignMachine: ((String?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                OrderDetailContent(order: order, isUpdating: isUpdating, machines: machines,
                                   onAdvance: onAdvance, onSetStatus: onSetStatus,
                                   onAssignMachine: onAssignMachine)
            }
            .background(KhaytDesign.bg)
            .navigationTitle(order.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.done")) { dismiss() }
                }
            }
        }
        // A sheet that opens half-way, as the mockup's does, and pulls up for
        // the rest.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// What the sheet shows, apart from the sheet. Its own view so the layout can be
/// rendered and checked on its own — `ImageRenderer` draws no navigation stack.
struct OrderDetailContent: View {
    let order: QueueOrder
    let isUpdating: Bool
    var machines: [MachineInfo] = []
    let onAdvance: () -> Void
    let onSetStatus: (String) -> Void
    var onAssignMachine: ((String?) -> Void)? = nil

    private static let stages: [OrderStatus] = [.pending, .printing, .post, .qc, .completed]
    /// A stage not reached yet. `surface3` disappeared against a light
    /// background; a faint label colour shows in both.
    private static let inactive = KhaytDesign.textFaint

    private var current: OrderStatus? { OrderStatus(rawValue: order.status) }
    private var next: OrderStatus? { current?.nextInQueue }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            timeline
            details
            action
            correction
        }
        .padding(KhaytDesign.pad)
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(order.displayTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(KhaytDesign.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CompanionStatusBadge(status: order.status)
            }
            Text(order.displayClient)
                .font(.subheadline)
                .foregroundStyle(KhaytDesign.textDim)
        }
    }

    /// The five stages as a line of dots: done ones filled, the current one
    /// ringed, the rest empty. A job on hold or still a quote sits on none.
    private var timeline: some View {
        let at = current.flatMap { Self.stages.firstIndex(of: $0) }
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, stage in
                let color = KhaytDesign.statusColor(for: stage.rawValue)
                let done = at.map { i < $0 } ?? false
                let isCurrent = at == i
                VStack(spacing: 5) {
                    Circle()
                        .fill(done || isCurrent ? color : Self.inactive)
                        .frame(width: isCurrent ? 14 : 10, height: isCurrent ? 14 : 10)
                        .overlay(Circle().stroke(isCurrent ? color.opacity(0.25) : .clear, lineWidth: 5))
                        .frame(height: 16)
                    // The mockup's short names — "Post-processing" does not fit
                    // under a dot five abreast.
                    Text(L10n.tr("stage.short.\(stage.rawValue)"))
                        .font(.system(size: 10, weight: isCurrent ? .bold : .medium))
                        .foregroundStyle(done || isCurrent ? color : KhaytDesign.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                if i < Self.stages.count - 1 {
                    Rectangle()
                        .fill(done ? color.opacity(0.45) : Self.inactive)
                        .frame(height: 2)
                        .frame(maxWidth: 28)
                        .padding(.top, 7)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current?.localizedLabel ?? order.status)
    }

    private var details: some View {
        VStack(spacing: 0) {
            if let due = order.formattedDueDate ?? order.dueDate, !due.isEmpty {
                row(L10n.tr("order.detail.due_date")) {
                    Text(due).foregroundStyle(order.isOverdue ? KhaytDesign.danger : KhaytDesign.text)
                }
                Divider()
            }
            printerRow
            if let priority = order.priority, !priority.isEmpty {
                Divider()
                row(L10n.tr("field.priority")) { Text(priority.capitalized).foregroundStyle(KhaytDesign.text) }
            }
        }
        .padding(.horizontal, 14)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: KhaytDesign.radiusLG))
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
                        Text(order.machine ?? L10n.tr("common.unassigned")).foregroundStyle(KhaytDesign.text)
                        if isUpdating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2).foregroundStyle(KhaytDesign.textMuted)
                        }
                    }
                }
            }
            .disabled(isUpdating)
        } else {
            row(L10n.tr("order.detail.printer")) {
                Text(order.machine ?? "—").foregroundStyle(KhaytDesign.text)
            }
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(label).foregroundStyle(KhaytDesign.textDim)
            Spacer(minLength: 12)
            value().font(.subheadline.weight(.medium))
        }
        .font(.subheadline)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// The one thing most people open this sheet to do.
    @ViewBuilder
    private var action: some View {
        if let next {
            let color = KhaytDesign.statusColor(for: next.rawValue)
            Button {
                onAdvance()
            } label: {
                HStack(spacing: 10) {
                    if isUpdating {
                        ProgressView().tint(.white)
                    } else {
                        Text(String(format: L10n.tr("order.detail.move_to"), next.localizedLabel))
                            .font(.headline)
                        Image(systemName: "arrow.forward")
                            .font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(color, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: color.opacity(0.3), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
        } else if current == .completed {
            Label(L10n.tr("order.detail.complete"), systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(KhaytDesign.ok)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(KhaytDesign.okSoft, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Any status, directly — for sending a job back, or holding it.
    private var correction: some View {
        Menu {
            ForEach(OrderStatus.assignable, id: \.self) { st in
                Button {
                    onSetStatus(st.rawValue)
                } label: {
                    if order.status == st.rawValue {
                        Label(st.localizedLabel, systemImage: "checkmark")
                    } else {
                        Text(st.localizedLabel)
                    }
                }
                .disabled(order.status == st.rawValue)
            }
        } label: {
            Label(L10n.tr("orders.detail.set_status"), systemImage: "arrow.triangle.branch")
                .font(.subheadline)
                .foregroundStyle(KhaytDesign.brand)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(isUpdating)
    }
}
