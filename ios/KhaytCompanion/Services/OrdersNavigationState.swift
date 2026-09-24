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

    func openLowStock() {
        pendingLowStock = true
        lowStockRequest += 1
    }

    func openOrders(filter: OrderStatus? = nil) {
        pendingStatusFilter = filter
        ordersTabRequest += 1
    }
}
