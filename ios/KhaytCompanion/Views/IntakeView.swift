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
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr(api.holdsBook ? "intake.foot" : "intake.foot.no_book"))
                        .font(.khayt(13, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                        .padding(.bottom, 4)
                    if items.isEmpty && !didLoad && errorMessage == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 44)
                    } else if items.isEmpty {
                        VStack(spacing: 5) {
                            Text(L10n.tr("intake.empty"))
                                .font(.khayt(15, .semibold, relativeTo: .headline))
                                .foregroundStyle(KhaytDesign.ink)
                            Text(errorMessage ?? L10n.tr("intake.empty.sub"))
                                .font(.khayt(13, relativeTo: .footnote))
                                .foregroundStyle(KhaytDesign.note)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.khayt(12.5, relativeTo: .footnote))
                                .foregroundStyle(KhaytDesign.late)
                        }
                        ForEach(items) { item in
                            IntakeCard(item: item, isWorking: workingId == item.id, canTake: api.holdsBook,
                                       onTake: { Task { await take(item) } },
                                       onDismiss: { Task { await setStatus(item, "declined") } },
                                       onRemind: { Task { await setStatus(item, "reminded") } })
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
            .khaytScreen(title: L10n.tr("intake.title"))
            .background(KhaytDesign.ground.ignoresSafeArea())
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

    private func take(_ item: WaitingListItem) async {
        workingId = item.id
        defer { workingId = nil }
        do {
            try await api.takeWaiting(item)
            CompanionHaptics.success()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
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

/// A walk-in, as `design/ios-v2/` draws one: an amber rail (somebody is
/// waiting), who and when, what they want, and the two answers — take it into
/// the queue, or dismiss it. Reminding and getting in touch are a long-press
/// away: useful, but not what the card is for.
private struct IntakeCard: View {
    let item: WaitingListItem
    let isWorking: Bool
    let canTake: Bool
    let onTake: () -> Void
    let onDismiss: () -> Void
    let onRemind: () -> Void

    private var when: String? {
        guard let raw = item.submittedAt ?? item.reminderDate, let date = DueDateParser.parse(raw) else { return nil }
        return date.formatted(.relative(presentation: .named))
    }

    private var want: String {
        var parts: [String] = [item.displayTitle]
        if let notes = item.notes, !notes.isEmpty, notes != item.project { parts.append(notes) }
        if let material = item.material, !material.isEmpty { parts.append(material) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.displayClient)
                    .font(.khayt(16, .medium, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                    .lineLimit(1)
                if (item.status ?? "") == "reminded" {
                    Text(L10n.tr("intake.reminded"))
                        .font(.khayt(10.5, .semibold, relativeTo: .caption2))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .foregroundStyle(KhaytDesign.attention)
                        .background(KhaytDesign.attention.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
                if let when {
                    Text(when)
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                }
            }
            Text(want)
                .font(.khayt(13.5, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            HStack(spacing: 8) {
                if canTake {
                    Button(action: onTake) {
                        Group {
                            if isWorking { ProgressView().tint(KhaytDesign.onBrand) } else { Text(L10n.tr("intake.take")) }
                        }
                        .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.onBrand)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onDismiss) {
                    Text(L10n.tr("intake.dismiss"))
                        .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.note)
                        .frame(maxWidth: canTake ? nil : .infinity, minHeight: 46)
                        .frame(minWidth: 100)
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .disabled(isWorking)
            .padding(.top, 13)
        }
        .padding(.vertical, 14).padding(.leading, 18).padding(.trailing, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface)
        .overlay(alignment: .leading) { Rectangle().fill(KhaytDesign.attention).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .contextMenu {
            Button(action: onRemind) { Label(L10n.tr("intake.remind"), systemImage: "bell") }
            if let dial = item.dialNumber, let url = URL(string: "tel:\(dial)") {
                Link(destination: url) { Label(L10n.tr("intake.call"), systemImage: "phone") }
            }
            if let dial = item.dialNumber,
               let url = URL(string: "https://wa.me/\(dial.hasPrefix("+") ? String(dial.dropFirst()) : dial)") {
                Link(destination: url) { Label(L10n.tr("intake.whatsapp"), systemImage: "message") }
            }
            if let email = item.email, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
                Link(destination: url) { Label(L10n.tr("intake.email"), systemImage: "envelope") }
            }
        }
    }
}
