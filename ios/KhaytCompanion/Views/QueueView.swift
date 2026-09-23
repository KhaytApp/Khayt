import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var orders: [QueueOrder] = []
    @State private var errorMessage: String?
    @State private var updatingId: String?

    var body: some View {
        NavigationStack {
            Group {
                if orders.isEmpty && errorMessage == nil {
                    ProgressView()
                } else if orders.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("queue.empty"),
                        systemImage: "tray",
                        description: Text(errorMessage ?? L10n.tr("queue.empty.sub"))
                    )
                } else {
                    List(orders) { order in
                        QueueRow(
                            order: order,
                            isUpdating: updatingId == order.id,
                            onAdvance: { Task { await advance(order) } },
                            onSetStatus: { status in Task { await setStatus(order, status: status) } }
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L10n.tr("queue.title"))
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            orders = try await api.fetchQueue()
        } catch {
            orders = []
            errorMessage = error.localizedDescription
        }
    }

    private func setStatus(_ order: QueueOrder, status: String) async {
        updatingId = order.id
        defer { updatingId = nil }
        do {
            try await api.updateOrderStatus(orderId: order.id, status: status)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func advance(_ order: QueueOrder) async {
        guard let current = OrderStatus(rawValue: order.status),
              let next = current.nextInQueue else { return }
        updatingId = order.id
        defer { updatingId = nil }
        do {
            try await api.updateOrderStatus(orderId: order.id, status: next.rawValue)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct QueueRow: View {
    let order: QueueOrder
    let isUpdating: Bool
    let onAdvance: () -> Void
    let onSetStatus: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(order.displayTitle)
                    .font(.headline)
                Spacer()
                StatusBadge(status: order.status)
            }
            Text(order.displayClient)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let machine = order.machine, !machine.isEmpty {
                Label(machine, systemImage: "printer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Menu {
                ForEach(OrderStatus.assignable, id: \.self) { st in
                    Button(st.localizedLabel) { onSetStatus(st.rawValue) }
                }
            } label: {
                Label(L10n.tr("orders.detail.set_status"), systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if OrderStatus(rawValue: order.status)?.nextInQueue != nil {
                Button(action: onAdvance) {
                    if isUpdating {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(L10n.tr("orders.detail.advance"), systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
                .disabled(isUpdating)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(OrderStatus(rawValue: status)?.label ?? status)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.2), in: Capsule())
    }
}
