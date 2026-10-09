import Foundation
import KhaytCore

// Two ways cloud sync used to lose a shop's records without a word, and what
// stops each one.
//
// 1. A RESTORE WAS UNDONE BY THE NEXT SYNC. Restoring wrote the backup's bytes
//    and nothing else. The next automatic sync merged the cloud in first, and
//    the shared rule did exactly what it is built to do: a tombstone deletes a
//    record of that id whatever its rev, and a higher rev replaces a lower one.
//    A record deleted after the backup was taken — the reason most people
//    restore — was deleted again within minutes, and every record edited
//    elsewhere since the backup went back to the edit. `RestoreGuard` makes a
//    restored book WIN: a restored record whose id is tombstoned is revived
//    under a new id (the only way a delete-wins rule lets it live), and a
//    restored record the other side holds at the same or a higher rev with
//    different content is stamped above it. Done once against the book being
//    replaced, and again against the cloud's own copy on every sync until one
//    push has carried the restored book up.
//
// 2. AUTOMATIC SYNC REPLACED AND REMOVED RECORDS IN SILENCE. The whole-book
//    path merges the cloud in every quarter of an hour, and its conflicts list
//    only reached a sheet nobody had open. `SyncLosses` keeps a copy of every
//    record a merge takes out of this book or overwrites after it was edited
//    here — in `sync-conflicts/` beside the backups, never synced — and the
//    window says so with a way back. `SyncBaseline` is what lets the shared
//    rule tell "edited here" from "simply older" at all: it reports an
//    overwritten local edit only when it knows the rev this Mac last agreed
//    with the cloud on, and the Mac never told it.

// MARK: - Files that hold customer records

/// The files this app keeps beside the book that carry whole customer records
/// — `sync-conflicts/`, `sync-baseline.json`, `restore-pending.json` — are
/// this user's alone: 0600, in a 0700 folder. Written with the default umask
/// they were 0644, readable by every account on the Mac.
enum PrivateFile {
    static let fileMode: Int = 0o600
    static let folderMode: Int = 0o700

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: fileMode], ofItemAtPath: url.path)
    }

    static func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: folderMode])
        try FileManager.default.setAttributes([.posixPermissions: folderMode], ofItemAtPath: url.path)
    }
}

// MARK: - Records, by key

/// `collection:id` for every record in a book's array collections.
enum BookRecords {
    static func each(_ book: [String: JSONValue],
                     _ body: (_ collection: String, _ id: String, _ record: [String: JSONValue]) -> Void) {
        for (collection, value) in book where collection != "tombstones" {
            guard case .array(let rows) = value else { continue }
            for case .object(let o) in rows {
                if case .string(let id)? = o["id"], !id.isEmpty { body(collection, id, o) }
            }
        }
    }

    static func index(_ book: [String: JSONValue]) -> [String: [String: JSONValue]] {
        var out: [String: [String: JSONValue]] = [:]
        each(book) { c, id, o in out[c + ":" + id] = o }
        return out
    }

    static func keys(_ book: [String: JSONValue]) -> Set<String> {
        var out = Set<String>()
        each(book) { c, id, _ in out.insert(c + ":" + id) }
        return out
    }

    static func rev(_ o: [String: JSONValue]?) -> Double {
        if case .number(let n)? = o?["rev"], n > 0 { return n }
        return 0
    }

    /// Everything but the change metadata — the shared `fingerprint`'s rule.
    static func content(_ o: [String: JSONValue]) -> [String: JSONValue] {
        var c = o
        c.removeValue(forKey: "rev")
        c.removeValue(forKey: "updatedAt")
        return c
    }

    static func tombstoneKeys(_ book: [String: JSONValue]) -> Set<String> {
        var out = Set<String>()
        guard case .array(let tombs)? = book["tombstones"] else { return out }
        for case .object(let t) in tombs {
            if case .string(let c)? = t["collection"], case .string(let i)? = t["id"] { out.insert(c + ":" + i) }
        }
        return out
    }
}

// MARK: - 1. A restore that stays restored

enum RestoreGuard {

