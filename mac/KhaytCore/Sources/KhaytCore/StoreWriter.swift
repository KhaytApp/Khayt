import Foundation

/// Changing a shop's book — on whichever device is holding it.
///
/// Three rules, and each is a failure this app would otherwise have.
///
/// **It never decrypts.** The secrets on disk are already `__enc__` strings, so
/// an edit to some other field carries them through untouched and SafeStorage is
/// never involved. Decrypting to re-encrypt would put a working credential one
/// bad round trip away from being unreadable, for no gain. What that buys is
/// paid for by `StoreRoundTripTests`, which proves a whole store survives the
/// JSON decode and encode value for value — because if it did not, every
/// record's fingerprint would move and `stampChanges` would push the entire book
/// to the cloud as changes nobody made.
///
/// **It reads from disk, inside the write.** Never from anything this app is
/// already holding. `store-io`'s `updateStoreOnDisk` learned this the hard way:
/// a read taken outside the write means a second caller works from the state
/// before the first change and puts it back.
///
/// **It writes only while it owns the book.** Ownership is checked before the
/// read and again immediately before the swap, so the window in which Electron
/// could take over is the width of one serialisation rather than a whole edit.
public enum StoreWriter {

    /// Told after every successful write, with the store that was written.
    ///
    /// ── WHY A HOOK HERE AND NOT A CALL AT EACH WRITE ─────────────────────
    ///
    /// Twenty-one places in `Shop` change the book, each followed by its own
    /// reload. Automatic sync has to hear about all of them and about the
    /// twenty-second somebody adds next month — and a trigger a new write path
    /// can simply forget to call is the shape of bug this repo keeps finding:
    /// correct code with no caller.
    ///
    /// `atomicWrite` is the one place every write actually lands, both the
    /// synchronous `update` and the async one, so hearing about it here cannot
    /// be bypassed by adding a path. Fired only after the swap succeeds: a
    /// refused or failed write did not change the book and must not schedule a
    /// push of something that is not there.
    ///
    /// Hopped to the main actor because the synchronous `update` is not on it
    /// and the listener — `Shop` — is.
    @MainActor public static var didWrite: (@MainActor (URL) -> Void)?

    /// Matches `MAX_STORE_BYTES` in lib/store-io.js. Every safety net — the
    /// daily backup, the iCloud copy, the pre-update snapshot — is built to that
    /// number, so writing past it produces a store nothing can protect.
    public static let maxStoreBytes = 50_000_000

    public enum Refusal: Error, CustomStringConvertible {
        case notOurs(String)
        case tooLarge(Int)
        case unreadable(String)

        public var description: String {
            switch self {
            case .notOurs(let who):
                return "\(who). Nothing was changed — only the app that owns the book may write to it."
            case .tooLarge(let n):
                return "That change would make the store \(n) bytes, past the \(maxStoreBytes) "
                     + "every backup is built to hold. Nothing was written."
            case .unreadable(let why):
                return "Could not read the store to change it: \(why)"
            }
        }
    }

