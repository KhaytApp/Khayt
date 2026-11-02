import Foundation

@MainActor
final class OrdersNavigationState: ObservableObject {
    @Published var pendingStatusFilter: OrderStatus?
    /// Bumped when any screen requests the Orders tab (including “see all” with no filter).
    @Published private(set) var ordersTabRequest = 0

    /// Bumped when a screen asks for Inventory showing only low stock — Shop
    /// Pulse's low-stock rail.
    @Published private(set) var lowStockRequest = 0
    @Published var pendingLowStock = false
    /// A model file opened into Khayt from another app, waiting for Home.
    @Published var quoteFileRequest: QuotedFile?

    func openLowStock() {
        pendingLowStock = true
        lowStockRequest += 1
    }

    func openOrders(filter: OrderStatus? = nil) {
        pendingStatusFilter = filter
        ordersTabRequest += 1
    }

    /// One job, opened over whatever screen is showing — a tapped alert.
    @Published var orderToOpen: String?
    /// The order requests waiting, asked for by a tapped request alert.
    @Published var intakeAsked = false

    func openOrder(id: String) { orderToOpen = id }
    func openIntake() { intakeAsked = true }
    /// The Orders tab on its Late chip, as Home's late figure opens it.
    func openOverdue() {
        UserDefaults.standard.set("orders_overdue", forKey: "khayt.orders.filter")
        openOrders()
    }

    /// Where a tapped alert goes: its job, the requests, the late jobs or the
    /// low shelf. Nil when it is about nothing the app can open.
    enum Destination: Equatable, Sendable { case order(String), intake, overdue, lowStock }

    nonisolated static func destination(identifier: String, thread: String,
                            userInfo: [AnyHashable: Any]) -> Destination? {
        if let id = userInfo["orderId"] as? String, !id.isEmpty { return .order(id) }
        if thread == "khayt.intake" || identifier.hasPrefix("intake.") { return .intake }
        if let k = userInfo["k"] as? [String: Any], k["kind"] as? String == "intake" { return .intake }
        if identifier.hasPrefix("khayt.overdue") { return .overdue }
        if identifier.hasPrefix("khayt.lowstock") { return .lowStock }
        return nil
    }

    func go(_ destination: Destination) {
        switch destination {
        case .order(let id): openOrder(id: id)
        case .intake: openIntake()
        case .overdue: openOverdue()
        case .lowStock: openLowStock()
        }
    }
}

/// A model file the phone holds a private copy of, to quote.
struct QuotedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    /// Copied into the app's own temporary folder: a file opened from another
    /// app or picked in Files is only readable while its security scope is
    /// open, and the estimate reads it later.
    static func copy(_ source: URL) -> QuotedFile? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appending(path: "quote-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: source.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: source, to: dest)) != nil else { return nil }
        return QuotedFile(url: dest)
    }
}
