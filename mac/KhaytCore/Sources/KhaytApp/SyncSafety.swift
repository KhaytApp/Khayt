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
        /// `collection:id` of every record the restore put in the book.
        var records: [String]
    }

    static func pending(for storeURL: URL) -> Pending? {
        guard let data = try? Data(contentsOf: pendingURL(for: storeURL)) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    static func markPending(_ keys: Set<String>, for storeURL: URL, now: Date = Date()) throws {
        let p = Pending(at: StoreWriter.iso(now), records: keys.sorted())
        try JSONEncoder().encode(p).write(to: pendingURL(for: storeURL), options: .atomic)
    }

    static func clear(for storeURL: URL) {
        try? FileManager.default.removeItem(at: pendingURL(for: storeURL))
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
    static func prevail(_ book: [String: JSONValue], over other: [String: JSONValue],
                        restored: Set<String>, now: Date = Date()) -> [String: JSONValue] {
        var out = book
        let present = BookRecords.keys(out)
        // Tombstoned over there, restored here.
        var dead: [JSONValue] = []
        for key in BookRecords.tombstoneKeys(other) where restored.contains(key) && present.contains(key) {
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
                o["rev"] = .number(their + 1)
                o["updatedAt"] = .string(at)
                rows[i] = .object(o)
                changed = true
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
        try? JSONEncoder().encode(self).write(to: Self.url(for: storeURL), options: .atomic)
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(at: StoreWriter.iso(now), losses: losses)).write(to: url, options: .atomic)
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
