import Foundation
import Combine
import UserNotifications
import KhaytCore

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
    private weak var printers: LivePrinters?
    /// When each machine last had an alert. One ending can be noticed three
    /// ways — the phone's own readings, the stream's event, Apple's push —
    /// and is said once.
    private var said: [String: Date] = [:]
    private static let sameEnding: TimeInterval = 10 * 60

    init(api: KhaytAPIClient, settings: ConnectionSettings, printers: LivePrinters) {
        self.api = api
        self.settings = settings
        self.printers = printers
        super.init()
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(PrintAlertAction.categories(tr: L10n.tr))
        center.delegate = self
        watching = printers.$byMachine.dropFirst().sink { [weak self] readings in
            guard let self, printers.isLive else { return }
            let ended = self.detector.observe(readings)
            guard !ended.isEmpty else { return }
            Task { await self.announce(ended) }
        }
    }

    /// A shop event off Khayt Cloud's stream: opened with the shop's key,
    /// and said if it is one this phone knows. Unknown kinds are ignored.
    func receive(kind: String, ciphertext: Data?, dek: Data, at: String = "") async {
        if kind == "intake" {
            await announceIntake(at: at)
            return
        }
        guard let ciphertext, let event = Self.open(kind: kind, ciphertext: ciphertext, dek: dek) else { return }
        await announce([event])
    }

    /// A customer's order request, told by the cloud's stream while the app
    /// is open — the same words Apple would show on a locked phone (Apple's
    /// own copy is held back while the stream is open, so it is said once).
    func announceIntake(at: String) async {
        let id = "intake." + (at.isEmpty ? ISO8601DateFormatter().string(from: Date()) : at)
        ShopFeed.shared.add(FeedItem(id: id, kind: "intake", title: L10n.tr("PUSH_INTAKE"),
                                     at: ISO8601DateFormatter().date(from: at) ?? Date(), tone: .attention,
                                     unread: true, orderId: nil))
        let c = UNMutableNotificationContent()
        c.title = L10n.tr("PUSH_TITLE")
        c.body = L10n.tr("PUSH_INTAKE")
        c.sound = .default
        c.threadIdentifier = "khayt.intake"
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// A sealed `print-finished` event, opened — nil for any other kind, or
    /// for one this phone cannot open (a different shop's key).
    nonisolated static func open(kind: String, ciphertext: Data, dek: Data) -> PrintFinished? {
        guard kind == "print-finished",
              let blob = try? JSONDecoder().decode(SyncCrypto.Blob.self, from: ciphertext),
              let plain = try? SyncCrypto.openStore(blob, dek: dek) else { return nil }
        return try? JSONDecoder().decode(PrintFinished.self, from: plain)
    }

    /// Say that a print ended, with the one button that makes sense for it.
    func announce(_ events: [PrintFinished], now: Date = Date()) async {
        guard settings.notifyPrintDone else { return }
        let events = events.filter { e in
            if let last = said[e.machineId], now.timeIntervalSince(last) < Self.sameEnding { return false }
            said[e.machineId] = now
            return true
        }
        guard !events.isEmpty else { return }
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
            ShopFeed.shared.add(ShopFeed.item(for: event, id: id, tr: L10n.tr))
            try? await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// The alert itself — the same builder the notification service
    /// extension uses for a push, so an ending reads the same however it came.
    nonisolated static func content(for event: PrintFinished, orderStatus: String?) -> UNMutableNotificationContent {
        PrintAlertText.content(for: event, orderStatus: orderStatus, tr: L10n.tr)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even with the app open: a print ending is worth a banner —
    /// except Apple's copy of an ending the open stream has already said.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let fromApple = notification.request.trigger is UNPushNotificationTrigger
        if fromApple, await MainActor.run(body: { self.printers?.streamOpen ?? false }) { return [] }
        return [.banner, .sound, .list]
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
