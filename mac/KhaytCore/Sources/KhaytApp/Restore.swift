import Foundation
import KhaytCore

/// Putting a backup back.
///
/// The other half of `Backups`. A shop that can take a copy of its book but
/// cannot put one back is only half protected, and the half it is missing is
/// the one it needs on the worst day.
///
/// Restoring REPLACES a shop's entire book, so almost all of this file is the
/// refusals. Three of them are lessons this codebase has already paid for.
///
/// **It validates before it destroys.** `renderer/app-state.js` used to zero
/// all thirty-one collections and only then hand the snapshot to a function
/// that early-returns on a bad one — so picking the wrong `.json` wiped the
/// shop's database and toasted "restored successfully". The check that catches
/// that is `looksLikeStore`, and it is asked here through the same module, not
/// a Swift opinion about what a store looks like.
///
/// **A backup does not carry everything the store holds.** Khayt builds its
/// daily backup out of the renderer's export payload, and two kinds of field
/// never reach the renderer at all:
///
/// - the shop's CREDENTIALS, which arrive masked as `__KHAYT_MASKED__` —
///   printer API keys, LAN access codes, the Telegram token, the cloud token,
///   the Drive refresh token;
/// - `printerCompletions`, the printer poll's completion history, which the
///   main process owns and `normalizeStoreSnapshot` drops.
///
/// Electron survives that because every save runs `mergeStoreSecretsFromDisk`
/// on the way to disk. A plain copy here would not: it would write the mask
/// over every credential the shop has and delete the completion history, and
/// the only symptom would be printers that stopped answering. So the restore
/// MERGES — the backup's records, the current book's secrets and main-owned
/// keys — exactly as Electron's save path does.
///
/// **The cloud must be told to forget what it thinks the server has.** A
/// restore moves local state backwards. `lib/cloud-backend.js` §7 spells out
/// what happens next if the retained server view survives it: the next push
/// ships every rolled-back record as a delta, or worse pushes a full blob the
/// server accepts, and every other device pulls the older store down. Nothing
/// says anything. The view outlives the process in `cloud-cache/`, so the file
/// goes with the restore — a missing cache means a cold pull, which is always
/// correct and merely dearer.
@MainActor
enum Restore {

    /// Why a restore did not happen. Every one of these leaves the book alone.
    enum Refusal: Error, CustomStringConvertible {
        case notOurs(String)
        case noSuchBackup(String)
        case unreadable(String)
        case notAKhaytStore(String)
        case damaged(String, [String])
        case couldNotProtectTheBook(String)

        var description: String {
            switch self {
            case .notOurs(let who):
                return "\(who). Nothing was changed — only the app that owns the book may replace it."
            case .noSuchBackup(let name):
                return "There is no backup called \(name)."
            case .unreadable(let why):
                return "That backup could not be read: \(why). The book was not touched."
            case .notAKhaytStore(let name):
                return "\(name) is not a Khayt backup. The book was not touched."
            case .damaged(let name, let errors):
                return "\(name) is damaged — \(errors.joined(separator: "; ")). The book was not touched."
            case .couldNotProtectTheBook(let why):
                return "Could not copy the current book before replacing it: \(why). "
                     + "Nothing was restored, because a restore you cannot undo is not one."
            }
        }
    }

    /// One backup, as a shop chooses between them.
    struct Candidate: Identifiable, Hashable, Sendable {
        var id: String { filename }
        let filename: String
        /// When the file was written, which is what a shop actually recognises
        /// — the name is the day the book was FOR, and a pre-update copy's name
        /// is a version number.
        let written: Date
        let bytes: Int
        /// Taken before an app update or a schema change rather than by the
        /// clock. Worth saying: it is the copy from just before something
        /// changed, which is usually the one a shop is looking for.
        var isInsurance: Bool { insurance != nil }
        /// WHY it was taken, when it was not taken by the clock — the
        /// protected prefixes of `lib/upgrade-backup.js isProtectedBackup`.
        let insurance: Insurance?
    }

    enum Insurance: Hashable, Sendable {
        /// `pre-update-` / `pre-upgrade-`: before an app update.
        case update
        /// `pre-wipe-`: before the other app's "reset everything" (Sep 2026).
        case wipe

        static func of(_ filename: String) -> Insurance? {
            if filename.hasPrefix("pre-wipe-") { return .wipe }
            if filename.hasPrefix("pre-update-") || filename.hasPrefix("pre-upgrade-") { return .update }
            return nil
        }
    }

    /// The file a name refers to, inside the backups folder and nowhere else.
    ///
    /// `lastPathComponent` and not the string given: a filename is the only
    /// thing a restore takes, and one carrying `../` names a file outside the
    /// folder. Khayt's own handler does the same with `path.basename`.
    static func backupURL(named filename: String, in directory: URL) -> URL {
        directory.appending(path: URL(fileURLWithPath: filename).lastPathComponent)
    }

