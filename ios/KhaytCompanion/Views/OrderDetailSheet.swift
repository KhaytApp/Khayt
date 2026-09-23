import SwiftUI

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
            List {
                Section {
                    LabeledContent(L10n.tr("field.project"), value: order.displayTitle)
                    LabeledContent(L10n.tr("field.client"), value: order.displayClient)
                    LabeledContent(L10n.tr("field.status")) {
                        CompanionStatusBadge(status: order.status)
                    }
                    if let machine = order.machine, !machine.isEmpty {
                        LabeledContent(L10n.tr("field.machine"), value: machine)
                    }
                    if let due = order.dueDate, !due.isEmpty {
                        LabeledContent(L10n.tr("field.due"), value: due)
                    }
                    if let priority = order.priority, !priority.isEmpty {
                        LabeledContent(L10n.tr("field.priority"), value: priority.capitalized)
                    }
                    LabeledContent(L10n.tr("order.detail.id"), value: order.id)
                        .font(.caption)
                }

                if let onAssignMachine, !machines.isEmpty {
                    Section(L10n.tr("field.machine")) {
                        Menu {
                            Button {
                                onAssignMachine(nil)
                            } label: {
                                Label(L10n.tr("common.unassigned"), systemImage: order.machineId == nil ? "checkmark" : "circle")
                            }
                            ForEach(machines) { m in
                                Button {
                                    onAssignMachine(m.id)
                                } label: {
                                    Label(m.name ?? m.id, systemImage: order.machineId == m.id ? "checkmark" : "printer")
                                }
                            }
                        } label: {
                            HStack {
                                Text(L10n.tr("order.detail.assigned"))
                                    .foregroundStyle(KhaytDesign.text)
                                Spacer()
                                Text(order.machine ?? L10n.tr("common.unassigned"))
                                    .foregroundStyle(KhaytDesign.textDim)
                                if isUpdating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption)
                                        .foregroundStyle(KhaytDesign.textMuted)
                                }
                            }
                        }
                        .disabled(isUpdating)
                    }
                }

                if OrderStatus(rawValue: order.status)?.nextInQueue != nil {
                    Section {
                        Button(action: onAdvance) {
                            if isUpdating {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                            } else {
                                Label(L10n.tr("orders.detail.advance"), systemImage: "arrow.right.circle.fill")
                            }
                        }
                        .disabled(isUpdating)
                    }
                }

                Section(L10n.tr("orders.detail.set_status")) {
                    ForEach(OrderStatus.assignable, id: \.self) { st in
                        Button {
                            onSetStatus(st.rawValue)
                        } label: {
                            HStack {
                                CompanionStatusBadge(status: st.rawValue, compact: true)
                                Spacer()
                                if order.status == st.rawValue {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(KhaytDesign.brand)
                                }
                            }
                        }
                        .disabled(isUpdating || order.status == st.rawValue)
                    }
                }
            }
            .navigationTitle(L10n.tr("order.detail.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.done")) { dismiss() }
                }
            }
        }
    }
}
