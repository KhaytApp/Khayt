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
        /// The job that was printing, when the finish seam could name it —
        /// for "Log as waste…" on a failed print. Never drawn: a banner shows
        /// on a locked screen.
        var orderId: String? = nil
        /// How far the print got (0–100) by the printer's last report, when
        /// it said; the waste sheet estimates the grams from it.
        var progress: Double? = nil
    }

    /// A macOS notification is only possible in a packaged app. See the note
    /// above — this is a fact about the process, not a setting.
    static var canDeliver: Bool { Bundle.main.bundleIdentifier != nil }

    private var asked = false

    /// What has been said about each machine's current print, so a finish, a
    /// failure or a pause is told once (`PrintNoticeLedger`). Ignored by
    /// observation: it changes on every sweep and nothing draws it.
    @ObservationIgnored var ledger = PrintNoticeLedger()

    /// Raise one. Recorded always; delivered when it can be.
    func raise(_ notice: Notice) {
        raised.insert(notice, at: 0)
        // Twenty is a session's worth of "what happened while I was out"
        // without becoming a log nobody reads.
        if raised.count > 20 { raised.removeLast(raised.count - 20) }
        guard Self.canDeliver else { return }
        Task { await deliver(notice) }
    }

    /// Deliver a notice without keeping it in `raised`. For good news — a
    /// print that finished — which has no place in "Printer trouble".
    func announce(_ notice: PrinterNotice.Notice) {
        guard Self.canDeliver else { return }
        Task { await deliver(notice) }
    }

    /// Record a notice without delivering it, for the snapshot runner: the
    /// alert card is drawn from `raised`, and a macOS banner for a pretend
    /// runout has no business appearing on a real desktop.
    func recordForTesting(_ notice: Notice) { raised.insert(notice, at: 0) }

    /// Will a notification posted now be HEARD, as far as this app can know?
    ///
    /// Every notice is posted with the default sound (`deliver`), so what
    /// decides is the system's settings for Khayt: allowed at all, sounds on,
    /// and shown somewhere (a banner or Notification Centre). Pure, so every
    /// combination can be tested without a notification centre.
    ///
    /// WHAT THIS CANNOT KNOW: a Focus or Do Not Disturb that is on, the Mac's
    /// volume or mute, and a notification summary that holds it back. macOS
    /// does not tell an app any of those, so under a Focus this says "heard"
    /// and the notification is in fact silent.
    nonisolated static func audible(authorized: Bool, soundOn: Bool, shown: Bool) -> Bool {
        authorized && soundOn && shown
    }

    /// The same question asked of the system. READS ONLY: it never asks for
    /// permission (that is `deliver`'s, on the first notice), so before
    /// anybody has answered the prompt the answer is no. And no in a
    /// development run, where there is no notification centre to ask.
    func carriesSound() async -> Bool {
        guard Self.canDeliver else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.audible(authorized: settings.authorizationStatus == .authorized,
                            soundOn: settings.soundSetting == .enabled,
                            shown: settings.alertSetting == .enabled
                                || settings.notificationCenterSetting == .enabled)
    }

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