    /// Every backup on the shelf, newest first.
    static func list(in directory: URL) -> [Candidate] {
        let fm = FileManager.default
        return Backups.all(in: directory).compactMap { name -> Candidate? in
            let url = directory.appending(path: name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            // An empty file is not a choice worth offering; it is a failed write.
            guard size > 0 else { return nil }
            return Candidate(filename: name,
                             written: (attrs[.modificationDate] as? Date) ?? .distantPast,
                             bytes: size,
                             insurance: Insurance.of(name))
        }.sorted { $0.written > $1.written }
    }

    /// Put a backup back, or refuse and leave the book exactly as it is.
    ///
    /// Returns the safety copy taken of the book being replaced, when there was
    /// a book to copy.
    @discardableResult
    static func restore(_ filename: String, for build: StoreReader.Build,
                        engine: KhaytEngine?, now: Date = Date()) async throws -> URL? {
        let directory = Backups.directory(for: build)
        let source = backupURL(named: filename, in: directory)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw Refusal.noSuchBackup(source.lastPathComponent)
        }
        return try await restore(backup: source, for: build, engine: engine, now: now)
    }

    /// Put back a backup that is not on the shelf — one brought down from
    /// off-site storage and decrypted into a temporary file. The same checks,
    /// the same safety copy, the same carrying forward: there is one restore.
    @discardableResult
    static func restore(backup source: URL, for build: StoreReader.Build,
                        engine: KhaytEngine?, now: Date = Date()) async throws -> URL? {
        try await restore(backup: source, storeURL: build.storeURL,
                                 owns: { StoreLock.weOwnIt(build) },
                                 whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
                                 protect: {
                                     // Never the backup being restored: it is the oldest one
                                     // more often than not, and rotation used to delete it.
                                     _ = try await Backups.writeNow(for: build, engine: engine, now: now,
                                                                    except: [source.lastPathComponent])
                                 },
                                 forgetCloudView: { forgetCloudView(for: build) },
                                 engine: engine)
    }

    /// The same, addressed by path — the seam the tests use, so that no test of
    /// this ever runs against a shop's live book.
    @discardableResult
    static func restore(backup source: URL, storeURL: URL,
                        owns: () -> Bool, whoHasIt: () -> String?,
                        protect: () async throws -> Void,
                        forgetCloudView: () -> Void,
                        engine: KhaytEngine?) async throws -> URL? {
        guard owns() else { throw Refusal.notOurs(whoHasIt() ?? "Another app owns this book") }

        let name = source.lastPathComponent
        let data: Data
        do { data = try Data(contentsOf: source) } catch {
            throw Refusal.unreadable(error.localizedDescription)
        }
        guard var snapshot = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw Refusal.unreadable("\(name) is not JSON")
        }

        // ASKED OF THE SHARED MODULE, not answered here. See the note above.
        if let engine {
            let verdict = try await engine.storeIsRestorable(snapshot)
            guard verdict.ours else { throw Refusal.notAKhaytStore(name) }
            guard verdict.ok else { throw Refusal.damaged(name, verdict.errors) }
        } else {
            // No engine is not permission to skip the check — it is a reason to
            // refuse. A restore is the one thing in this app that cannot be
            // done on a best-effort basis.
            throw Refusal.unreadable("the shared validator is not loaded")
        }

