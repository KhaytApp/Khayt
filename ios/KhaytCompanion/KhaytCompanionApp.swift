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
        #if DEBUG
        Self.openForScreenshots(apiClient)
        #endif
    }

    #if DEBUG
    /// `-KhaytOpen <what>` on the launch line: one screen opened once, so the
    /// detail pages and sheets can be photographed too. Home takes `quote`,
    /// `waste`, `expense`, `addspool`, `intake`, `settings` and `order:<id>`;
    /// Inventory takes `spool:<id>`; Orders takes `neworder`.
    enum ScreenshotOpen {
        private static var used = false
        /// The request, if it starts with `prefix` and nobody has taken it yet.
        @MainActor static func take(_ prefix: String) -> String? {
            guard !used, let v = UserDefaults.standard.string(forKey: "KhaytOpen"), v.hasPrefix(prefix) else { return nil }
            used = true
            return String(v.dropFirst(prefix.count))
        }
    }

    /// `-KhaytSampleShop YES -KhaytTab orders` on the launch line: the sample
    /// shop, opened on that tab, so every screen can be photographed from the
    /// command line (`simctl launch`) without a tap. Debug builds only.
    private static func openForScreenshots(_ api: KhaytAPIClient) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "KhaytSampleShop") { try? api.openSampleShop() }
        if let tab = defaults.string(forKey: "KhaytTab") {
            defaults.set(tab, forKey: "khayt.pending.tab")
        }
    }
    #endif

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
