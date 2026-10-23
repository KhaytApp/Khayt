import Foundation
import UserNotifications

/// Telling somebody a print has gone wrong.
///
/// The reason an app like this is worth leaving open. Khayt sends these through
/// Telegram, email or a webhook — transports for somebody who is not in the
/// workshop. This one is for the person who is: a notification on the machine
/// they are sitting at, which arrives whether or not the shop has ever set up a
/// bot.
///
/// **It does not deliver in a development run**, and that is deliberate rather
/// than a gap. `UNUserNotificationCenter.current()` traps when the process has
/// no bundle identifier, which `swift run` does not — so it would take the
/// whole app down, including the snapshot harness, for a notification nobody
/// would see. The alerts are still computed and still recorded; only the
/// delivery is skipped.
@MainActor
@Observable
final class PrinterNotice {

    /// Every notice this session raised, newest first, whether or not macOS
    /// showed it. The app puts them on screen too: a notification that was
    /// dismissed while the shop was making coffee is a notification it never
    /// had, and "what went wrong overnight" is a question worth answering
    /// after the fact.
    ///
    /// OBSERVABLE, and the class is too — it is held by `PrinterWatch` as a
    /// `let`, so an @Observable watch does not make a plain class inside it
    /// observable. The section rendered nothing at all until this said so.
    private(set) var raised: [Notice] = []

    struct Notice: Identifiable, Hashable, Sendable {
        let id = UUID()
        let machineId: String
        let machine: String
        let kind: String
        let title: String
        let body: String
        let at: Date
    }

    /// A macOS notification is only possible in a packaged app. See the note
    /// above — this is a fact about the process, not a setting.
    static var canDeliver: Bool { Bundle.main.bundleIdentifier != nil }

    private var asked = false

    /// Raise one. Recorded always; delivered when it can be.
    func raise(_ notice: Notice) {
        raised.insert(notice, at: 0)
        // Twenty is a session's worth of "what happened while I was out"
        // without becoming a log nobody reads.
        if raised.count > 20 { raised.removeLast(raised.count - 20) }
        guard Self.canDeliver else { return }
        Task { await deliver(notice) }
    }

    /// Record a notice without delivering it, for the snapshot runner: the
    /// alert card is drawn from `raised`, and a macOS banner for a pretend
    /// runout has no business appearing on a real desktop.
    func recordForTesting(_ notice: Notice) { raised.insert(notice, at: 0) }

    private func deliver(_ notice: Notice) async {
        let centre = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            // Asked on the first alert rather than at launch: a permission
            // prompt on first run, before the app has done anything, is a
            // prompt somebody denies to get rid of it.
            _ = try? await centre.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        // The machine and the kind, so a second alert about the same fault
        // replaces the first rather than stacking under it.
        content.threadIdentifier = notice.machineId
        let request = UNNotificationRequest(identifier: notice.machineId + ":" + notice.kind + ":"
                                            + String(Int(notice.at.timeIntervalSince1970)),
                                            content: content, trigger: nil)
        try? await centre.add(request)
    }
}
