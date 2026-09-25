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
                                                      updaterDelegate: launchProbe,
                                                      userDriverDelegate: nil)
        // Never install without asking — see the note on `checksAutomatically`.
        controller.updater.automaticallyDownloadsUpdates = false
        do {
            try controller.updater.start()
            self.controller = controller
            // ── AT LAUNCH: ASK, AND OFFER WHAT IS FOUND ───────────────────
            //
            // The shop (Sep 2026): "the app should check for updates at launch
            // and offer the user to update if an update exists". It did check
            // — `checkForUpdatesInBackground` — but with "install
            // automatically" on (as this shop's Mac has it), Sparkle's
            // background check downloads SILENTLY and installs on quit, and
            // nothing is ever offered. So launch PROBES instead
            // (`checkForUpdateInformation`, no UI), and only when it finds a
            // version does it open the standard offer — once the probe's cycle
            // has ended, since Sparkle ignores a check while one is running.
            // Nothing new: nothing shown, not a "you're up to date" every
            // launch. Sparkle's hourly schedule carries on as it was.
            if controller.updater.automaticallyChecksForUpdates {
                launchProbe.armed = true
                controller.updater.checkForUpdateInformation()
            }
        } catch {
            // A shop cannot act on this and the app works without it, so it is
            // not a dialog. It IS a log line, because "updates silently never
            // happened" is the failure that hides for months.
            FileHandle.standardError.write(Data(
                "updates: Sparkle would not start — \(error.localizedDescription)\n".utf8))
        }
    }

    /// The launch probe's delegate — see `init`.
    private let launchProbe = LaunchProbe()

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

    // NO "install automatically". The shop (Sep 2026): "should never auto
    // update, should always ask for permission". Sparkle is told so twice:
    // `SUAllowsAutomaticUpdates` is NO in the bundle (make-app.sh), which makes
    // it refuse silent installs whatever a Mac has stored, and the stored
    // setting is switched off at every launch below, for a Mac that had it on.
}

/// The switch, in Settings → App Preferences → On this Mac.
///
/// This Mac's choice, applied the moment it is flipped — not part of the pane's
/// Save, which writes the shop's book to every device.
struct UpdateToggles: View {
    let shop: Shop
    @State private var checks = Updates.shared.checksAutomatically

    var body: some View {
        Toggle(shop.words.callIt("mac.updates_auto_check"), isOn: $checks)
            .disabled(!Updates.shared.isAvailable)
            .onChange(of: checks) { _, on in Updates.shared.checksAutomatically = on }
        // Said, because the switch that installed silently is gone: the app
        // asks before every update.
        Text(shop.words.callIt("mac.updates_always_ask"))
            .font(.caption).foregroundStyle(.secondary)
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

/// Hears the launch probe, and opens the offer when it found a version.
final class LaunchProbe: NSObject, SPUUpdaterDelegate {
    /// Only the probe made at launch opens the offer; Sparkle's own scheduled
    /// checks keep their own behaviour.
    @MainActor var armed = false
    @MainActor private var found = false

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { if armed { found = true } }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard armed, updateCheck == .updateInformation else { return }
            armed = false
            guard found else { return }
            found = false
            // The next run-loop turn: the probe's session has ended by then.
            DispatchQueue.main.async { updater.checkForUpdates() }
        }
    }
}
