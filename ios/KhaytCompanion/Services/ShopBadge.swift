import BackgroundTasks
import Foundation
import UserNotifications

/// The number on the app icon: Home's "Needs you" count, the same figure the
/// greeting says (Turki, Nov 13).
///
/// The app works it out and sets it on opening, on every change to the book,
/// and in a background refresh just after midnight, when jobs turn late. It
/// writes it into `alert-index.json` too, so the notification extension can
/// put the same number on a pushed alert. Nothing adds one per alert: that
/// drifts from the screen. Khayt Cloud sends no `badge` at all, since it
/// cannot read the book. Zero clears it, and so do signing out and switching shops.
@MainActor
final class ShopBadge {
    static let shared = ShopBadge()
    /// The background refresh's identifier (Info.plist `BGTaskSchedulerPermittedIdentifiers`).
    static let refreshTask = "com.khaytapp.companion.badge"

    private weak var api: KhaytAPIClient?
    private var watch: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    /// Puts the number on the icon. Tests replace it.
    var apply: (Int) async -> Void = { n in try? await UNUserNotificationCenter.current().setBadgeCount(n) }
    /// Where the alert index lives: the shared book's folder. Tests replace it.
    var directory: () -> URL? = { try? CompanionBook.inSharedContainer().directory }
    /// What the icon was last set to, for tests and to skip a repeat.
    private(set) var current: Int?

    /// Follow the book from now on.
    func start(api: KhaytAPIClient) {
        self.api = api
        watch = NotificationCenter.default.addObserver(forName: .khaytBookChanged, object: nil, queue: .main) { [weak self] note in
            let changed = (note.object as? URL)?.standardizedFileURL
            MainActor.assumeIsolated {
                // Only this phone's own book; a test's book in a temporary
                // folder is not the shop.
                guard let self, changed == self.directory()?.standardizedFileURL else { return }
                self.bookChanged()
            }
        }
    }

    /// A sync round can write the book several times in a second: work the
    /// count out once, after the last.
    private func bookChanged() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.recompute()
        }
    }

    /// Set the icon to `count` (zero clears it) and tell the extension.
    func set(_ count: Int) async {
        let n = max(0, count)
        if let dir = directory() { AlertIndex.setBadge(n, in: dir) }
        current = n
        await apply(n)
    }

    func clear() async { await set(0) }

    /// Home's count, worked out from the book on this phone. Only from the
    /// book: without one, the phone would have to ask the Mac, and Home sets
    /// the count itself whenever it loads. The sample shop has nothing that
    /// needs anyone.
    func recompute() async {
        guard let api else { return }
        guard !api.isSampleShop, api.holdsBook else {
            if api.isSampleShop || !api.hasShop { await clear() }
            return
        }
        guard let queue = try? await api.fetchQueue() else { return }
        let spools = (try? await api.fetchInventory()) ?? []
        let waiting = (try? await api.fetchWaitingList()) ?? []
        let quotes = try? await api.fetchRecentOrders(limit: 200, status: OrderStatus.quote.rawValue)
        await set(NeedsYou.summary(queue: queue, spools: spools, waiting: waiting, quotes: quotes).total)
    }

    // MARK: - Background refresh

    /// Ask iOS for a refresh a few minutes after the next local midnight, when
    /// yesterday's due jobs turn late. iOS decides when it really runs.
    static func scheduleRefresh(now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = nextRefresh(after: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func nextRefresh(after now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(24 * 3600)
        return tomorrow.addingTimeInterval(5 * 60)
    }

    /// The refresh itself: the count from the book, then the next one asked for.
    func backgroundRefresh() async {
        await recompute()
        Self.scheduleRefresh()
    }
}
