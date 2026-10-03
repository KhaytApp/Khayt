import Foundation
import KhaytCore

/// What a group IS: one print in parts, or separate prints kept together.
///
/// ── TWO THINGS SHARED ONE WORD ───────────────────────────────────────────
///
/// A shop's groups are of two kinds, and the library drew them the same:
///
/// - **Parts.** Several files that together make ONE print — Baby Grendizer
///   in eight pieces, a Luffy card with its stand, a pose with a sub-folder
///   per colour. To the shop this is one model; its files are its parts.
/// - **Collection.** Similar but independent prints kept together — the seven
///   Saudi Kings. Each is a model in its own right.
///
/// "All models" therefore shows a parts group as ONE tile and a collection's
/// members as model tiles (`LibraryEntry.allModels`). The Groups view is
/// unchanged: every group is a tile there.
///
/// ── WHERE IT IS KEPT ─────────────────────────────────────────────────────
///
/// A group has no record — each file carries its group as a PATH — so the
/// kind lives in settings, keyed by that path:
///
///     settings.libraryGroups = { "Luffy Card": { "kind": "parts" } }
///
/// Its own top-level key rather than inside `settings.printLibrary`, which
/// is per-machine LOCATION configuration (roots, the S3 and Drive secrets
/// the store masks and seals) that the other app's library pane writes as a
/// whole. Settings sync, and `lib/settings-edit.js` keeps a key it does not
/// know ("start from what is already there"), so the other app carries it
/// untouched. An entry is an object, not a bare string, so a later field
/// (a cover, a sort) can sit beside `kind` without a second key.
enum GroupKind: String, CaseIterable, Sendable {
    case parts
    case collection

    /// THE ONE DEFAULT. A group with no entry — every group made before this
    /// existed — is parts: this shop's groups are all multi-part projects,
    /// and showing a project as one tile is the safe reading (it is one
    /// click from its files; a collection wrongly collapsed is too).
    static let assumed: GroupKind = .parts

    /// How the choice is named where the shop makes it.
    var wordKey: String {
        switch self {
        case .parts: "mac.group_kind_parts"
        case .collection: "mac.group_kind_collection"
        }
    }

    /// Its mark: a puzzle piece for a print in parts, a stack for a set.
    var symbol: String {
        switch self {
        case .parts: "puzzlepiece.fill"
        case .collection: "square.stack.fill"
        }
    }
}

@MainActor
enum GroupKinds {
    nonisolated static let settingsKey = "libraryGroups"

    /// The kinds a book's settings hold, by group path. A malformed entry is
    /// skipped (and so reads as the default), never fatal.
    nonisolated static func read(_ settings: [String: JSONValue]) -> [String: GroupKind] {
        guard case .object(let map)? = settings[settingsKey] else { return [:] }
        var out: [String: GroupKind] = [:]
        for (path, entry) in map {
            guard case .object(let fields) = entry, case .string(let raw)? = fields["kind"],
                  let kind = GroupKind(rawValue: raw) else { continue }
            out[path] = kind
        }
        return out
    }

    nonisolated static func kind(of path: String, in kinds: [String: GroupKind]) -> GroupKind {
        kinds[path] ?? GroupKind.assumed
    }

    /// Set some groups' kinds in a book's settings.
    ///
    /// Through `Shop.settingsKeys`, the same round-trip write the slicer list
    /// uses (#1676): the map as the book holds it is the baseline, so every
    /// entry this did not touch goes back exactly as it was spelled, and a
    /// touched entry keeps any field beside `kind`. Entries for groups no file
    /// sits under any more are pruned in the same write (`prune`).
    static func write(_ changes: [String: GroupKind], into root: inout [String: JSONValue]) {
        guard !changes.isEmpty else { return }
        let settings = Shop.settings(root)
        let stored = settings[settingsKey]
        var map: [String: JSONValue] = [:]
        if case .object(let m)? = stored { map = m }
        for (path, kind) in changes where !path.isEmpty {
            var entry: [String: JSONValue] = [:]
            if case .object(let e)? = map[path] { entry = e }
            entry["kind"] = .string(kind.rawValue)
            map[path] = .object(entry)
        }
        write(map: map, stored: stored, settings: settings, into: &root)
    }

    /// A folder moved from `path` to `destination`, taking the files `moving`
    /// with it: the kinds go with the files.
    ///
    /// MOVED, NOT COPIED. Every entry at or beneath `path` leaves it — no file
    /// sits there any more — and arrives at the matching path beneath
    /// `destination`. A copy left the old entry behind, and moving the folder
    /// BACK found that stale entry and kept it over the kind the shop had set
    /// since. Undo still finds the old kinds: `Shop.editFiles` records what
    /// this changed in the map and `Shop.restore` puts it back with the files.
    ///
    /// A destination path that already held files OTHER than the moving ones
    /// is an existing group and keeps what it is: moving a folder INTO a group
    /// does not change that group. Any other entry there is a leftover — a
    /// group moved away earlier, a deleted group's name — and is overwritten
    /// by the moving folder's kind, or removed when the folder had none, so a
    /// dead group's kind is never inherited.
    ///
    /// Call it AFTER the files are rewritten (it runs as `editFiles`'s
    /// `alsoRoot`): what else sits under the destination is read from the
    /// book as it stands, minus the moving files.
    static func carry(from path: String, to destination: String, moving: Set<String>,
                      in root: inout [String: JSONValue]) {
        carry([(from: path, to: destination)], moving: moving, in: &root)
    }

