import SwiftUI
import UserNotifications

/// Inbound job requests (the waiting-list funnel) — triage on the go.
struct IntakeView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var items: [WaitingListItem] = []
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var workingId: String?
    @State private var remindAbout: WaitingListItem?

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
                                       onRemind: { remindAbout = item })
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
            // One sheet header (review W5): an inline title and Close on the
            // leading side, as every sheet opened from New has.
            .navigationBarTitleDisplayMode(.inline)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
            .confirmationDialog(L10n.tr("intake.remind.when"),
                                isPresented: Binding(get: { remindAbout != nil }, set: { if !$0 { remindAbout = nil } }),
                                titleVisibility: .visible, presenting: remindAbout) { item in
                Button(L10n.tr("intake.remind.tomorrow")) { Task { await remind(item, inDays: 1) } }
                Button(L10n.tr("intake.remind.3days")) { Task { await remind(item, inDays: 3) } }
                Button(L10n.tr("intake.remind.week")) { Task { await remind(item, inDays: 7) } }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
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

    /// "Remind me": the day, written as the request's `reminderDate` (the
    /// desktop shows "Reminder due" on it) and a phone alert at 9:00 that
    /// opens the requests.
    private func remind(_ item: WaitingListItem, inDays days: Int) async {
        guard let when = IntakeReminder.date(inDays: days) else { return }
        workingId = item.id
        defer { workingId = nil }
        do {
            try await api.updateWaitingStatus(id: item.id, status: "reminded",
                                              reminderDate: IntakeReminder.day(when))
            await IntakeReminder.schedule(item, at: when)
            CompanionHaptics.success()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
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

/// A walk-in, as `design/ios-v2/` draws one: a steel rail and a "Waiting"
/// chip (somebody is waiting on the shop), who and when, what they want, and the two answers — take it into
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
        return date.formatted(.relative(presentation: .named).locale(L10n.locale))
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
                // Steel: this one waits on the shop, not on a printer — amber
                // is progress and today. Said in words, not only by the edge.
                HStack(spacing: 5) {
                    Circle().fill(KhaytDesign.pending).frame(width: 6, height: 6)
                    Text(when.map { L10n.tr("intake.waiting") + " · " + $0 } ?? L10n.tr("intake.waiting"))
                        .font(.khayt(11.5, .medium, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.pending)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(KhaytDesign.pendingWash, in: Capsule())
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
        .overlay(alignment: .leading) { Rectangle().fill(KhaytDesign.pending).frame(width: 3) }
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

/// A request's reminder: the day it is due and the phone alert for it.
enum IntakeReminder {
    /// 9:00 on the day `days` from today, on the phone's clock.
    static func date(inDays days: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return nil }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
    }

    /// The book's day, yyyy-MM-dd in the Gregorian calendar whatever the
    /// phone's is — the desktop compares it with its own today as text.
    static func day(_ date: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The alert. Its id starts `intake.`, so tapping it opens the requests.
    static func content(for item: WaitingListItem) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = L10n.tr("PUSH_TITLE")
        let who = item.clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        c.body = L10n.format("intake.remind.alert", who.isEmpty ? item.displayTitle : who)
        c.sound = .default
        c.threadIdentifier = "khayt.intake"
        c.filterCriteria = NotificationKind.intake
        return c
    }

    static func schedule(_ item: WaitingListItem, at date: Date) async {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: "intake.remind.\(item.id)", content: content(for: item),
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }
}
