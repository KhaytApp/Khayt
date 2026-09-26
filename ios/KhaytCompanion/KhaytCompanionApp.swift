import SwiftUI

@main
struct KhaytCompanionApp: App {
    @StateObject private var settings: ConnectionSettings
    @StateObject private var api: KhaytAPIClient
    @StateObject private var health: ConnectionHealth
    @StateObject private var nfc = NFCReader()
    @StateObject private var ordersNav = OrdersNavigationState()
    @StateObject private var live: LivePrinters
    @StateObject private var channel: LiveChannel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let s = ConnectionSettings()
        let apiClient = KhaytAPIClient(settings: s)
        let healthMonitor = ConnectionHealth(api: apiClient, settings: s)
        _settings = StateObject(wrappedValue: s)
        _api = StateObject(wrappedValue: apiClient)
        _health = StateObject(wrappedValue: healthMonitor)
        let printers = LivePrinters { try await apiClient.fetchLivePrinters() }
        _live = StateObject(wrappedValue: printers)
        _channel = StateObject(wrappedValue: LiveChannel(api: apiClient, printers: printers))
        KhaytType.applyNavigationBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(api)
                .environmentObject(health)
                .environmentObject(nfc)
                .environmentObject(ordersNav)
                .environmentObject(live)
                .companionLocale(settings)
                .tint(KhaytDesign.accent)
                // The design's face for everything that does not choose its own.
                .font(.khayt(17, relativeTo: .body))
                .task {
                    await CompanionNotifications.shared.requestAuthorizationIfNeeded()
                }
                // Nothing is polled for a screen nobody can see.
                .onChange(of: scenePhase) { _, phase in
                    live.setActive(phase == .active)
                    channel.setActive(phase == .active)
                }
                // Signing in or out of the cloud opens or closes the stream.
                .onChange(of: api.cloud) { _, _ in channel.setActive(scenePhase == .active) }
                .task { channel.setActive(true) }
        }
    }
}