    /// The marker a restore leaves until a push has carried the restored book
    /// up. Beside the book, so it belongs to exactly one book.
    static func pendingURL(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: "restore-pending.json")
    }

    struct Pending: Codable, Equatable {
        var at: String
        /// `collection:id` of every record the restore CHANGED — brought back,
        /// or put back as it was — not every record in the book.
        var records: [String]
        /// The cloud's rev of each restored record the first time it was held
        /// against the cloud; nil until then. The hold prevails only over a
        /// cloud copy at or below it, so an edit another device makes AFTER
        /// the restore stands. A record the cloud did not hold then is absent,
        /// and any copy of it that appears later is somebody's new edit.
        var cloudRevs: [String: Double]? = nil
        /// The restored records the cloud had tombstoned at that first hold.
        var cloudTombstones: [String]? = nil
    }

    /// How long a restore is held against the cloud before the ordinary rule
    /// takes over again. A Mac whose pushes keep failing used to hold it — and
    /// override every other device's edits to those records — for ever.
    static let lifetime: TimeInterval = 7 * 86_400

    static func pending(for storeURL: URL) -> Pending? {
        guard let data = try? Data(contentsOf: pendingURL(for: storeURL)) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    /// The marker if it is still live. An expired one is removed, and the
    /// caller is told so it can say so.
    static func take(for storeURL: URL, now: Date = Date()) -> (pending: Pending?, expired: Bool) {
        guard let p = pending(for: storeURL) else { return (nil, false) }
        if let at = markedAt(p.at), now.timeIntervalSince(at) > lifetime {
            clear(for: storeURL)
            return (nil, true)
        }
        return (p, false)
    }

    /// `StoreWriter.iso`'s own format, read back.
    static func markedAt(_ text: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.date(from: text)
    }

    static func markPending(_ keys: Set<String>, for storeURL: URL, now: Date = Date()) throws {
        try save(Pending(at: StoreWriter.iso(now), records: keys.sorted()), for: storeURL)
    }

    static func save(_ pending: Pending, for storeURL: URL) throws {
        try PrivateFile.write(try JSONEncoder().encode(pending), to: pendingURL(for: storeURL))
    }

    static func clear(for storeURL: URL) {
        // lock: system — the sync's own pending marker, cleared once it is carried up.
        try? FileManager.default.removeItem(at: pendingURL(for: storeURL))
    }

    /// After a pull: a role that can never push (a viewer) can never carry the
    /// restore up, so its marker would hold for ever. One pull has made it win
    /// once; from here the ordinary rule applies. True when it was cleared.
    @discardableResult
    static func afterPull(canWrite: Bool, storeURL: URL) -> Bool {
        guard !canWrite, pending(for: storeURL) != nil else { return false }
        clear(for: storeURL)
        return true
    }

    /// The records a restore CHANGED: in the restored book and absent from the
    /// one it replaced, or there with different content. A record the two
    /// books agree on was not restored — marking it made this Mac override
    /// every other device's later edit to it.
    static func changedKeys(restored: [String: JSONValue],
                            replaced: [String: JSONValue]?) -> Set<String> {
        guard let replaced else { return BookRecords.keys(restored) }
        let theirs = BookRecords.index(replaced)
        var out = Set<String>()
        BookRecords.each(restored) { c, id, o in
            let key = c + ":" + id
            if let them = theirs[key], BookRecords.content(them) == BookRecords.content(o) { return }
            out.insert(key)
        }
        return out
    }

    /// The cloud's view of the restored records at the first hold.
    struct Ceiling: Equatable {
        var revs: [String: Double]
        var tombstones: Set<String>
    }

    /// Hold a pending restore against the CLOUD's copy: the first time, note
    /// what the cloud holds of each restored record (`cloudRevs`); every time,
    /// prevail only over cloud copies at or below that. Returns the book and a
    /// copy of every cloud record it overrode — kept in `sync-conflicts/` by
    /// the caller like everything else sync takes, which it never was.
    static func hold(_ book: [String: JSONValue], over cloud: [String: JSONValue],
                     pending: inout Pending, now: Date = Date())
    -> (book: [String: JSONValue], overridden: [SyncLoss]) {
        let restored = Set(pending.records)
        if pending.cloudRevs == nil {
            var revs: [String: Double] = [:]
            BookRecords.each(cloud) { c, id, o in
                let key = c + ":" + id
                if restored.contains(key) { revs[key] = BookRecords.rev(o) }
            }
            pending.cloudRevs = revs
            pending.cloudTombstones = BookRecords.tombstoneKeys(cloud).intersection(restored).sorted()
        }
        let ceiling = Ceiling(revs: pending.cloudRevs ?? [:],
                              tombstones: Set(pending.cloudTombstones ?? []))
        var overridden: [SyncLoss] = []
        let out = prevail(book, over: cloud, restored: restored, ceiling: ceiling, now: now,
                          overrode: { c, id, theirs, mine in
            overridden.append(SyncLoss(kind: .replaced, collection: c, recordId: id,
                                       record: .object(theirs), replacedBy: .object(mine)))
        })
        return (out, overridden)
    }

    /// Make the restored records in `book` win over `other` — the book being
    /// replaced, or the cloud's copy.
    ///
    /// * A restored record whose id `other` has tombstoned is revived under a
    ///   NEW id, with every reference to it relinked — `reviveUnderNewIds`, the
    ///   same rule Undo after a delete uses, for the same reason: a tombstone
    ///   wins on every device whatever the rev, so the old id can never live
    ///   again.
    /// * A restored record that `other` holds at the same or a higher rev with
    ///   different content is stamped one above it, so the higher-rev rule
    ///   keeps the restored copy here and sends it everywhere else.
    ///
    /// Records the restore did not bring are left alone, and so is a restored
    /// record `other` already agrees with — stamping that would push a change
    /// nobody made.
    ///
    /// `ceiling`, against the cloud: only a tombstone and a copy the cloud
    /// already held at the first hold are prevailed over (`hold`).
    /// `overrode` hears of every record of `other`'s that was stamped over.
    static func prevail(_ book: [String: JSONValue], over other: [String: JSONValue],
                        restored: Set<String>, ceiling: Ceiling? = nil, now: Date = Date(),
                        overrode: ((_ collection: String, _ id: String,
                                    _ theirs: [String: JSONValue], _ mine: [String: JSONValue]) -> Void)? = nil)
    -> [String: JSONValue] {
        var out = book
        let present = BookRecords.keys(out)
        // Tombstoned over there, restored here.
        var dead: [JSONValue] = []
        for key in BookRecords.tombstoneKeys(other) where restored.contains(key) && present.contains(key) {
            if let ceiling, !ceiling.tombstones.contains(key) { continue }
            guard let split = key.firstIndex(of: ":") else { continue }
            dead.append(.object(["collection": .string(String(key[..<split])),
                                 "id": .string(String(key[key.index(after: split)...]))]))
        }
        if !dead.isEmpty {
            StoreWriter.reviveUnderNewIds(before: ["tombstones": .array(dead)], after: &out)
        }
        // Older or equal over there, and different.
        let theirs = BookRecords.index(other)
        let at = StoreWriter.iso(now)
        for (collection, value) in out where collection != "tombstones" {
            guard case .array(var rows) = value else { continue }
            var changed = false
            for i in rows.indices {
                guard case .object(var o) = rows[i], case .string(let id)? = o["id"] else { continue }
                let key = collection + ":" + id
                guard restored.contains(key), let them = theirs[key] else { continue }
                let mine = BookRecords.rev(o), their = BookRecords.rev(them)
                guard their >= mine, BookRecords.content(them) != BookRecords.content(o) else { continue }
                // Edited over there AFTER the restore was first held: theirs
                // is a new edit, not the stale copy the restore is replacing.
                if let ceiling, their > (ceiling.revs[key] ?? 0) { continue }
                o["rev"] = .number(their + 1)
                o["updatedAt"] = .string(at)
                rows[i] = .object(o)
                changed = true
                overrode?(collection, id, them, o)
            }
            if changed { out[collection] = .array(rows) }
        }
        return out
    }

    /// The replaced book's deletes, carried into the restored one. A delete
    /// the restored book does not know about is one another device will hand
    /// straight back to it; the restored records it names have already been
    /// moved to new ids by `prevail`, so none of them is touched.
    static func carryTombstones(into book: [String: JSONValue],
                                from current: [String: JSONValue]) -> [String: JSONValue] {
        guard case .array(let theirs)? = current["tombstones"], !theirs.isEmpty else { return book }
        var out = book
        var tombs: [JSONValue] = []
        if case .array(let held)? = out["tombstones"] { tombs = held }
        var known = BookRecords.tombstoneKeys(out)
        let present = BookRecords.keys(out)
        for case .object(let t) in theirs {
            guard case .string(let c)? = t["collection"], case .string(let i)? = t["id"] else { continue }
            let key = c + ":" + i
            guard !known.contains(key), !present.contains(key) else { continue }
            tombs.append(.object(t))
            known.insert(key)
        }
        if tombs.count > StoreWriter.tombstoneCap { tombs.removeFirst(tombs.count - StoreWriter.tombstoneCap) }
        out["tombstones"] = .array(tombs)
        return out
    }
}

