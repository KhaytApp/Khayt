import SwiftUI
import KhaytCore
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

    /// When a check last WENT OUT, for the Internet use pane's "Last
    /// checked". Not Sparkle's `lastUpdateCheckDate`: Sparkle moves that on a
    /// refused check too (read in `SPUUpdater.m`, `abortUpdateDriver`), so
    /// under the switch it would always say "just now".
    nonisolated static let lastAllowedKey = "updates.lastAllowedCheck"
    var lastChecked: Date? {
        UserDefaults.standard.object(forKey: Self.lastAllowedKey) as? Date ?? (
            OutboundGate.shared.verdict(.updates).allowed ? controller?.updater.lastUpdateCheckDate : nil)
    }

    /// The shop's book has been read. A launch check that the switch held
    /// back while the settings were unknown is made now, if they allow it.
    func bookWasRead() {
        guard let controller, launchProbe.waitsForBook else { return }
        launchProbe.waitsForBook = false
        guard controller.updater.automaticallyChecksForUpdates, OutboundGate.shared.verdict(.updates).allowed else { return }
        launchProbe.armed = true
        controller.updater.checkForUpdateInformation()
    }

    // ── "BEFORE YOU UPDATE" IS READ BEFORE THE UPDATE WINDOW OPENS ────────
    //
    // `UpdateGate.swift` (Mac file page 28, frame C). Sparkle's window is
    // opened in ONE place, `showOffer`, and Sparkle is refused in its own
    // hook (`shouldProceedWithUpdate`) for a version whose items nobody has
    // ticked, so its scheduler and anything else meet the same answer.

    /// Each version found, and its unread items once its file was asked for
    /// (empty: nothing to read, or it could not be read). In memory: asked
    /// again in the next run.
    private var known: [String: [KhaytEngine.GatedRelease]] = [:]
    private var looking: Set<String> = []
    /// A version found before there was a window to hold it in.
    private var waiting: String?
    /// The app's one shop: held, so an update found while its window is
    /// closed is still looked into.
    private var shop: Shop?
    /// TESTS ONLY: Sparkle's "a check is running" and "open the window".
    var busyForTests: (() -> Bool)?
    var openForTests: (() -> Void)?
    private var opening = false

    /// The window an update is held in. A version found earlier is taken up now.
    func attach(_ shop: Shop) {
        self.shop = shop
        if let version = waiting { waiting = nil; offer(version) }
    }

    /// "Check for Updates…", by hand. It LOOKS first, without Sparkle's
    /// window, so a version that must be read about meets Khayt's sheet and
    /// not a refusal. Nothing found, or no check possible: Sparkle's own
    /// check follows and says so in its own words.
    func checkForUpdates() {
        guard let controller else { return }
        // A check is running or Sparkle's window is open: this brings the
        // window forward, as it always did. Nothing new is started.
        guard !controller.updater.sessionInProgress else { openSparkle(); return }
        launchProbe.armed = true
        launchProbe.byHand = true
        controller.updater.checkForUpdateInformation()
    }

    /// A check found `version`: Sparkle's window, Khayt's sheet first, or
    /// find out which.
    func offer(_ version: String) {
        guard let shop else { waiting = version; return }
        switch UpdateGate.verdict(known[version]) {
        case .proceed: showOffer()
        case .hold(let releases): shop.holdUpdate(version, releases)
        case .ask:
            guard !looking.contains(version) else { return }
            looking.insert(version)
            Task { @MainActor in
                let unread = await shop.updateGateItems(for: version)
                self.looking.remove(version)
                self.known[version] = unread
                self.offer(version)
            }
        }
    }

    /// Sparkle's hook asks: may this version be shown and downloaded? No
    /// while it has items nobody ticked, or while that is not known yet; and
    /// asking starts the finding out, which ends in the sheet or in Sparkle's
    /// window (`offer`), so a refusal here is never the end of it.
    ///
    /// REFUSED WHILE NOT KNOWN, and not let through: Sparkle's own hourly
    /// check is usually the first to see a new version, and letting an
    /// unknown one through would open the update window around the sheet
    /// for exactly the releases it exists for. The finding out always ends
    /// (5 seconds at most, and every failure counts as "nothing to read"),
    /// so this is a wait, never a block.
    ///
    /// Returns the sentence Sparkle shows for a refused check made by hand,
    /// or nil to go on.
    func mayProceed(_ version: String) -> String? {
        let verdict = UpdateGate.verdict(known[version])
        if verdict == .proceed { return nil }
        offer(version)
        return Words.upfront(verdict == .ask ? "mac.upgate_looking" : "mac.upgate_hold")
    }

    /// The items were ticked: this version is clear, and its window opens.
    func wasRead(_ version: String) {
        known[version] = []
        showOffer()
    }

    /// Sparkle's update window, ONCE SPARKLE WILL TAKE THE CALL.
    ///
    /// Sparkle drops `checkForUpdates` while a session is in progress, and
    /// one is in progress exactly when this is wanted: after a check ends,
    /// Sparkle marks a new session before it schedules the next check
    /// (`SPUUpdater.m`, the driver's completion, read for 2.9.6), and after a
    /// refused check made by hand its alert holds the session until OK. One
    /// hop to the next run-loop turn, as this used to do, was swallowed: a
    /// check by hand with nothing new showed nothing at all (review of this
    /// change). So it waits for the session to end, and gives up after five
    /// minutes rather than open a window nobody is waiting for.
    func showOffer() {
        guard !opening else { return }
        opening = true
        Task { @MainActor in
            for _ in 0..<1200 where self.sparkleIsBusy { try? await Task.sleep(for: .milliseconds(250)) }
            self.opening = false
            if !self.sparkleIsBusy { self.openSparkle() }
        }
    }

    private var sparkleIsBusy: Bool { busyForTests?() ?? controller?.updater.sessionInProgress ?? false }

    /// The one place Sparkle is asked for its window.
    private func openSparkle() {
        if let stand = openForTests { stand(); return }
        controller?.updater.checkForUpdates()
    }

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
    /// The probe was asked for from the menu: with nothing found, Sparkle's
    /// own check follows, to say "up to date" or why it could not ask.
    @MainActor var byHand = false
    @MainActor private var found: String?
    /// A check was refused because the shop's book had not been read yet.
    @MainActor var waitsForBook = false

    /// Sparkle asks before EVERY check, scheduled or by hand (its documented
    /// hook: `-updater:mayPerformUpdateCheck:error:`, which in Swift throws to
    /// refuse). "Make no internet calls" refuses here, so no feed is fetched.
    /// A check somebody asked for by hand shows the reason in Sparkle's own
    /// alert, in the shop's words; a scheduled one is counted on its row.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try mayCheck()
        UserDefaults.standard.set(Date(), forKey: Updates.lastAllowedKey)
    }

    /// Asked again once an update is found and before it is downloaded: an
    /// alert left open across turning the switch on must not fetch the
    /// archive when Install is clicked.
    nonisolated func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                             updateCheck: SPUUpdateCheck) throws {
        do { try OutboundGate.shared.require(.updates) }
        catch let blocked as OutboundBlocked {
            throw NSError(domain: "app.khayt.outbound", code: 1, userInfo: [
                NSLocalizedDescriptionKey: Self.reason(blocked)])
        }
        // A look without a window shows and downloads nothing.
        guard updateCheck != .updateInformation else { return }
        // "Before you update" first (`Updates.mayProceed`). This is the lock:
        // whatever started the check, a version with unread items stops here.
        let version = updateItem.displayVersionString
        let refusal = Thread.isMainThread ? MainActor.assumeIsolated { Updates.shared.mayProceed(version) }
                                          : DispatchQueue.main.sync { MainActor.assumeIsolated { Updates.shared.mayProceed(version) } }
        if let refusal {
            throw NSError(domain: "app.khayt.update-gate", code: 1, userInfo: [NSLocalizedDescriptionKey: refusal])
        }
    }

    /// The hook's own answer, apart from Sparkle's types so it can be tested.
    nonisolated func mayCheck() throws {
        do { try OutboundGate.shared.require(.updates) }
        catch let blocked as OutboundBlocked {
            if blocked.reason == "settings-unknown" {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.waitsForBook = true } }
            }
            throw NSError(domain: "app.khayt.outbound", code: 1, userInfo: [
                NSLocalizedDescriptionKey: Self.reason(blocked)])
        }
    }

    /// The sentence Sparkle shows. This can be asked off the main thread, so
    /// the words are fetched on it.
    nonisolated static func reason(_ blocked: OutboundBlocked) -> String {
        if Thread.isMainThread { return blocked.errorDescription ?? blocked.description }
        return DispatchQueue.main.sync { blocked.errorDescription ?? blocked.description }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { if armed { found = item.displayVersionString } }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard armed, updateCheck == .updateInformation else { return }
            armed = false
            let hand = byHand, version = found
            byHand = false
            found = nil
            if let version { Updates.shared.offer(version) }
            else if hand { Updates.shared.showOffer() }
        }
    }
}
