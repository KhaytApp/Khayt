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
    /// `published`: the cloud's own alerts about a customer's page (a quote
    /// answered, a message, a payment) name it by `ref.item`, the first 16
    /// hex of SHA-256 of its token — the phone matches that to a job.
    enum Destination: Equatable, Sendable { case order(String), intake, overdue, lowStock, orders, published(String) }

    nonisolated static func destination(identifier: String, thread: String,
                            userInfo: [AnyHashable: Any]) -> Destination? {
        if let id = userInfo["orderId"] as? String, !id.isEmpty { return .order(id) }
        if thread == "khayt.intake" || identifier.hasPrefix("intake.") { return .intake }
        if let k = userInfo["k"] as? [String: Any], k["kind"] as? String == "intake" { return .intake }
        if let k = userInfo["k"] as? [String: Any], let kind = k["kind"] as? String {
            switch kind {
            case "overdue": return .overdue
            case "low-stock": return .lowStock
            case "due-today": return .orders
            case "quote-decision", "message", "payment":
                if let ref = k["ref"] as? [String: Any], let item = ref["item"] as? String, !item.isEmpty {
                    return .published(item.lowercased())
                }
                return .orders
            default: break
            }
        }
        if identifier.hasPrefix("khayt.overdue") { return .overdue }
        if identifier.hasPrefix("khayt.lowstock") { return .lowStock }
        return nil
    }

    /// A `khayt://` link, in the Mac's shapes (`mac/.../DeepLink.swift`):
    /// `job/<id>`, `machine/<id>`, `screen/<name>`. Navigate only; anything
    /// else is nothing. Returns the tab to show, if the link names one.
    enum Link: Equatable { case job(String), tab(Int), orders(OrderStatus?) }

    nonisolated static func link(_ url: URL) -> Link? {
        guard url.scheme?.lowercased() == "khayt", let host = url.host()?.lowercased() else { return nil }
        let rest = url.path().split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let first = rest.first, !first.isEmpty else { return nil }
        switch host {
        case "job": return .job(first)
        case "machine": return .tab(3)
        case "spool": return .tab(2)
        case "screen":
            let parts = first.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "dashboard": return .tab(0)
            case "board", "jobs": return .orders(parts.count > 1 ? OrderStatus(rawValue: parts[1]) : nil)
            case "inventory": return .tab(2)
            case "machines": return .tab(3)
            case "customers": return .tab(4)
            default: return nil
            }
        default: return nil
        }
    }

    func go(_ destination: Destination) {
        switch destination {
        case .order(let id): openOrder(id: id)
        case .intake: openIntake()
        case .overdue: openOverdue()
        case .lowStock: openLowStock()
        case .orders, .published: openOrders()
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