// MARK: - 2a. What this Mac last agreed with the cloud on

/// The rev at which this Mac and the cloud last held the same copy of each
/// record — `syncedRev` in lib/sync.js, kept on disk because the engine keeps
/// it only for the life of the process, and the first merge after a launch is
/// as likely as any to overwrite something.
struct SyncBaseline: Codable, Equatable {
    var shopId: String
    var revs: [String: Double]

    static func url(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: "sync-baseline.json")
    }

    static func load(for storeURL: URL, shopId: String) -> SyncBaseline {
        guard let data = try? Data(contentsOf: url(for: storeURL)),
              let b = try? JSONDecoder().decode(SyncBaseline.self, from: data),
              b.shopId == shopId else { return SyncBaseline(shopId: shopId, revs: [:]) }
        return b
    }

    func save(for storeURL: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? PrivateFile.write(data, to: Self.url(for: storeURL))
    }

    /// After an exchange: every record this book and the cloud now hold at
    /// the same rev is agreed at that rev. A record that has left the book is
    /// forgotten, so the file never outgrows the book.
    func agreeing(book: [String: JSONValue], cloud: [String: JSONValue]) -> SyncBaseline {
        let theirs = BookRecords.index(cloud)
        var next: [String: Double] = [:]
        BookRecords.each(book) { c, id, o in
            let key = c + ":" + id
            let rev = BookRecords.rev(o)
            if let them = theirs[key], BookRecords.rev(them) == rev {
                next[key] = rev
            } else if let was = revs[key] {
                next[key] = was
            }
        }
        return SyncBaseline(shopId: shopId, revs: next)
    }
}

