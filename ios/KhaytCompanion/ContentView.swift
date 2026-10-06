import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0

    private let tabs: [KhaytTabItem] = [
        KhaytTabItem(id: 0, title: L10n.tr("tab.home"), icon: "house.fill"),
        KhaytTabItem(id: 1, title: L10n.tr("tab.orders"), icon: "rectangle.stack.fill"),
        KhaytTabItem(id: 2, title: L10n.tr("tab.inventory"), icon: "cylinder.split.1x2.fill"),
        KhaytTabItem(id: 3, title: L10n.tr("tab.machines"), icon: "printer.fill"),
        KhaytTabItem(id: 4, title: L10n.tr("tab.clients"), icon: "person.2.fill"),
        KhaytTabItem(id: 5, title: L10n.tr("tab.settings"), icon: "gearshape.fill")
    ]

    var body: some View {
        Group {
            if Self.hasAShop(settings: settings, signedInToCloud: api.cloud != nil) {
                MainTabView(selectedTab: $selectedTab, tabs: tabs)
            } else {
                PairingView()
            }
        }
        .onAppear { applyPendingTab() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { applyPendingTab() }
        }
    }

    /// Paired with a Mac, set up from Khayt Cloud alone, or opened on the
    /// sample shop — each is a shop to show. The sample shop has neither an
    /// address nor a sign-in by design, and before it was named here the
    /// "Explore with a sample shop" button wrote its book and then left the
    /// phone on the pairing screen, which is where beta review is sent in.
    static func hasAShop(settings: ConnectionSettings, signedInToCloud: Bool) -> Bool {
        settings.isPaired && (settings.isConfigured || signedInToCloud || settings.isSampleShop)
    }

    private func applyPendingTab() {
        guard let key = UserDefaults.standard.string(forKey: "khayt.pending.tab") else { return }
        UserDefaults.standard.removeObject(forKey: "khayt.pending.tab")
        switch key {
        case "orders": selectedTab = 1
        case "inventory": selectedTab = 2
        case "machines": selectedTab = 3
        case "clients": selectedTab = 4
        case "settings": selectedTab = 5
        default: break
        }
    }
}

struct MainTabView: View {
    @Binding var selectedTab: Int
    let tabs: [KhaytTabItem]
    @EnvironmentObject private var health: ConnectionHealth
    @EnvironmentObject private var ordersNav: OrdersNavigationState

    var body: some View {
        ZStack {
            KhaytScreenBackground()
            VStack(spacing: 0) {
                ConnectionBanner()
                tabContent
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            KhaytTabBar(selection: $selectedTab, items: tabs)
        }
        .tint(KhaytDesign.accent)
        .onAppear { health.startPolling() }
        .onDisappear { health.stopPolling() }
        .onChange(of: ordersNav.lowStockRequest) { _, _ in
            selectedTab = 2
        }
        .onChange(of: ordersNav.ordersTabRequest) { _, _ in
            selectedTab = 1
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0: DashboardView()
        case 1: OrdersView()
        case 2: InventoryView()
        case 3: MachinesView()
        case 4: ClientsView()
        case 5: SettingsView()
        default: DashboardView()
        }
    }
}
