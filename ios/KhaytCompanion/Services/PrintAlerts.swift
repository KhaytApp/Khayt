import Foundation
import Combine
import UserNotifications
import KhaytCore

/// Notices a print ending in successive live readings.
///
/// Only a machine SEEN printing and then seen not printing counts. A machine
/// that drops out of the readings, or that the phone first sees idle, is not
/// a finished print — the phone was simply not looking when it ran. Nor is
/// one whose poll failed (`isUnheard`): the print is still on the bed.
struct FinishDetector {
    private var printing: [String: (since: Date, filename: String?)] = [:]

    mutating func observe(_ readings: [String: MachineLiveStatus], now: Date = Date()) -> [PrintFinished] {
        var ended: [PrintFinished] = []
        for (id, r) in readings {
            let isPrinting = r.isPrinting
            if r.isPaused { continue }      // still on the bed: neither started nor ended
            if r.isUnheard { continue }     // a missed poll: not heard, not ended
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
    /// Where a tapped alert opens. Set by the app as it starts, before any
    /// alert that launched it is handed over.
    weak var navigation: OrdersNavigationState?
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
    func receive(kind: String, ciphertext: Data?, dek: Data, at: String = "", ref: [String: String]? = nil) async {
        if kind == "intake" {
            await announceIntake(at: at)
            return
        }
        if let key = Self.shopAlertKeys[kind] {
            await announceShop(kind: kind, key: key, at: at, ref: ref)
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
        c.filterCriteria = NotificationKind.intake
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// The kinds the stream carries that Apple would otherwise say — while
    /// the stream is open Apple's copy is held back (see `willPresent`), so
    /// the app says each itself, in the same words, routed the same way.
    nonisolated static let shopAlertKeys: [String: String] = [
        "overdue": "PUSH_OVERDUE", "low-stock": "PUSH_LOW_STOCK", "due-today": "PUSH_DUE_TODAY",
        "quote-decision": "PUSH_QUOTE_DECISION", "message": "PUSH_MESSAGE", "payment": "PUSH_PAYMENT",
    ]

    func announceShop(kind: String, key: String, at: String, ref: [String: String]?) async {
        let id = kind + "." + (at.isEmpty ? ISO8601DateFormatter().string(from: Date()) : at)
        var body = L10n.tr(key)
        if kind == "quote-decision", let d = ref?["decision"] {
            body = L10n.tr(d == "approve" ? "PUSH_QUOTE_APPROVED" : "PUSH_QUOTE_DECLINED")
        }
        let tone: FeedItem.Tone = ["overdue"].contains(kind) ? .late : (kind == "low-stock" ? .attention : .none)
        ShopFeed.shared.add(FeedItem(id: id, kind: kind, title: body,
                                     at: ISO8601DateFormatter().date(from: at) ?? Date(), tone: tone,
                                     unread: true, orderId: nil))
        // Apple's copy of these is always shown (see `alwaysPushed`); a
        // second banner from the stream would say it twice.
        if Self.alwaysPushed.contains(kind), api.receivesPush { return }
        let c = UNMutableNotificationContent()
        c.title = L10n.tr("PUSH_TITLE")
        c.body = body
        c.sound = .default
        c.threadIdentifier = "khayt.shop"
        c.filterCriteria = NotificationKind.shop
        var k: [String: Any] = ["kind": kind, "at": at]
        if let ref { k["ref"] = ref }
        c.userInfo = ["k": k]
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
        PrintAlertText.content(for: event, orderStatus: orderStatus, locale: L10n.locale, tr: L10n.tr)
    }

    // MARK: - UNUserNotificationCenterDelegate

    // The completion-handler forms, never the `async` ones: UIKit asserts its
    // completion runs on the main thread, and a `nonisolated async` delegate
    // method ends on whichever thread its last line ran on. A tap that
    // returned early (the Mac's test alert, linked to no job) ended on a
    // background thread and the app aborted (TestFlight 202611131908, Nov 14).
    // Here the work runs on the main actor and the completion is called there,
    // on every path.

    /// Shown even with the app open: a print ending is worth a banner —
    /// except Apple's copy of something the open stream says itself.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        let fromApple = notification.request.trigger is UNPushNotificationTrigger
        let kind = Self.pushKind(notification.request.content.userInfo)
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            let held = fromApple && Self.streamSays(kind: kind) && (self.printers?.streamOpen ?? false)
            done(held ? [] : [.banner, .sound, .list])
        }
    }

    /// Kinds whose push is ALWAYS shown, even with the stream open: a
    /// customer's answer, message or payment must never be lost to a stream
    /// that dropped it (push review P8, Dev Hub Nov 13). The stream's own copy
    /// of these goes to the feed only, so each is said once.
    nonisolated static let alwaysPushed: Set<String> = ["quote-decision", "message", "payment"]

    /// True when the open stream says this kind itself, so Apple's copy may be
    /// held back. Unknown kinds and pushes with no kind are always shown.
    nonisolated static func streamSays(kind: String?) -> Bool {
        guard let kind else { return false }
        return ["print-finished", "intake", "overdue", "low-stock", "due-today"].contains(kind)
    }

    /// The `kind` of a pushed alert: the cloud's `k` block, or a rewritten
    /// print alert (which keeps `k`, and is a print ending by its `outcome`).
    nonisolated static func pushKind(_ info: [AnyHashable: Any]) -> String? {
        if let kind = (info["k"] as? [String: Any])?["kind"] as? String { return kind }
        return info["outcome"] != nil ? "print-finished" : nil
    }

    /// The shop an alert is about, when it says: a rewritten print alert's
    /// `shopId`, or the cloud's `k.shopId`.
    nonisolated static func pushShop(_ info: [AnyHashable: Any]) -> String? {
        (info["shopId"] as? String) ?? (info["k"] as? [String: Any])?["shopId"] as? String
    }

    /// May a tapped alert act on this phone's book? Not when it names a shop
    /// other than the one signed in (push review P2): its job id would open,
    /// or move, a job of the wrong shop. An alert that names no shop — a
    /// local one, or from an older cloud — is this phone's own.
    nonisolated static func belongsHere(_ info: [AnyHashable: Any], signedInShop: String?) -> Bool {
        guard let shop = pushShop(info) else { return true }
        return shop == signedInShop
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let identifier = request.identifier
        let thread = request.content.threadIdentifier
        let action = response.actionIdentifier
        nonisolated(unsafe) let info = request.content.userInfo
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            await self.handleTap(identifier: identifier, thread: thread, userInfo: info, action: action)
            done()
        }
    }

    /// A tapped alert, or one of its buttons — on the main actor.
    func handleTap(identifier: String, thread: String, userInfo info: [AnyHashable: Any], action: String) async {
        // Another shop's alert, from before a sign-out or a switch: open the
        // app, act on nothing.
        guard Self.belongsHere(info, signedInShop: api.cloud?.shopId) else { return }
        // The alert itself tapped, not one of its buttons: open what it is about.
        if action == UNNotificationDefaultActionIdentifier {
            guard var to = OrdersNavigationState.destination(identifier: identifier, thread: thread,
                                                             userInfo: info) else { return }
            if case .published(let item) = to {
                to = await api.orderId(publishedItem: item).map { .order($0) } ?? .orders
            }
            navigation?.go(to)
            return
        }
        guard let move = PrintAlertAction(rawValue: action),
              let orderId = info["orderId"] as? String else { return }
        await perform(move, orderId: orderId)
    }

    /// The button's move, made the way the same move is made in the app —
    /// into the book, offline-safe, sent on like any edit. Checked against
    /// the job as it is NOW: an alert tapped an hour later must not move a
    /// job someone has already moved.
    /// A Live Activity's button: the same move, for the one job printing on
    /// that machine — none when there is not exactly one, as the alert's rule.
    func perform(move: String, machineId: String) async {
        let onMachine = ((try? await api.fetchQueue()) ?? [])
            .filter { $0.machineId == machineId && $0.status == "printing" }
        guard onMachine.count == 1 else { return }
        await perform(move == "post" ? .moveToPost : .reprint, orderId: onMachine[0].id)
    }

    func perform(_ action: PrintAlertAction, orderId: String) async {
        let status = ((try? await api.fetchQueue()) ?? []).first { $0.id == orderId }?.status
        var notes: [String] = []
        do {
            switch action {
            case .moveToPost:
                guard status == "printing" else { return }
                notes = try await api.updateOrderStatus(orderId: orderId, status: "post")
            case .reprint:
                guard status == "printing" else { return }
                notes = try await api.updateOrderStatus(orderId: orderId, status: "pending")
            case .markShipped:
                try await api.markShipped(orderId: orderId)
            }
        } catch {
            // Nothing to show it on; the job is as it was, and the app says
            // why the next time the person opens it.
            return
        }
        // What the shop's rules did with the move — filament taken back, a
        // spool running low — said the only place a button tap from the lock
        // screen can be answered: one quiet follow-up alert.
        if let content = Self.notesContent(notes) {
            try? await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: "move.\(orderId).\(Date().timeIntervalSince1970)",
                                           content: content, trigger: nil))
        }
    }

    /// The follow-up for a move's notes — nil when the rules said nothing.
    /// No sound and no buttons: the person has just acted, this only tells
    /// them what followed.
    nonisolated static func notesContent(_ notes: [String]) -> UNMutableNotificationContent? {
        guard !notes.isEmpty else { return nil }
        let c = UNMutableNotificationContent()
        c.title = L10n.tr("PUSH_TITLE")
        c.body = notes.joined(separator: "\n")
        c.threadIdentifier = "khayt.move"
        c.interruptionLevel = .passive
        return c
    }
}