// MARK: - 2b. What a merge took, kept

struct SyncLoss: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Deleted on another device and taken out of this book.
        case removed
        /// Changed here, and overwritten by another device's copy.
        case replaced
        /// Deleted here; another device's later edit to it was dropped.
        case keptDeleted
    }
    let kind: Kind
    let collection: String
    let recordId: String
    /// The copy that is gone.
    let record: JSONValue
    /// What took its place, for `.replaced`.
    let replacedBy: JSONValue?

    var id: String { kind.rawValue + ":" + collection + ":" + recordId }

    /// What a person would call it.
    var title: String {
        guard case .object(let o) = record else { return recordId }
        for field in ["project", "name", "nameEn", "nameAr", "title", "label", "item", "brand"] {
            if case .string(let s)? = o[field], !s.isEmpty { return s }
        }
        return recordId
    }
}

enum SyncLosses {

    static func directory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: "sync-conflicts")
    }

    struct File: Codable, Equatable {
        var at: String
        var losses: [SyncLoss]
    }

    /// What `merged` took from `before`: every record it removed, every one it
    /// overwrote after it was edited here, and every edit from elsewhere that
    /// a delete made here kept out.
    static func compute(before: [String: JSONValue], after: [String: JSONValue],
                        conflicts: [JSONValue]) -> [SyncLoss] {
        let afterKeys = BookRecords.keys(after)
        let was = BookRecords.index(before)
        let now = BookRecords.index(after)
        var out: [SyncLoss] = []
        var seen = Set<String>()

        BookRecords.each(before) { c, id, o in
            let key = c + ":" + id
            guard !afterKeys.contains(key) else { return }
            out.append(SyncLoss(kind: .removed, collection: c, recordId: id,
                                record: .object(o), replacedBy: nil))
            seen.insert(key)
        }
        for case .object(let conflict) in conflicts {
            guard case .string(let c)? = conflict["collection"], case .string(let id)? = conflict["id"] else { continue }
            let key = c + ":" + id
            guard !seen.contains(key) else { continue }
            let kind: String? = { if case .string(let k)? = conflict["kind"] { return k } else { return nil } }()
            let took: Bool = { if case .bool(let b)? = conflict["tookIncoming"] { return b } else { return false } }()
            if kind == "delete_over_edit" {
                // Deleted here, and the incoming edit skipped. (The other way
                // round — deleted there — is a removal, already kept above.)
                guard was[key] == nil, let discarded = conflict["discarded"] else { continue }
                out.append(SyncLoss(kind: .keptDeleted, collection: c, recordId: id,
                                    record: discarded, replacedBy: nil))
                seen.insert(key)
            } else if kind == "remote_over_local_edit" || (kind == nil && took) {
                // `remote_over_local_edit` carries the local copy; an equal-rev
                // tie that took the incoming one does not, so it is read from
                // the book as it was.
                let mine: JSONValue? = kind == nil ? was[key].map(JSONValue.object) : conflict["discarded"]
                guard let mine else { continue }
                out.append(SyncLoss(kind: .replaced, collection: c, recordId: id,
                                    record: mine, replacedBy: now[key].map(JSONValue.object)))
                seen.insert(key)
            }
        }
        return out
    }

    /// The file for one merge. Named once, before the merge, so a merge the
    /// write chain has to work out again rewrites the same file.
    static func fileURL(for storeURL: URL, at date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        return directory(for: storeURL).appending(path: "sync-\(f.string(from: date)).json")
    }

    /// Write the copies, BEFORE the merged book replaces the one they came
    /// from. Throws: a merge that cannot keep what it is about to take does
    /// not go ahead.
    static func keep(_ losses: [SyncLoss], at url: URL, now: Date = Date()) throws {
        guard !losses.isEmpty else { return }
        let folder = url.deletingLastPathComponent()
        try PrivateFile.makeFolder(folder)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // WHOLE CUSTOMER RECORDS: this user's only.
        try PrivateFile.write(try enc.encode(File(at: StoreWriter.iso(now), losses: losses)), to: url)
        prune(folder: folder, now: now, keep: url)
    }

    /// How long a kept copy stays, and how many are kept at most. Every merge
    /// that takes something writes a file, and automatic sync merges every
    /// quarter of an hour: unpruned, the folder only ever grew.
    static let keepDays: Double = 60
    static let keepFiles = 200

    /// Drop kept copies older than `keepDays`, then the oldest beyond
    /// `keepFiles`. `keep` is never dropped — it was just written.
    static func prune(for storeURL: URL, now: Date = Date()) {
        prune(folder: directory(for: storeURL), now: now, keep: nil)
    }

    private static func prune(folder: URL, now: Date, keep: URL?) {
        // lock: system — ages out the sync's own safety copies on a fixed rule.
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        let files: [(URL, Date)] = names.filter { $0.pathExtension == "json" }.map { url in
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            return (url, at)
        }.sorted { $0.1 > $1.1 }
        let oldest = now.addingTimeInterval(-keepDays * 86_400)
        var kept = 0
        for (url, at) in files {
            let isNew = keep.map { $0.standardizedFileURL == url.standardizedFileURL } ?? false
            if !isNew && (at < oldest || kept >= keepFiles) {
                try? fm.removeItem(at: url)
                continue
            }
            kept += 1
        }
    }

    static func read(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    /// Put one back. A removed record comes back under a new id when its old
    /// one is tombstoned (`StoreWriter.update` revives it); a replaced one
    /// replaces what took its place, moving its rev FORWARD so the next sync
    /// keeps it rather than undoing the undo.
    static func putBack(_ loss: SyncLoss, into root: inout [String: JSONValue]) {
        guard case .object(let wanted) = loss.record else { return }
        var rows: [JSONValue] = []
        if case .array(let held)? = root[loss.collection] { rows = held }
        if let i = rows.firstIndex(where: {
            if case .object(let o) = $0, o["id"] == .string(loss.recordId) { return true }
            return false
        }), case .object(let current) = rows[i] {
            rows[i] = .object(StoreWriter.restoring(wanted, over: current))
        } else {
            rows.append(.object(wanted))
        }
        root[loss.collection] = .array(rows)
    }
}

/// What the window says about the last merges that took something.
struct SyncLossNotice: Equatable {
    var files: [URL]
    var losses: [SyncLoss]
    var replaced: Int { losses.filter { $0.kind == .replaced }.count }
    var removed: Int { losses.filter { $0.kind == .removed }.count }
    var keptDeleted: Int { losses.filter { $0.kind == .keptDeleted }.count }

    func adding(_ more: [SyncLoss], file: URL) -> SyncLossNotice {
        SyncLossNotice(files: files + [file], losses: losses + more)
    }
}
