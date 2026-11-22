import Foundation

/// When this Mac sends what it has changed, without being asked.
///
/// ── WHY THIS WAS THE LAST THING MISSING ────────────────────────────────────
///
/// Khayt pushes to the cloud on every save — `renderer/app-state.js` calls
/// `KhaytCloudSync.scheduleSync()` at the end of the save chain, debounced so a
/// burst of edits becomes one upload. This app pushed only when somebody opened
/// *Check the cloud* and pressed *Send*, twice.
///
/// So an edit made here stayed here. A shop with two machines drifting apart is
/// the failure that costs most and announces itself least, and the sidebar has
/// been saying "Not synced automatically" in small grey type in the hope that
/// somebody reads it.
///
/// ── THE NUMBERS ARE KHAYT'S ────────────────────────────────────────────────
///
/// Debounce and backoff are `renderer/cloud-sync.js`'s own, so two machines in
/// one shop behave the same way under the same load. They are stated here as
/// constants rather than reached for through the bridge because they are
/// scheduling, not a rule about a shop's money — and because a timer that has
/// to cross into JavaScript to learn how long to wait is a timer that stops
/// working the moment the engine fails to load.
enum AutoSync {

    /// One save is rarely one save. Khayt's `DEFAULT_DEBOUNCE_MS`.
    static let debounce: Duration = .milliseconds(2500)

    /// After a failure — offline, a refused token, a service having a bad
    /// minute. Doubling, capped, exactly as `scheduleRetry` does.
    static let retryBase: Duration = .seconds(5)
    static let retryCeiling: Duration = .seconds(5 * 60)

    static func retryDelay(attempt: Int) -> Duration {
        // `attempt` is how many have already failed: 0 → base, 1 → 2×base, …
        let steps = max(0, min(attempt, 20))
        let base = retryBase.components.seconds
        let seconds = base << steps                      // base · 2^steps, no Double
        let capped = min(seconds, retryCeiling.components.seconds)
        return .seconds(capped)
    }

    /// How long a shop whose delta chain is CLOSED must wait between whole-book
    /// uploads.
    ///
    /// A shop the service has gated cannot append one change at a time; every
    /// push is the entire store, and on this app that means a backup, a merge
    /// of the cloud into the book, a rewrite of the book and a megabyte on the
    /// wire. Doing that two and a half seconds after each keystroke-sized edit
    /// would be a shop's whole day of typing turned into a hundred full
    /// uploads and a hundred backups.
    ///
    /// Deltas keep the fast cadence. Only the expensive path gets a floor, and
    /// the floor is long enough to be cheap and short enough that a second
    /// machine is never more than a quarter of an hour behind.
    static let wholeBookFloor: TimeInterval = 15 * 60

    /// May the whole book go up now, given when it last did?
    ///
    /// `nil` means it has not this session, which is always allowed: the first
    /// push after opening the app is the one that carries whatever was changed
    /// while it was closed.
    static func mayPushWholeBook(lastAt: Date?, now: Date = Date()) -> Bool {
        guard let lastAt else { return true }
        return now.timeIntervalSince(lastAt) >= wholeBookFloor
    }

    /// May a write we just made be pushed on its own?
    ///
    /// Three conditions, pulled out of the early return they used to be so they
    /// can be pinned. An early return that quietly answers "no" for the wrong
    /// reason is the shape of this feature's worst failure: nothing happens,
    /// nothing is said, and the shop finds out from the other machine.
    ///
    /// `canWrite` is the one worth explaining. This Mac often opens a book
    /// another Khayt owns, read-only. The whole-book push MERGES the cloud into
    /// the book before uploading, which needs the lock — and the app that does
    /// hold it is syncing anyway. So a read-only book syncs nothing from here,
    /// deliberately, rather than half-syncing and failing at the write.
    static func shouldSyncOnWrite(unlocked: Bool, connected: Bool, canWrite: Bool) -> Bool {
        unlocked && connected && canWrite
    }

    /// What the sidebar says.
    ///
    /// Khayt's own status vocabulary, minus the states this app cannot be in.
    /// `locked` is the one that matters and the one Khayt does not have: the
    /// data key here lives only as long as the app does, so a shop that has not
    /// unlocked the cloud since launch is not broken — it is locked, and the
    /// difference is a sentence rather than an error.
    enum Status: Equatable, Sendable {
        /// No cloud on this book, or the sample shop.
        case off
        /// Connected, but nobody has unlocked the data key this session.
        case locked
        /// Unlocked, nothing waiting.
        case idle
        /// A push is in flight.
        case syncing
        /// Everything this Mac had is up, as of this moment.
        case synced(Date)
        /// Something is waiting — a debounce, a floor, or a backoff.
        case waiting
        /// The last attempt failed, and it will be tried again.
        case failing(String)
    }
}
