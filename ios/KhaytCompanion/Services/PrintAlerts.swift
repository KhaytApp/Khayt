import Foundation
import Combine
import UserNotifications

/// A print that has just stopped, as the Mac's `print-finished` event
/// describes it (payload v1, agreed with the Mac and Cloud lanes). The same
/// shape is built on the phone from the live readings, so there is one kind
/// of alert whichever way it was noticed.
struct PrintFinished: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case finished, failed, cancelled }

    var v: Int = 1
    var kind: String = "print-finished"
    var at: String
    var machineId: String
    var machineName: String?
    var orderId: String?
    var project: String?
    var client: String?
    var filename: String?
    var durationS: Double?
    var outcome: Outcome
    var photo: Bool = false
    /// The stage the Mac moved the job to on this edge, if it did — so the
    /// phone never moves it a second time. Nil today: the Mac records the
    /// end, it does not advance the job.
    var advancedTo: String?
}

/// What an alert offers, and the one move each makes.
///
/// Agreed with the Mac lane, and deliberately narrow:
/// - a print that FINISHED can go on to post-processing — the next stage;
/// - one that FAILED or was CANCELLED can be re-queued (back to pending);
/// - an order already COMPLETED can be marked shipped — `markShipped` works
///   from completed only, and a print that has just finished is not that.
/// A reprint of a print that came out fine is another copy of the job, not a
/// move of this one, and is not offered.
enum PrintAlertAction: String, CaseIterable {
    case moveToPost = "khayt.print.post"
    case reprint = "khayt.print.reprint"
    case markShipped = "khayt.print.shipped"

    var title: String {
        switch self {
        case .moveToPost: return L10n.tr("alert.print.move_post")
        case .reprint: return L10n.tr("alert.print.reprint")
        case .markShipped: return L10n.tr("alert.print.mark_shipped")
        }
    }

    /// The category an alert carries decides its buttons.
    var category: String { rawValue + ".category" }

    static let infoCategory = "khayt.print.info"

    /// Which button, if any, for this ending of this job.
    static func offered(for event: PrintFinished, orderStatus: String?) -> PrintAlertAction? {
        guard event.orderId != nil, let status = orderStatus else { return nil }
        switch event.outcome {
        case .finished:
            if status == "completed" { return .markShipped }
            // Already moved (by the Mac, or by hand since): nothing to offer.
            if let advanced = event.advancedTo, advanced != "printing" { return nil }
            return status == "printing" ? .moveToPost : nil
        case .failed, .cancelled:
            return status == "printing" ? .reprint : nil
        }
    }

    static var categories: Set<UNNotificationCategory> {
        var out = Set(allCases.map { action in
            UNNotificationCategory(
                identifier: action.category,
                actions: [UNNotificationAction(identifier: action.rawValue, title: action.title,
                                               // It writes to the shop's book: not from a locked phone.
                                               options: [.authenticationRequired])],
                intentIdentifiers: [])
        })
        out.insert(UNNotificationCategory(identifier: infoCategory, actions: [], intentIdentifiers: []))
        return out
    }
}

/// Notices a print ending in successive live readings.
///
/// Only a machine SEEN printing and then seen not printing counts. A machine
/// that drops out of the readings, or that the phone first sees idle, is not
/// a finished print — the phone was simply not looking when it ran.
struct FinishDetector {
    private var printing: [String: (since: Date, filename: String?)] = [:]

    mutating func observe(_ readings: [String: MachineLiveStatus], now: Date = Date()) -> [PrintFinished] {
        var ended: [PrintFinished] = []
        for (id, r) in readings {
            let isPrinting = r.isPrinting
            if isPrinting {
                if printing[id] == nil { printing[id] = (now, r.filename) }
                continue
            }
            guard let was = printing.removeValue(forKey: id) else { continue }
            let state = (r.state ?? "").lowercased()
            let outcome: PrintFinished.Outcome =
                !(r.error ?? "").isEmpty || state.contains("error") || state.contains("fail") ? .failed
                : state.contains("cancel") ? .cancelled : .finished
            ended.append(PrintFinished(at: ISO8601DateFormatter().string(from: now), machineId: id,
                                       machineName: r.name, orderId: nil, project: nil, client: nil,
                                       filename: was.filename ?? r.filename,
                                       durationS: now.timeIntervalSince(was.since), outcome: outcome))
        }
        return ended
    }
}

