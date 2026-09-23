import SwiftUI
import Sparkle

/// Keeping the app up to date, which it could not do at all.
///
/// ── WHY THIS EXISTS, AND WHY IT IS SPARKLE ────────────────────────────────
///
/// The Electron app has updated itself since it shipped. This one had no way
/// to, so a shop that installed it would stay on that build until somebody
/// noticed and downloaded another by hand — and this app is becoming the main
/// Khayt on macOS, which makes "no updates" a promise to fall behind.
///
/// Sparkle rather than something written here. Updating an app in place is
/// privileged, fiddly work — replace the bundle a running process is inside,
/// verify what you downloaded before you trust it, survive a failure without
/// leaving a half-app on disk — and a version of that written from scratch
/// would be the least reviewed code in the product doing the most dangerous
/// thing in it.
///
/// ── TWO SIGNATURES, AND THEY ARE NOT THE SAME CHECK ───────────────────────
///
/// An update has to pass both before Sparkle will install it:
///
///   Apple's   the downloaded app is signed by the same Developer ID as the
///             one running, and notarised. Answers "did Apple let this out".
///   EdDSA     the archive matches the signature in the appcast, made with a
///             private key that lives in a Keychain and in one CI secret.
///             Answers "did WE publish this".
///
/// The second is the one that matters if the download is ever intercepted or
/// the hosting is compromised: an attacker who can replace the zip cannot
/// produce the signature for it. `SUPublicEDKey` in `Info.plist` is the public
/// half, and it is written into the bundle at build time by `make-app.sh`.
///
/// ── IT IS NOT STARTED FOR EVERY LAUNCH ────────────────────────────────────
///
/// `startingUpdater: false`, then started explicitly. The snapshot runner opens
/// this app sixty-odd times in a row to photograph every screen; an updater
/// that woke up in each of those would hammer the feed and, worse, could put a
/// modal over the screen being photographed. `KHAYT_SNAPSHOT_DIR` is the same
/// signal the rest of the harness uses.
@MainActor
final class Updates {
    static let shared = Updates()

    /// Nil when this build cannot update itself, which is not a failure:
    /// an unsigned local build has no feed to ask and nothing to verify with.
    private(set) var controller: SPUStandardUpdaterController?

    private init() {
        // No feed, no updater. `make-app.sh` writes `SUFeedURL` only for a
        // build that is actually published, so `swift run Khayt` and an ad-hoc
        // bundle get an app with the menu item disabled rather than one that
        // asks a URL that is not there and reports an error for it.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        guard ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DIR"] == nil else { return }

        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
            // AT LAUNCH, as well as on Sparkle's hourly schedule — when the
            // shop has left automatic checks on. Sparkle's own scheduler waits
            // out the interval from the LAST check, so a Mac opened each
            // morning could run yesterday's build until lunchtime. In the
            // background: a found update is offered, nothing interrupts.
            if controller.updater.automaticallyChecksForUpdates {
                controller.updater.checkForUpdatesInBackground()
            }
        } catch {
            // A shop cannot act on this and the app works without it, so it is
            // not a dialog. It IS a log line, because "updates silently never
            // happened" is the failure that hides for months.
            FileHandle.standardError.write(Data(
                "updates: Sparkle would not start — \(error.localizedDescription)\n".utf8))
        }
    }

    /// Can this build check at all? Drives whether the menu item is enabled,
    /// so a local build says so by being greyed out rather than by failing.
    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.updater.checkForUpdates() }

    /// Whether this Mac looks for updates by itself — Sparkle's own setting,
    /// kept in this Mac's defaults, never in the shop's book.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Whether a found update is downloaded and installed on quit without
    /// asking. Off unless the shop turns it on.
    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }
}

/// The two switches, in Settings → App Preferences → On this Mac.
///
/// This Mac's choice, applied the moment it is flipped — not part of the pane's
/// Save, which writes the shop's book to every device.
struct UpdateToggles: View {
    let shop: Shop
    @State private var checks = Updates.shared.checksAutomatically
    @State private var installs = Updates.shared.installsAutomatically

    var body: some View {
        Toggle(shop.words.callIt("mac.updates_auto_check"), isOn: $checks)
            .disabled(!Updates.shared.isAvailable)
            .onChange(of: checks) { _, on in
                Updates.shared.checksAutomatically = on
                if !on { installs = false }
            }
        Toggle(shop.words.callIt("mac.updates_auto_install"), isOn: $installs)
            .disabled(!Updates.shared.isAvailable || !checks)
            .onChange(of: installs) { _, on in Updates.shared.installsAutomatically = on }
        if !Updates.shared.isAvailable {
            // A local build has no feed; say so rather than show dead switches.
            Text(shop.words.callIt("mac.updates_unavailable"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The menu item, in the app menu where macOS puts it in every other app.
///
/// Disabled rather than hidden on a build with no feed: a menu that changes
/// shape between builds is one people stop trusting, and "greyed out" is the
/// system's own way of saying not here.
struct CheckForUpdatesCommand: View {
    let shop: Shop

    var body: some View {
        Button(shop.words.callIt("mac.check_updates")) {
            Updates.shared.checkForUpdates()
        }
        .disabled(!Updates.shared.isAvailable)
    }
}
