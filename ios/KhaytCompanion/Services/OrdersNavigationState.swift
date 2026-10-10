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