/// Print alerts on this phone: noticing the end of a print, saying so, and
/// doing what the alert's button asks.
///
/// ── WHAT THIS VERSION CAN AND CANNOT SEE ────────────────────────────────
///
/// It notices an ending in the live readings, which arrive while the app is
/// running — on the shop's Wi-Fi, or through Khayt Cloud's stream. With the
/// app closed nothing arrives, and a closed app can only be woken by a push
/// from Apple: that is the Mac's `print-finished` event relayed by Khayt
/// Cloud over APNs, and needs the shop's push key. The alert it will show is
/// built here, from the same payload.
@MainActor
final class PrintAlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private let api: KhaytAPIClient
    private let settings: ConnectionSettings
    private var detector = FinishDetector()
    private var watching: AnyCancellable?

    init(api: KhaytAPIClient, settings: ConnectionSettings, printers: LivePrinters) {
        self.api = api
        self.settings = settings
        super.init()
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(PrintAlertAction.categories)
        center.delegate = self
        watching = printers.$byMachine.dropFirst().sink { [weak self] readings in
            guard let self, printers.isLive else { return }
            let ended = self.detector.observe(readings)
            guard !ended.isEmpty else { return }
            Task { await self.announce(ended) }
        }
    }

    /// Say that a print ended, with the one button that makes sense for it.
    func announce(_ events: [PrintFinished]) async {
        guard settings.notifyPrintDone else { return }
        let queue = (try? await api.fetchQueue()) ?? []
        for var event in events {
            // The job on that machine — only when there is exactly one, as
            // the Mac does: guessing which of two jobs just finished would put
            // a button on the wrong one.
            let onMachine = queue.filter { $0.machineId == event.machineId && $0.status == "printing" }
            if event.orderId == nil, onMachine.count == 1 {
                event.orderId = onMachine[0].id
                event.project = onMachine[0].project
                event.client = onMachine[0].client
            }
            let status = queue.first { $0.id == event.orderId }?.status
            let content = Self.content(for: event, orderStatus: status)
            let id = "print.\(event.machineId).\(event.at)"
            try? await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// The alert itself — shared with the push path, which will build the
    /// same content from the Mac's decrypted event.
    nonisolated static func content(for event: PrintFinished, orderStatus: String?) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        switch event.outcome {
        case .finished: c.title = L10n.tr("alert.print.finished")
        case .failed: c.title = L10n.tr("alert.print.failed")
        case .cancelled: c.title = L10n.tr("alert.print.cancelled")
        }
        let what = event.project ?? event.filename ?? L10n.tr("alert.print.a_job")
        var parts = [what]
        if let machine = event.machineName, !machine.isEmpty { parts.append(machine) }
        if let s = event.durationS, s >= 60 {
            let f = DateComponentsFormatter()
            f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute]
            f.unitsStyle = .abbreviated
            if let t = f.string(from: s) { parts.append(t) }
        }
        c.body = parts.joined(separator: " · ")
        c.sound = .default
        c.threadIdentifier = "khayt.prints"
        let action = PrintAlertAction.offered(for: event, orderStatus: orderStatus)
        c.categoryIdentifier = action?.category ?? PrintAlertAction.infoCategory
        var info: [String: Any] = ["machineId": event.machineId, "outcome": event.outcome.rawValue]
        if let order = event.orderId { info["orderId"] = order }
        c.userInfo = info
        return c
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even with the app open: a print ending is worth a banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let action = PrintAlertAction(rawValue: response.actionIdentifier),
              let orderId = info["orderId"] as? String else { return }
        await perform(action, orderId: orderId)
    }

    /// The button's move, made the way the same move is made in the app —
    /// into the book, offline-safe, sent on like any edit. Checked against
    /// the job as it is NOW: an alert tapped an hour later must not move a
    /// job someone has already moved.
    func perform(_ action: PrintAlertAction, orderId: String) async {
        let status = ((try? await api.fetchQueue()) ?? []).first { $0.id == orderId }?.status
        do {
            switch action {
            case .moveToPost:
                guard status == "printing" else { return }
                try await api.updateOrderStatus(orderId: orderId, status: "post")
            case .reprint:
                guard status == "printing" else { return }
                try await api.updateOrderStatus(orderId: orderId, status: "pending")
            case .markShipped:
                try await api.markShipped(orderId: orderId)
            }
        } catch {
            // Nothing to show it on; the job is as it was, and the app says
            // why the next time the person opens it.
        }
    }
}
