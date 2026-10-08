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
    static let settingsTab = 5
    @Binding var selectedTab: Int
    let tabs: [KhaytTabItem]
    @EnvironmentObject private var health: ConnectionHealth
    @EnvironmentObject private var ordersNav: OrdersNavigationState

    var body: some View {
        // The system's TabView, not a bar of our own: on iPhone Duo only
        // TabView (and UITabBarController) move to the trailing edge of the
        // outer display and can become a sidebar on the inner one — Apple's
        // iPhone Duo Q&A, "custom bars won't auto-adapt". `sidebarAdaptable`
        // is a bottom bar on iPhone and a sidebar where there is room.
        TabView(selection: $selectedTab) {
            // Five in the bar — an iPhone tab bar holds five, and a sixth put
            // Clients and Settings behind "More". `.sidebarOnly` alone does
            // not prevent that on iPhone (measured), so in compact width the
            // Settings tab is not there at all and Home's gear opens it; in
            // regular width (iPad, iPhone Duo's inner display) it is a
            // sidebar-only tab.
            ForEach(shownTabs) { item in
                Tab(item.title, systemImage: item.icon, value: item.id) {
                    page(item.id)
                }
                .tabPlacement(item.id == Self.settingsTab ? .sidebarOnly : .automatic)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(KhaytDesign.accent)
        .onAppear { health.startPolling(); keepSelectionShown() }
        .onDisappear { health.stopPolling() }
        .onChange(of: ordersNav.lowStockRequest) { _, _ in
            selectedTab = 2
        }
        .onChange(of: ordersNav.ordersTabRequest) { _, _ in
            selectedTab = 1
        }
        // Folding iPhone Duo with Settings open takes that tab away, and so
        // does asking for it in compact width: Home, rather than a blank page.
        .onChange(of: widthClass) { _, _ in keepSelectionShown() }
        .onChange(of: selectedTab) { _, _ in keepSelectionShown() }
    }

    private func keepSelectionShown() {
        if !shownTabs.contains(where: { $0.id == selectedTab }) { selectedTab = 0 }
    }

    @Environment(\.horizontalSizeClass) private var widthClass

    private var shownTabs: [KhaytTabItem] { Self.shown(tabs, regularWidth: widthClass == .regular) }

    static func shown(_ tabs: [KhaytTabItem], regularWidth: Bool) -> [KhaytTabItem] {
        regularWidth ? tabs : tabs.filter { $0.id != settingsTab }
    }

    /// One tab's page: the screen background, the connection banner, the screen.
    /// Per tab rather than around the TabView, so the banner sits over the
    /// content column when the tabs are a sidebar.
    private func page(_ id: Int) -> some View {
        ZStack {
            KhaytScreenBackground()
            VStack(spacing: 0) {
                ConnectionBanner()
                tabContent(id)
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ id: Int) -> some View {
        switch id {
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
