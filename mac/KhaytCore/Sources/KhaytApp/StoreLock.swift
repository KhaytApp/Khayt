import Foundation
import KhaytCore

/// Who owns the shop's book.
///
/// A port of `lib/store-lock.js`, and the second module in this app written
/// twice — for the same reason as `LibraryLocation`: it is a protocol two
/// different runtimes have to agree on, and it reaches the filesystem and the
/// process table, neither of which JavaScriptCore has. `StoreLockParityTests`
/// runs both against the same cases.
///
/// The Electron app takes ownership for its whole session and refreshes a
/// heartbeat. This app reads that record and says what it found. It does not
/// take the lock, because it does not write — and a reader that claimed
/// ownership would lock a shop out of its own app for nothing.
enum StoreLock {

    /// Three missed heartbeats. Consulted only where liveness cannot be — see
    /// `decide`.
    static let staleAfterMs: Double = 90_000
    static let filename = "khayt-store.lock"

    struct Record: Codable, Equatable, Sendable {
        var app: String?
        var pid: Int?
        var host: String?
        var takenAt: Double?
        var heartbeat: Double?
    }

    enum Action: String, Equatable, Sendable { case take, own, held }

    struct Verdict: Equatable, Sendable {
        let action: Action
        let holder: Record?
        let reason: String
    }

