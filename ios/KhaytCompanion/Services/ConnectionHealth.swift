import Foundation

enum ConnectionHealthState: String, Sendable {
    case unknown
    case connected
    case unreachable
    case unauthorized

    var label: String {
        switch self {
        case .unknown: return L10n.tr("connection.checking")
        case .connected: return L10n.tr("connection.connected")
        case .unreachable: return L10n.tr("connection.unreachable")
        case .unauthorized: return L10n.tr("connection.unauthorized")
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: return "wifi.exclamationmark"
        case .connected: return "wifi"
        case .unreachable: return "wifi.slash"
        case .unauthorized: return "lock.slash"
        }
    }
}

@MainActor
final class ConnectionHealth: ObservableObject {
    @Published private(set) var state: ConnectionHealthState = .unknown
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastStatus: ShopStatus?
    /// Whether the Mac ITSELF answered the last check. Not the same as `state`:
    /// with a book on the phone, the screens read the book and `state` reads
    /// connected whether the Mac is there or not. The strip needs the truth.
    @Published private(set) var macInReach = false

    private let api: KhaytAPIClient
    private weak var settings: ConnectionSettings?
    private var task: Task<Void, Never>?

    init(api: KhaytAPIClient, settings: ConnectionSettings? = nil) {
        self.api = api
        self.settings = settings
    }

    func bind(settings: ConnectionSettings) {
        self.settings = settings
    }

    func startPolling(intervalSeconds: UInt64 = 30) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        task?.cancel()
        task = nil
    }

    func refresh() async {
        macInReach = await api.macAnswers()
        if !macInReach, await followTheMac() {
            macInReach = await api.macAnswers()
        }
        guard api.canSync else {
            state = .unreachable
            lastStatus = nil
            lastChecked = Date()
            notifyConnectionChange()
            if let settings { CompanionNotifications.shared.saveDisconnectedSnapshot(shopName: settings.shopLabel) }
            return
        }
        do {
            let status = try await api.fetchStatus()
            lastStatus = status
            do {
                let queue = try await api.fetchQueue()
                state = .connected
                await refreshWidgetsAndAlerts(status: status, queue: queue)
            } catch let err as KhaytAPIError {
                lastStatus = nil
                if case .unauthorized = err {
                    state = .unauthorized
                } else {
                    state = .unreachable
                    if let settings { CompanionNotifications.shared.saveDisconnectedSnapshot(shopName: settings.shopLabel) }
                }
            }
            lastChecked = Date()
            notifyConnectionChange()
        } catch let err as KhaytAPIError {
            lastStatus = nil
            if case .unauthorized = err { state = .unauthorized }
            else { state = .unreachable }
            lastChecked = Date()
            notifyConnectionChange()
            if let settings { CompanionNotifications.shared.saveDisconnectedSnapshot(shopName: settings.shopLabel) }
        } catch {
            lastStatus = nil
            state = .unreachable
            lastChecked = Date()
            notifyConnectionChange()
            if let settings { CompanionNotifications.shared.saveDisconnectedSnapshot(shopName: settings.shopLabel) }
        }
    }

    private func notifyConnectionChange() {
        guard let settings else { return }
        CompanionNotifications.shared.handleHealthUpdate(state: state, status: lastStatus, settings: settings)
    }

    /// The Mac did not answer at its stored address. If it is on this network
    /// under the name it was paired with, somewhere else, move there.
    ///
    /// At most once a minute: a Mac that is simply switched off answers no
    /// lookup either, and browsing every thirty seconds for a machine that is
    /// not there would be a phone doing work to be told nothing.
    private var lastLookup: Date?

    private func followTheMac(now: Date = Date()) async -> Bool {
        guard let settings, settings.isPaired, let name = settings.bonjourName else { return false }
        if let last = lastLookup, now.timeIntervalSince(last) < 60 { return false }
        lastLookup = now
        guard let found = await MacFinder.find(named: name) else { return false }
        guard found.host != settings.host || found.port != settings.port else { return false }
        settings.host = found.host
        settings.port = found.port
        if settings.serviceName.isEmpty { settings.serviceName = name }
        return true
    }

    private func refreshWidgetsAndAlerts(status: ShopStatus, queue: [QueueOrder]) async {
        guard let settings else { return }
        var lowStock = 0
        if settings.notifyLowStock {
            lowStock = (try? await api.fetchInventory())?.filter(\.isLowStock).count ?? 0
        }
        // Keep the home-screen widget's live print progress fresh on each poll.
        let livePrints = ((try? await api.fetchMachinesLive()) ?? [])
            .filter { $0.isPrinting }
            .map { WidgetPrint(id: $0.id, name: $0.displayName, progress: $0.progress ?? 0, eta: $0.etaText) }
        CompanionNotifications.shared.handleDashboardSnapshot(
            status: status,
            queue: queue,
            lowStockCount: lowStock,
            settings: settings,
            livePrints: livePrints
        )
    }
}
