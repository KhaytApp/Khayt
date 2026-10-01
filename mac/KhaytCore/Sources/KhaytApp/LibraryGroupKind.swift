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
    /// touched entry keeps any field beside `kind`.
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

    /// A folder moved from `path` to `destination`: its entry and every entry
    /// beneath it are carried to the new paths, whole.
    ///
    /// COPIED, NOT MOVED. Undoing the move puts the files back under the old
    /// paths, and settings are not part of the file undo — so the old entries
    /// stay, and an undone move finds its kinds where it left them. A path no
    /// file sits under is never read. Where the destination already has an
    /// entry, it is kept: moving a folder INTO an existing group does not
    /// change what that group is.
    static func carry(from path: String, to destination: String, in root: inout [String: JSONValue]) {
        guard path != destination else { return }
        let settings = Shop.settings(root)
        let stored = settings[settingsKey]
        guard case .object(var map)? = stored else { return }
        var changed = false
        for (key, entry) in map where Shop.isUnder(key, path) {
            let moved = destination + key.dropFirst(path.count)
            guard map[moved] == nil else { continue }
            map[moved] = entry
            changed = true
        }
        guard changed else { return }
        write(map: map, stored: stored, settings: settings, into: &root)
    }

    private static func write(map: [String: JSONValue], stored: JSONValue?,
                              settings: [String: JSONValue], into root: inout [String: JSONValue]) {
        let written: [String: JSONValue] = [settingsKey: .object(map)]
        let opened: [String: JSONValue]? = stored.map { [settingsKey: $0] }
        root["settings"] = .object(Shop.settingsKeys(written, opened: opened, over: settings))
    }
}
