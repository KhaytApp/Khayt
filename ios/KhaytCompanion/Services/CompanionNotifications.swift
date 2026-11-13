import Foundation
import UserNotifications

@MainActor
final class CompanionNotifications: ObservableObject {
    static let shared = CompanionNotifications()

    @Published private(set) var isAuthorized = false

    private var lastQueued: Int?
    private var lastPrinting: Int?
    private var lastConnectionOK = true
    private var lastOverdueCount: Int?
    private var lastLowStock: Int?

    func requestAuthorizationIfNeeded() async {
        // Skip the system permission prompt during automated screenshot runs.
        if ProcessInfo.processInfo.environment["KHAYT_SCREENSHOT"] != nil { return }
        #if DEBUG
        // The sample-shop launch line (see `KhaytCompanionApp`) is a screenshot run too.
        if UserDefaults.standard.bool(forKey: "KhaytSampleShop") { return }
        #endif
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted ?? false
        } else {
            isAuthorized = settings.authorizationStatus == .authorized
        }
    }

    /// Whether alerts are allowed now, read without asking — iOS Settings can
    /// change it while the app is away.
    func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let allowed = status == .authorized || status == .provisional || status == .ephemeral
        if allowed != isAuthorized { isAuthorized = allowed }
    }

    func handleHealthUpdate(
        state: ConnectionHealthState,
        status: ShopStatus?,
        settings: ConnectionSettings
    ) {
        // The sample shop has no Mac to lose: "Khayt disconnected" there is a
        // false alarm on a real phone, posted to someone trying the app.
        guard settings.notifyConnection, !settings.isSampleShop else { return }
        let ok = state == .connected
        if lastConnectionOK && !ok {
            post(
                id: "khayt.offline",
                title: L10n.tr("notify.offline.title"),
                body: L10n.tr("notify.offline.body")
            )
        }
        lastConnectionOK = ok
    }

    func handleDashboardSnapshot(
        status: ShopStatus,
        queue: [QueueOrder],
        lowStockCount: Int,
        settings: ConnectionSettings,
        livePrints: [WidgetPrint]? = nil,
        connected: Bool = true,
        asOf: Date = Date(),
        money: WidgetMoney? = nil
    ) {
        // Nothing in the sample shop happens, so nothing in it is news.
        let real = !settings.isSampleShop
        if real, settings.notifyQueueChanges {
            let q = status.queued
            let p = status.printing
            if let lq = lastQueued, let lp = lastPrinting, (lq != q || lp != p) {
                post(
                    id: "khayt.queue",
                    title: L10n.tr("notify.queue.title"),
                    body: L10n.format("notify.queue.body", q, p)
                )
            }
            lastQueued = q
            lastPrinting = p
        }

        if real, settings.notifyOverdue {
            let overdue = queue.filter(\.isOverdue).count
            if let prev = lastOverdueCount, overdue > prev, overdue > 0 {
                post(
                    id: "khayt.overdue",
                    title: L10n.tr("notify.overdue.title"),
                    body: L10n.format("notify.overdue.body", overdue)
                )
            }
            lastOverdueCount = overdue
        }

        if real, settings.notifyLowStock {
            if let prev = lastLowStock, lowStockCount > prev, lowStockCount > 0 {
                post(
                    id: "khayt.lowstock",
                    title: L10n.tr("notify.low_stock.title"),
                    body: L10n.format("notify.low_stock.body", lowStockCount)
                )
            }
            lastLowStock = lowStockCount
        }

        WidgetSnapshotStore.save(
            WidgetSnapshot(
                shopName: settings.shopLabel,
                queued: status.queued,
                printing: status.printing,
                post: status.post,
                qc: status.qc,
                completedToday: status.completedToday,
                connected: connected,
                updatedAt: asOf,
                // Carry over the last known prints when a caller (e.g. a health
                // poll) doesn't supply fresh live data, so it isn't clobbered.
                prints: livePrints ?? WidgetSnapshotStore.load()?.prints,
                // Nil clears the Money widget: the sample shop, no book.
                money: money
            )
        )
    }

    /// `keepMoney`: the shop is out of reach but still paired, so the Money
    /// widget keeps its last figures (it shows their age, and greys them once
    /// they are old). An unpaired phone keeps none of a shop's money.
    func saveDisconnectedSnapshot(shopName: String, keepMoney: Bool = true) {
        WidgetSnapshotStore.save(
            WidgetSnapshot(
                shopName: shopName,
                queued: 0,
                printing: 0,
                post: 0,
                qc: 0,
                completedToday: 0,
                connected: false,
                updatedAt: Date(),
                prints: nil,
                money: keepMoney ? WidgetSnapshotStore.load()?.money : nil
            )
        )
    }

    /// Every kind this instance has posted, in order (what the tests read).
    private(set) var posted: [String] = []

    private func post(id: String, title: String, body: String) {
        posted.append(id)
        let tone: FeedItem.Tone = id == "khayt.overdue" || id == "khayt.offline" ? .late
            : id == "khayt.lowstock" ? .attention : .none
        let now = Date()
        ShopFeed.shared.add(FeedItem(id: id + "." + String(Int(now.timeIntervalSince1970)), kind: id,
                                     title: body.isEmpty ? title : title + " — " + body, at: now,
                                     tone: tone, unread: true, orderId: nil))
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.filterCriteria = NotificationKind.shop
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id + ".\(Date().timeIntervalSince1970)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