    /// The same, addressed by path.
    ///
    /// Not a convenience: it is the seam the tests need. Everything below runs
    /// against a copy of a real store in a temp directory, because a write path
    /// whose only trial run was on a shop's live book has not been tested, it
    /// has been risked.
    public static func update(storeURL url: URL,
                       owns: () -> Bool,
                       whoHasIt: () -> String?,
                       mutate: (inout [String: JSONValue]) throws -> Void) throws {
        guard owns() else {
            throw Refusal.notOurs(whoHasIt() ?? "Another app owns this book")
        }

        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw Refusal.unreadable(error.localizedDescription) }
        guard var root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw Refusal.unreadable("\(url.lastPathComponent) is not JSON")
        }

        try mutate(&root)

        let encoder = JSONEncoder()
        let next = try encoder.encode(root)
        guard next.count <= maxStoreBytes else { throw Refusal.tooLarge(next.count) }

        // Asked again, as late as it can be. Electron takes ownership on startup
        // whatever it finds, so between the read and here it may have become the
        // owner; writing then would lose whatever it has since done.
        guard owns() else {
            throw Refusal.notOurs(whoHasIt() ?? "Another app took the book")
        }
        try atomicWrite(next, to: url)
    }

    /// The same, for a change that has to ask the shared JavaScript what to do.
    ///
    /// Moving a job runs `order-status` and `order-deduction` inside the write,
    /// and the engine is an actor — so the mutation suspends. It must still
    /// happen between the read and the swap, because the whole reason the read
    /// is inside the write is that a change computed from a stale copy puts the
    /// stale copy back.
    ///
    /// The ownership check after the mutation therefore matters more here, not
    /// less: the window is now a JavaScript call wide rather than a
    /// serialisation, and it is the last thing checked before the swap.
    /// `@MainActor` because its caller is, and because everything it does is
    /// either file I/O the synchronous version already does on this thread or a
    /// hop to the engine actor. Leaving it nonisolated only means handing three
    /// closures across an isolation boundary they have no reason to cross.
    @MainActor
    public static func update(storeURL url: URL,
                       owns: () -> Bool,
                       whoHasIt: () -> String?,
                       mutate: (inout [String: JSONValue]) async throws -> Void) async throws {
        guard owns() else {
            throw Refusal.notOurs(whoHasIt() ?? "Another app owns this book")
        }

        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw Refusal.unreadable(error.localizedDescription) }
        guard var root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw Refusal.unreadable("\(url.lastPathComponent) is not JSON")
        }

        try await mutate(&root)

        let next = try JSONEncoder().encode(root)
        guard next.count <= maxStoreBytes else { throw Refusal.tooLarge(next.count) }
        guard owns() else {
            throw Refusal.notOurs(whoHasIt() ?? "Another app took the book")
        }
        try atomicWrite(next, to: url)
    }

    /// Temp file, fsync, then swap — the same shape as `atomicWriteStoreUnsafe`.
    ///
    /// The temp name carries our pid and a fresh UUID, so a crash can orphan a
    /// temp file but no two writers can ever be handed the same path to
    /// cross-write — the failure that once left a shop with a corrupt primary,
    /// a corrupt `.prev`, and the setup wizard. The old
    /// store rolls to `.prev` first: one generation of rollback, and the file
    /// `recoverStoreRaw` reaches for when the primary will not parse.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
        let fm = FileManager.default
        fm.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: data)
            // fsync, not just close: a crash between the write and the swap must
            // not leave a temp file that is shorter than it claims to be.
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmp)
            throw error
        }
        let prev = url.appendingPathExtension("prev")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: prev)
            try? fm.moveItem(at: url, to: prev)   // rollback copy is best-effort
        }
        do { try fm.moveItem(at: tmp, to: url) }
        catch {
            try? fm.removeItem(at: tmp)           // never leave a stray temp behind
            throw error
        }
        // AFTER the swap, and only on success. See `didWrite`.
        Task { @MainActor in StoreWriter.didWrite?(url) }
    }

    // MARK: - Stamping

    /// Mark a record as changed, the way `renderer/sync.js` stampChanges does.
    ///
    /// The renderer's sync baseline is an in-memory index seeded from the store
    /// on load, so a change written here that did NOT bump `rev` would look, to
    /// the next Electron launch, exactly like the state it had always been in —
    /// and would never reach the cloud. Bumping it makes the edit
    /// self-describing whether or not Electron ever runs again.
    public static func stamp(_ record: inout [String: JSONValue]) {
        let rev: Double
        if case .number(let n)? = record["rev"] { rev = n + 1 } else { rev = 1 }
        record["rev"] = .number(rev)
        record["updatedAt"] = .string(iso(Date()))
    }

    /// `new Date().toISOString()` — millisecond precision, always UTC, always Z.
    public static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: date)
    }

    /// A record put back as it was, but moving forward.
    ///
    /// An undo restores every field EXCEPT `rev`, which carries on from where
    /// the record is now and is then stamped. A revision that went backwards
    /// would look to the next sync exactly like the change never happened, and
    /// the other machine's copy would win — the undo would be undone, by a
    /// laptop, quietly.
    public static func restoring(_ wanted: [String: JSONValue],
                          over current: [String: JSONValue]) -> [String: JSONValue] {
        var out = wanted
        out["rev"] = current["rev"]
        stamp(&out)
        return out
    }

    public static func updateRecord(storeURL: URL, owns: () -> Bool, whoHasIt: () -> String?,
                             collection: String, id: String,
                             change: (inout [String: JSONValue]) -> Void) throws {
        try update(storeURL: storeURL, owns: owns, whoHasIt: whoHasIt) { root in
            guard case .array(var rows)? = root[collection] else { return }
            guard let index = rows.firstIndex(where: {
                if case .object(let o) = $0, case .string(let rowId)? = o["id"] { return rowId == id }
                return false
            }) else { return }
            guard case .object(var record) = rows[index] else { return }
            change(&record)
            stamp(&record)
            rows[index] = .object(record)
            root[collection] = .array(rows)
        }
    }
}
