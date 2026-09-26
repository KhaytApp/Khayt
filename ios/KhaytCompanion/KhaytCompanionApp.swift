import SwiftUI

/// For the one thing SwiftUI has no hook for: the APNs device token.
final class PushTokenDelegate: NSObject, UIApplicationDelegate {
    static var api: KhaytAPIClient?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Self.api?.didReceivePushToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No push on this build — the simulator, or a build signed without
        // the `aps-environment` entitlement, which waits on Push being turned
        // on for com.khaytapp.companion in the developer portal. Alerts still
        // come from the live readings and the stream while the app is open.
    }
}

@main
struct KhaytCompanionApp: App {
    @UIApplicationDelegateAdaptor(PushTokenDelegate.self) private var pushDelegate
    @StateObject private var settings: ConnectionSettings
    @StateObject private var api: KhaytAPIClient
    @StateObject private var health: ConnectionHealth
    @StateObject private var nfc = NFCReader()
    @StateObject private var ordersNav = OrdersNavigationState()
    @StateObject private var live: LivePrinters
    @StateObject private var channel: LiveChannel
    @Environment(\.scenePhase) private var scenePhase
    /// Held for the life of the app: it is the notification centre's delegate,
    /// which must be in place before a tapped alert launches the app.
    private let alerts: PrintAlertCenter

    init() {
        let s = ConnectionSettings()
        let apiClient = KhaytAPIClient(settings: s)
        let healthMonitor = ConnectionHealth(api: apiClient, settings: s)
        _settings = StateObject(wrappedValue: s)
        _api = StateObject(wrappedValue: apiClient)
        _health = StateObject(wrappedValue: healthMonitor)
        let printers = LivePrinters { try await apiClient.fetchLivePrinters() }
        _live = StateObject(wrappedValue: printers)
        let channel = LiveChannel(api: apiClient, printers: printers)
        _channel = StateObject(wrappedValue: channel)
        let center = PrintAlertCenter(api: apiClient, settings: s, printers: printers)
        alerts = center
        channel.onEvent = { kind, at, ciphertext, session in
            await center.receive(kind: kind, ciphertext: ciphertext, dek: session.dek, at: at)
        }
        PushTokenDelegate.api = apiClient
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
