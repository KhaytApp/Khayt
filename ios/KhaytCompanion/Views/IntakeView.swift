import SwiftUI

/// Inbound job requests (the waiting-list funnel) — triage on the go.
struct IntakeView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var items: [WaitingListItem] = []
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var workingId: String?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty && !didLoad && errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("intake.empty"),
                        systemImage: "tray",
                        description: Text(errorMessage ?? L10n.tr("intake.empty.sub"))
                    )
                } else {
                    List(items) { item in
                        IntakeRow(item: item, isWorking: workingId == item.id)
                            .listRowBackground(KhaytDesign.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await setStatus(item, "declined") }
                                } label: { Label(L10n.tr("intake.decline"), systemImage: "xmark") }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    Task { await setStatus(item, "reminded") }
                                } label: { Label(L10n.tr("intake.remind"), systemImage: "bell") }
                                    .tint(KhaytDesign.warn)
                            }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .refreshable { await load() }
                }
            }
            .khaytScreen(title: L10n.tr("intake.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.done")) { dismiss() }
                }
            }
            .task {
                await load()
                didLoad = true
            }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            items = try await api.fetchWaitingList()
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    private func setStatus(_ item: WaitingListItem, _ status: String) async {
        workingId = item.id
        defer { workingId = nil }
        do {
            try await api.updateWaitingStatus(id: item.id, status: status)
            CompanionHaptics.success()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}

private struct IntakeRow: View {
    let item: WaitingListItem
    let isWorking: Bool

    private var priorityColor: Color {
        switch (item.priority ?? "normal").lowercased() {
        case "urgent": return KhaytDesign.danger
        case "high": return KhaytDesign.orange
        case "low": return KhaytDesign.textMuted
        default: return KhaytDesign.info
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(priorityColor).frame(width: 8, height: 8)
                Text(item.displayTitle)
                    .font(.headline)
                    .foregroundStyle(KhaytDesign.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isWorking { ProgressView().controlSize(.small) }
                if (item.status ?? "") == "reminded" {
                    KhaytPill(text: L10n.tr("intake.reminded"), color: KhaytDesign.warn)
                }
            }
            Text(item.displayClient)
                .font(.subheadline)
                .foregroundStyle(KhaytDesign.textDim)

            HStack(spacing: 8) {
                if let material = item.material, !material.isEmpty {
                    tag(material)
                }
                if let est = item.estValue, est > 0 {
                    tag("~\(Int(est)) SAR")
                }
                if let source = item.source, !source.isEmpty {
                    Label(source, systemImage: "arrow.down.right.circle")
                        .font(.caption2)
                        .foregroundStyle(KhaytDesign.textMuted)
                }
            }

            if let notes = item.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(KhaytDesign.textMuted)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let dial = item.dialNumber, let url = URL(string: "tel:\(dial)") {
                    contactLink(L10n.tr("intake.call"), "phone.fill", url, KhaytDesign.ok)
                }
                if let dial = item.dialNumber, let url = URL(string: "https://wa.me/\(dial.hasPrefix("+") ? String(dial.dropFirst()) : dial)") {
                    contactLink(L10n.tr("intake.whatsapp"), "message.fill", url, KhaytDesign.brand)
                }
                if let email = item.email, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
                    contactLink(L10n.tr("intake.email"), "envelope.fill", url, KhaytDesign.textDim)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(KhaytDesign.textDim)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(KhaytDesign.surface2, in: Capsule())
    }

    private func contactLink(_ label: String, _ icon: String, _ url: URL, _ color: Color) -> some View {
        Link(destination: url) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
