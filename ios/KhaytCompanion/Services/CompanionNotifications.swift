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
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted ?? false
        } else {
            isAuthorized = settings.authorizationStatus == .authorized
        }
    }

    func handleHealthUpdate(
        state: ConnectionHealthState,
        status: ShopStatus?,
        settings: ConnectionSettings
    ) {
        guard settings.notifyConnection else { return }
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
        livePrints: [WidgetPrint]? = nil
    ) {
        if settings.notifyQueueChanges {
            let q = status.queued
            let p = status.printing
            if let lq = lastQueued, let lp = lastPrinting, (lq != q || lp != p) {
                post(
                    id: "khayt.queue",
                    title: L10n.tr("notify.queue.title"),
                    body: String(format: L10n.tr("notify.queue.body"), q, p)
                )
            }
            lastQueued = q
            lastPrinting = p
        }

        if settings.notifyOverdue {
            let overdue = queue.filter(\.isOverdue).count
            if let prev = lastOverdueCount, overdue > prev, overdue > 0 {
                post(
                    id: "khayt.overdue",
                    title: L10n.tr("notify.overdue.title"),
                    body: String(format: L10n.tr("notify.overdue.body"), overdue)
                )
            }
            lastOverdueCount = overdue
        }

        if settings.notifyLowStock {
            if let prev = lastLowStock, lowStockCount > prev, lowStockCount > 0 {
                post(
                    id: "khayt.lowstock",
                    title: L10n.tr("notify.low_stock.title"),
                    body: String(format: L10n.tr("notify.low_stock.body"), lowStockCount)
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
                connected: true,
                updatedAt: Date(),
                // Carry over the last known prints when a caller (e.g. a health
                // poll) doesn't supply fresh live data, so it isn't clobbered.
                prints: livePrints ?? WidgetSnapshotStore.load()?.prints
            )
        )
    }

    func saveDisconnectedSnapshot(shopName: String) {
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
                prints: nil
            )
        )
    }

    private func post(id: String, title: String, body: String) {
        let tone: FeedItem.Tone = id == "khayt.overdue" || id == "khayt.offline" ? .late
            : id == "khayt.lowstock" ? .attention : .none
        let now = Date()
        ShopFeed.shared.add(FeedItem(id: id + "." + String(Int(now.timeIntervalSince1970)), kind: id,
                                     title: body.isEmpty ? title : title + " — " + body, at: now,
                                     tone: tone, unread: true, orderId: nil))
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id + ".\(Date().timeIntervalSince1970)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