    /// Several folders moved in ONE write (`Shop.moveGroups`), each taking
    /// its kinds — the rule above, applied to every move before the map is
    /// written once.
    ///
    /// ── WHY NOT `carry` ONCE PER MOVE ─────────────────────────────────────
    ///
    /// Every write of the map prunes it (`prune`), and by the time the kinds
    /// are carried every moving file has already been rewritten. Carrying the
    /// first folder therefore pruned the SECOND folder's entries — no file
    /// sat under its old path any more — and the second group arrived with
    /// no kind. One pass over the map as the book held it, one write.
    ///
    /// `moving` is every file the batch moves. The moves' sources must not
    /// nest and their destinations must differ (`Shop.planGroupMove` makes
    /// sure), so no move reaches into another's subtree.
    static func carry(_ moves: [(from: String, to: String)], moving: Set<String>,
                      in root: inout [String: JSONValue]) {
        let moves = moves.filter { $0.from != $0.to }
        guard !moves.isEmpty else { return }
        let settings = Shop.settings(root)
        let stored = settings[settingsKey]
        guard case .object(let original)? = stored else { return }
        let staying = groupPaths(root, except: moving)
        var map = original
        for (path, destination) in moves {
            // The source subtree empties.
            for key in original.keys where Shop.isUnder(key, path) { map[key] = nil }
            // The destination subtree: every path an entry moves to, and every
            // entry already there.
            var targets = Set(original.keys.filter { Shop.isUnder($0, destination) })
            for key in original.keys where Shop.isUnder(key, path) {
                targets.insert(destination + key.dropFirst(path.count))
            }
            for target in targets {
                if staying.contains(where: { Shop.isUnder($0, target) }) {
                    map[target] = original[target]
                } else {
                    map[target] = original[path + target.dropFirst(destination.count)]
                }
            }
        }
        write(map: map, stored: stored, settings: settings, into: &root)
    }

    /// The map as a book holds it, entry by entry — what `Shop.editFiles`
    /// compares before and after a write, so its undo can put kinds back.
    nonisolated static func entries(_ root: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(let settings)? = root["settings"],
              case .object(let map)? = settings[settingsKey] else { return [:] }
        return map
    }

    /// Put some entries back as they were (nil: the entry was not there), for
    /// an undo. Round-trip like every other write, and pruned like one.
    static func restore(_ entries: [String: JSONValue?], into root: inout [String: JSONValue]) {
        guard !entries.isEmpty else { return }
        let settings = Shop.settings(root)
        let stored = settings[settingsKey]
        var map: [String: JSONValue] = [:]
        if case .object(let m)? = stored { map = m }
        for (path, entry) in entries { map[path] = entry }
        write(map: map, stored: stored, settings: settings, into: &root)
    }

    /// Every group path a live file sits in, read from the book's records the
    /// way `LibraryFile.groupName` reads them (`folder` wins when present).
    nonisolated static func groupPaths(_ root: [String: JSONValue],
                                       except skipped: Set<String> = []) -> [String] {
        guard case .array(let rows)? = root["printFiles"] else { return [] }
        var out: [String] = []
        for row in rows {
            guard case .object(let record) = row else { continue }
            if case .string(let id)? = record["id"], skipped.contains(id) { continue }
            let folder: String? = { if case .string(let s)? = record["folder"] { s } else { nil } }()
            let group: String? = { if case .string(let s)? = record["group"] { s } else { nil } }()
            if let name = LibraryFile.groupName(folder: folder, group: group) { out.append(name) }
        }
        return out
    }

    /// The map without entries for paths no file sits under.
    ///
    /// A path's kind is read only while files sit under it, so an entry left
    /// behind is dead weight at best — and at worst the kind a NEW group of
    /// the same name inherits (a deleted "Kings" collection turning the next
    /// "Kings" into one). Pruned on every write of the map, never on its own,
    /// so a book this app only reads is never rewritten for it. A book with
    /// no `printFiles` list at all is not pruned: that is a book this cannot
    /// read, not an empty library.
    nonisolated static func prune(_ map: [String: JSONValue],
                                  root: [String: JSONValue]) -> [String: JSONValue] {
        guard case .array? = root["printFiles"] else { return map }
        let live = groupPaths(root)
        return map.filter { key, _ in live.contains { Shop.isUnder($0, key) } }
    }

    private static func write(map: [String: JSONValue], stored: JSONValue?,
                              settings: [String: JSONValue], into root: inout [String: JSONValue]) {
        let kept = prune(map, root: root)
        // Nothing changed: leave the settings exactly as they are — not even
        // an empty map written where the book had none.
        if case .object(let had)? = stored, had == kept { return }
        if stored == nil, kept.isEmpty { return }
        let written: [String: JSONValue] = [settingsKey: .object(kept)]
        let opened: [String: JSONValue]? = stored.map { [settingsKey: $0] }
        root["settings"] = .object(Shop.settingsKeys(written, opened: opened, over: settings))
    }
}