    /// A hostname, comparably.
    ///
    /// `ProcessInfo.hostName` and Node's `os.hostname()` return the SAME machine
    /// in different case — `turkis-macbook-air.local` against
    /// `Turkis-MacBook-Air.local`. Compared raw, this app reads the Electron
    /// app's lock as coming from another machine, stops asking whether that pid
    /// is alive, and falls back to the clock: a live holder whose heartbeat
    /// lagged would have its lock taken. Two writers, which is the one thing
    /// this file exists to prevent. Hostnames are case-insensitive by
    /// convention, so folding is not a workaround.
    private static func host(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A heartbeat in the FUTURE is not stale. Two machines never agree on the
    /// time, and treating a negative age as old breaks a live holder's lock
    /// instantly — the one outcome this exists to prevent.
    private static func isStale(_ record: Record, now: Double) -> Bool {
        now - (record.heartbeat ?? 0) >= staleAfterMs
    }

    /// What the lock record means. `alive` answers "is that pid running on THIS
    /// machine?", and is nil when it cannot be known — which includes every
    /// record written by another host.
    static func decide(_ existing: Record?, pid: Int, host hostName: String,
                       now: Double, alive: Bool?) -> Verdict {
        guard let existing else {
            return Verdict(action: .take, holder: nil, reason: "no-lock")
        }
        let theirPid = existing.pid ?? 0
        let theirHost = host(existing.host)
        guard theirPid != 0 else {
            // Not a lock record: truncated by a crash, hand-edited, a stray file.
            // A holder that can never be disproved would wedge the app.
            return Verdict(action: .take, holder: nil, reason: "unreadable")
        }
        let myHost = Self.host(hostName)
        if theirPid == pid && theirHost == myHost {
            return Verdict(action: .own, holder: existing, reason: "already-ours")
        }
        // Pids are unique per host only. Without this, one machine adopts
        // another's lock the moment the numbers collide.
        if !theirHost.isEmpty && !myHost.isEmpty && theirHost != myHost {
            return isStale(existing, now: now)
                ? Verdict(action: .take, holder: existing, reason: "other-host-stale")
                : Verdict(action: .held, holder: existing, reason: "other-host-fresh")
        }
        // LIVENESS BEATS TIME. A running process still owns the store even if it
        // has not written a heartbeat for an hour — paused at a breakpoint,
        // stopped by the OS, or busy through a long import.
        if alive == true { return Verdict(action: .held, holder: existing, reason: "holder-alive") }
        if alive == false { return Verdict(action: .take, holder: existing, reason: "holder-gone") }
        return isStale(existing, now: now)
            ? Verdict(action: .take, holder: existing, reason: "unknown-stale")
            : Verdict(action: .held, holder: existing, reason: "unknown-fresh")
    }

    // MARK: - The impure half

    static func lockURL(for build: StoreReader.Build) -> URL {
        build.storeURL.deletingLastPathComponent().appending(path: filename)
    }

    static func read(for build: StoreReader.Build) -> Record? {
        guard let data = try? Data(contentsOf: lockURL(for: build)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Is that pid a running process? `EPERM` means it exists and is not ours.
    static func pidIsAlive(_ pid: Int) -> Bool {
        if pid <= 0 { return false }
        // A damaged lock file: a pid beyond Int32 trapped here, and a negative
        // one made kill() signal-check every process and read as alive.
        guard let p = pid_t(exactly: pid), p > 0 else { return false }
        if kill(p, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The verdict for a store on this Mac, right now.
    static func verdict(for build: StoreReader.Build) -> Verdict {
        let record = read(for: build)
        let host = ProcessInfo.processInfo.hostName
        let sameHost = record.map { Self.sameHost($0.host, host) } ?? false
        let alive: Bool? = (sameHost && (record?.pid ?? 0) != 0)
            ? pidIsAlive(record!.pid!) : nil
        return decide(record, pid: Int(ProcessInfo.processInfo.processIdentifier),
                      host: host, now: Date().timeIntervalSince1970 * 1000, alive: alive)
    }

    /// Take ownership, if it is free. Returns the record we wrote, or nil when
    /// somebody else has it — in which case this app stays a reader.
    @discardableResult
    static func take(for build: StoreReader.Build, appName: String = "Khayt for Mac") -> Record? {
        guard verdict(for: build).action != .held else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        let record = Record(app: appName,
                            pid: Int(ProcessInfo.processInfo.processIdentifier),
                            host: ProcessInfo.processInfo.hostName,
                            takenAt: now, heartbeat: now)
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        try? data.write(to: lockURL(for: build))
        return record
    }

    /// Keep the claim fresh — ONLY while it is still ours.
    ///
    /// Electron takes the book unconditionally when it starts. This used to
    /// write our record back every thirty seconds regardless, so the lock
    /// flipped between the two apps, both believed they owned the book, and
    /// Electron's next save of its in-memory copy erased whatever the Mac had
    /// written. Found by a review. Now a beat first reads the file: somebody
    /// else's record there means we have lost the book, and nil says so.
    static func beat(_ record: Record, for build: StoreReader.Build) -> Record? {
        guard let current = read(for: build), current.pid == record.pid,
              sameHost(current.host, record.host) else { return nil }
        var next = record
        next.heartbeat = Date().timeIntervalSince1970 * 1000
        if let data = try? JSONEncoder().encode(next) { try? data.write(to: lockURL(for: build)) }
        return next
    }

    /// Host names compared the way Electron writes them (lowercased).
    static func sameHost(_ a: String?, _ b: String?) -> Bool {
        (a ?? "").lowercased() == (b ?? "").lowercased()
    }

    /// Give it up. Only ever removes a record that is ours — Electron takes
    /// ownership unconditionally on startup, and deleting its claim on our way
    /// out would leave the book looking unowned while it is being written to.
    static func release(_ record: Record?, for build: StoreReader.Build?) {
        guard let record, let build, let current = read(for: build) else { return }
        guard current.pid == record.pid,
              host(current.host) == host(record.host) else { return }
        try? FileManager.default.removeItem(at: lockURL(for: build))
    }

    /// Do we hold it right now? Asked again immediately before a write lands.
    static func weOwnIt(_ build: StoreReader.Build) -> Bool {
        verdict(for: build).action == .own
    }

    /// Who holds it, as FACTS rather than a sentence.
    ///
    /// The sentence used to be built here, and this file is nonisolated — it
    /// runs below the interface with no language in scope — so the sidebar
    /// line every screen carries read "Khayt for Mac has this book open" in
    /// English under an Arabic toolbar. Facts have no language; the window
    /// says them in the shop's.
    ///
    /// Never a pid: what matters is which application, and — when it is
    /// elsewhere — which machine.
    struct Held: Equatable, Sendable {
        /// The application's own name, or nil when it did not give one.
        let app: String?
        /// The other machine, or nil when it is this one.
        let host: String?
    }

    static func held(_ verdict: Verdict, selfHost: String = ProcessInfo.processInfo.hostName) -> Held? {
        guard verdict.action == .held, let holder = verdict.holder else { return nil }
        let theirHost = host(holder.host)
        let elsewhere = !theirHost.isEmpty && theirHost != host(selfHost)
        return Held(app: (holder.app ?? "").isEmpty ? nil : holder.app,
                    host: elsewhere ? holder.host : nil)
    }

    /// The same, in English, for the writer's refusals.
    ///
    /// Those are the layer that has no language either and, unlike the sidebar
    /// line, no view to hand the words to — see `WordsAreTranslatedTests.exempt`.
    static func describe(_ verdict: Verdict, selfHost: String = ProcessInfo.processInfo.hostName) -> String? {
        guard let holder = held(verdict, selfHost: selfHost) else { return nil }
        let who = holder.app ?? "Another copy of Khayt"
        let where_ = holder.host.map { " on \($0)" } ?? ""
        return "\(who)\(where_) has this book open"
    }
}