        // The book as it stands, for the fields a backup does not carry. Read
        // here rather than passed in, and read INSIDE the restore, for the same
        // reason every other write in this app does it.
        let current = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }

        if let current {
            // Copy the book before replacing it. If that fails, stop: a restore
            // that cannot be undone is a second way to lose a shop's data.
            do { try await protect() }
            catch { throw Refusal.couldNotProtectTheBook(String(describing: error)) }
            snapshot = carryForward(into: snapshot, from: current, paths: try await engine?.secretPaths() ?? [])
        }
        // WHAT RUNS ON THIS MAC STAYS THIS MAC'S. A backup's slicer settings
        // are a program and its arguments, and a restored book choosing them
        // could run any command through a genuine slicer. Kept from the book
        // here — or dropped when this Mac has none. The shop's decision, Sep
        // 24 2026. Refused outright if the rule cannot run: a restore that
        // might carry another computer's slicer is not one to make quietly.
        if let engine {
            snapshot = try await engine.keepMachineLocal(local: current ?? [:], incoming: snapshot)
        }

        let next = try JSONEncoder().encode(snapshot)
        guard next.count <= StoreWriter.maxStoreBytes else {
            throw StoreWriter.Refusal.tooLarge(next.count)
        }
        // Asked again, as late as it can be — the validation and the safety copy
        // both took time, and Electron takes the book on startup whatever it finds.
        guard owns() else { throw Refusal.notOurs(whoHasIt() ?? "Another app took the book") }
        try StoreWriter.atomicWrite(next, to: storeURL)

        forgetCloudView()
        return current == nil ? nil : storeURL
    }

    // MARK: - What a backup does not carry

    /// Keys the main process owns and the renderer never sees, so an Electron
    /// backup — built from the renderer's export payload — does not contain
    /// them. `MAIN_OWNED_KEYS` in lib/store-io.js, pinned by
    /// test/mac-core-is-not-a-fork.test.js.
    static let mainOwnedKeys = ["printerCompletions"]

    /// The mask the renderer holds in place of every credential.
    /// `STORE_SECRET_MASK` in lib/store-io.js, pinned by the same test.
    static let secretMask = "__KHAYT_MASKED__"

    /// Fill in what the backup could not have: main-owned keys, and every
    /// credential that reaches a backup as a mask.
    ///
    /// This is `mergeStoreSecretsFromDisk` for a restore. It takes nothing the
    /// backup genuinely has — a Mac-written backup is a byte copy of the store
    /// and carries its own `__enc__` secrets, and those are the ones restored.
    static func carryForward(into snapshot: [String: JSONValue],
                             from current: [String: JSONValue],
                             paths: [String]) -> [String: JSONValue] {
        var out = snapshot
        for key in mainOwnedKeys where out[key] == nil {
            if let held = current[key] { out[key] = held }
        }
        for path in paths {
            if let split = path.range(of: "[].") {
                // The only array with credentials in it is `machines`, and its
                // elements are matched BY ID. By index would hand one printer's
                // access code to another the moment a machine was added or the
                // list reordered — which is worse than losing it.
                let collection = String(path[path.startIndex..<split.lowerBound])
                let field = String(path[split.upperBound...]).split(separator: ".").map(String.init)
                out = carryForwardInCollection(collection, field: field, into: out, from: current)
            } else {
                let keys = path.split(separator: ".").map(String.init)
                if isEmptyOrMasked(value(at: keys, in: out)), let held = value(at: keys, in: current) {
                    out = setting(keys, to: held, in: out)
                }
            }
        }
        return out
    }

    private static func carryForwardInCollection(_ collection: String, field: [String],
                                                 into out: [String: JSONValue],
                                                 from current: [String: JSONValue]) -> [String: JSONValue] {
        guard case .array(let incoming)? = out[collection],
              case .array(let held)? = current[collection] else { return out }
        var byId: [String: [String: JSONValue]] = [:]
        for row in held {
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { continue }
            byId[id] = o
        }
        var rows = incoming
        for i in rows.indices {
            guard case .object(let row) = rows[i], case .string(let id)? = row["id"],
                  let mine = byId[id] else { continue }
            guard isEmptyOrMasked(value(at: field, in: row)),
                  let heldValue = value(at: field, in: mine) else { continue }
            rows[i] = .object(setting(field, to: heldValue, in: row))
        }
        var next = out
        next[collection] = .array(rows)
        return next
    }

    /// A value that is absent, empty, or the renderer's mask — the three things
    /// that mean "the backup does not really have this".
    static func isEmptyOrMasked(_ value: JSONValue?) -> Bool {
        switch value {
        case .none, .null: return true
        case .string(let s): return s.isEmpty || s == secretMask
        default: return false
        }
    }

    static func value(at keys: [String], in object: [String: JSONValue]) -> JSONValue? {
        var cursor: JSONValue = .object(object)
        for key in keys {
            guard case .object(let o) = cursor, let next = o[key] else { return nil }
            cursor = next
        }
        return cursor
    }

    /// Write a value at a dotted path, creating the objects on the way.
    ///
    /// Only ever called when the CURRENT book has a value there, so a store
    /// with no `settings.bnpl` never grows one just because it was walked.
    static func setting(_ keys: [String], to value: JSONValue,
                        in object: [String: JSONValue]) -> [String: JSONValue] {
        guard let head = keys.first else { return object }
        var out = object
        if keys.count == 1 {
            out[head] = value
            return out
        }
        var child: [String: JSONValue] = [:]
        if case .object(let existing)? = out[head] { child = existing }
        out[head] = .object(setting(Array(keys.dropFirst()), to: value, in: child))
        return out
    }

    // MARK: - The cloud

    /// Delete the retained server view, so the next sync is a cold pull.
    ///
    /// `forgetServerView()` is Electron's version of this and runs in a process
    /// that is not going to be the one restoring. What outlives the process is
    /// the file, and without it the backend starts with no view, rev 0 and no
    /// pushed revs — which is exactly the state `forgetServerView` engineers,
    /// and which makes the next push a blob the server refuses with a 409:
    /// pull, merge, re-push, and the merge keeps the higher rev.
    static func forgetCloudView(for build: StoreReader.Build) {
        forgetCloudViewFiles(in: build.storeURL.deletingLastPathComponent().appending(path: "cloud-cache"))
    }

    /// The same, by path. Only `cloud-view-*.json` goes: the folder is the
    /// app's cache directory and nothing else in it is this restore's to delete.
    static func forgetCloudViewFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("cloud-view-") && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
