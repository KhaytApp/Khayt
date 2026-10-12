import Foundation
import KhaytCore

/// A Stop a person can press while the library looks through its folders.
///
/// ── WHY A FLAG AND NOT ONLY `Task.cancel` ─────────────────────────────────
///
/// The shop linked a Google Drive folder of ~10,000 models and reported "no
/// way to stop the online folder scan" (Oct 2026). The scan has more than one
/// way in — the load-time pass, which is a Task this app keeps, and a Rescan
/// button whose Task belongs to a view — and its walk runs on a dispatch queue
/// (`PinWork`), where a cancelled Task is not visible. One flag, held by the
/// shop for as long as a scan runs, reaches all three. The Tasks that ARE
/// kept are cancelled as well, so nothing waits on them for long.
final class ScanStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}

/// Files a cloud drive lists but has not downloaded.
///
/// ── READING ONE IS DOWNLOADING IT ─────────────────────────────────────────
///
/// Google Drive, Dropbox, OneDrive and iCloud Drive on macOS 26 are File
/// Provider folders: every file is listed, most are "dataless" placeholders,
/// and the first read of one makes the provider fetch it. Indexing hashed every
/// file, so a linked Drive of 9,927 models was being DOWNLOADED, one model at a
/// time, to be indexed — 194 in, and the shop's disk filling with a Drive it
/// had asked to leave online. A placeholder's name and size are free; its
/// bytes are not. So a placeholder is indexed from what is free, and its bytes
/// are read when the shop opens it (`Shop.fillNowLocal` then fills the rest).
enum LinkedCloud {

    /// `SF_DATALESS` from `<sys/stat.h>`: "file is dataless object". Spelled
    /// as a number because the Darwin overlay does not export it.
    nonisolated static let datalessFlag: UInt32 = 0x4000_0000

    /// True when reading this file would make a cloud provider download it.
    ///
    /// Two signals, because neither covers every provider: the dataless flag
    /// is set by the kernel on any File Provider placeholder (Drive's "online
    /// only"), and the ubiquitous-item status is how iCloud Drive says the
    /// same. Both are metadata — asking costs no download.
    nonisolated static func isOnlineOnly(_ url: URL) -> Bool {
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_flags & datalessFlag) != 0 { return true }
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true, let status = v.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    /// The size the drive lists for a file, without reading it.
    nonisolated static func listedSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

/// Filing the linked models already in the book again, by their folders.
///
/// ── THE DATA ALREADY ON DISK ──────────────────────────────────────────────
///
/// A better grouping rule fixes the NEXT model indexed. The 194 the shop
/// already had were filed under `Auto_Copied_Shared (1)/…` with their projects
/// trimmed away, and would have stayed there beside the new ones filed
/// properly. So the records are filed again from the path they point at, once
/// per book (`version`), and on demand from Settings.
///
/// ── WHAT IS THE SHOP'S AND IS NOT TOUCHED ─────────────────────────────────
///
/// Nothing in the book marks a group the shop chose by hand. So a record is
/// moved only when its group is still the one the APP gave it: the group the
/// old rule produces for its path (`ImportGrouping.V1`), or the one this app
/// last wrote and remembered in `autoGroup`. A model the shop dragged into a
/// group of its own has neither, and keeps it. Its NAME is changed only on the
/// same terms: when it is still the title the old rule gave it.
enum LinkedRegroup {

    /// Bumped when the rule changes enough that the book should be refiled.
    nonisolated static let version = 2.0

    struct Change: Equatable, Sendable {
        let id: String
        let group: String
        /// A new name, when the record still had the one the old rule gave.
        let name: String?
    }

    /// The name a file gets when its folder does not name it.
    nonisolated static func stem(_ url: URL) -> String {
        url.lastPathComponent.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
    }

    /// The changes one linked folder needs.
    ///
    /// - Parameters:
    ///   - rows: the book's `printFiles`.
    ///   - root: the linked folder.
    ///   - models: every model under it, as the scan's walk found them —
    ///     a folder of one model and a folder of several are judged over all
    ///     of them, indexed or not, exactly as the scan files them.
    nonisolated static func changes(rows: [JSONValue], root: URL, models: [URL]) -> [Change] {
        let old = ImportGrouping.V1.placements(for: models, chosen: root)
        let new = ImportGrouping.placements(for: models, chosen: root, includeChosen: false)
        func key(_ u: URL) -> String { u.standardizedFileURL.path }
        let byPath = Dictionary(models.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Change] = []
        for case .object(let o) in rows {
            guard case .string(let id)? = o["id"], case .string(let path)? = o["externalPath"], !path.isEmpty,
                  LibraryMove.under(path, root.path),
                  let url = byPath[key(URL(fileURLWithPath: path))],
                  let was = old[url], let now = new[url] else { continue }
            func text(_ k: String) -> String? { if case .string(let s)? = o[k] { s } else { nil } }
            let current = LibraryFile.groupName(folder: text("folder"), group: text("group")) ?? ""
            let fromOldRule = LibraryFile.normalise(was.group) == current
            let fromThisApp = text("autoGroup").map { LibraryFile.normalise($0) == current } ?? false
            guard fromOldRule || fromThisApp else { continue }          // the shop's own
            let group = now.group ?? ""
            var name: String?
            let oldName = was.title ?? stem(url), newName = now.title ?? stem(url)
            if text("name") == oldName, newName != oldName { name = newName }
            guard LibraryFile.normalise(group) != current || name != nil else { continue }
            out.append(Change(id: id, group: group, name: name))
        }
        return out
    }

    /// The changes, written onto the book's records. Both group fields, as
    /// every group write does (`moveRecord`), and `autoGroup`, so a later
    /// refile can tell this group from one the shop chooses afterwards.
    ///
    /// ── THE GROUP'S KIND AND PICTURE GO WITH IT ───────────────────────────
    ///
    /// A shop that marked `Auto_Copied_Shared (1)/Mumm-Ra` as one print's
    /// parts, or gave it a picture, set that on the group — an entry in
    /// `settings.libraryGroups` keyed by its path. Refiling moved the records
    /// and left the entry behind on a path no file sat under, and the next
    /// write of the map pruned it: the kind and the picture the shop chose
    /// were gone (alpha.66 review). So when EVERY record of a group goes to
    /// one new group, its entry goes with it — unless the new group already
    /// has one of its own, which is the shop's and stays.
    nonisolated static func apply(_ changes: [Change], to root: inout [String: JSONValue]) {
        let byId = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard case .array(var rows)? = root["printFiles"] else { return }
        // Where each group's records went, read before they move.
        var went: [String: Set<String>] = [:]
        for case .object(let o) in rows {
            guard case .string(let id)? = o["id"], let c = byId[id] else { continue }
            func text(_ k: String) -> String? { if case .string(let s)? = o[k] { s } else { nil } }
            if let from = LibraryFile.groupName(folder: text("folder"), group: text("group")) {
                went[from, default: []].insert(LibraryFile.normalise(c.group))
            }
        }
        for (i, row) in rows.enumerated() {
            guard case .object(var o) = row, case .string(let id)? = o["id"], let c = byId[id] else { continue }
            o["group"] = .string(c.group)
            o["folder"] = .string(c.group)
            o["autoGroup"] = .string(c.group)
            if let name = c.name { o["name"] = .string(name) }
            rows[i] = .object(o)
        }
        root["printFiles"] = .array(rows)
        carryEntries(went, rows: rows, into: &root)
    }

    /// The `settings.libraryGroups` entries of groups that moved whole.
    nonisolated static func carryEntries(_ went: [String: Set<String>], rows: [JSONValue],
                                         into root: inout [String: JSONValue]) {
        guard case .object(var settings)? = root["settings"],
              case .object(var map)? = settings[GroupKinds.settingsKey] else { return }
        // Every group path still in use, and every level above one.
        var inUse: Set<String> = []
        for case .object(let o) in rows {
            func text(_ k: String) -> String? { if case .string(let s)? = o[k] { s } else { nil } }
            guard let g = LibraryFile.groupName(folder: text("folder"), group: text("group")) else { continue }
            inUse.insert(g)
        }
        var changed = false
        for (from, destinations) in went {
            guard destinations.count == 1, let to = destinations.first, !to.isEmpty, to != from,
                  let entry = map[from], map[to] == nil,
                  // Something still filed at or below it keeps the group — and its entry.
                  !inUse.contains(where: { Shop.isUnder($0, from) }) else { continue }
            map[to] = entry
            map[from] = nil
            changed = true
        }
        guard changed else { return }
        settings[GroupKinds.settingsKey] = .object(map)
        root["settings"] = .object(settings)
    }

    /// Whether this walk may mark the book refiled: every linked folder was
    /// there and walked whole. A Drive not mounted yet at launch, or a folder
    /// that listed nothing while records point into it (a File Provider still
    /// starting up), is refiled later — never marked done unseen, which would
    /// leave its records under the old groups for good.
    nonisolated static func complete(linked: [String], walked: [(root: URL, models: [URL])],
                                     rows: [JSONValue]) -> Bool {
        let seen = Set(walked.map { $0.root.standardizedFileURL.path })
        for path in linked where !seen.contains(URL(fileURLWithPath: path).standardizedFileURL.path) {
            return false
        }
        // Each record belongs to the innermost linked folder around it, as
        // the walk files it (`Shop.linkedWalk`).
        let empty = Set(walked.filter { $0.models.isEmpty }.map { $0.root.standardizedFileURL.path })
        guard !empty.isEmpty else { return true }
        let roots = Array(seen)
        for case .object(let o) in rows {
            guard case .string(let p)? = o["externalPath"], !p.isEmpty else { continue }
            let owner = roots.filter { LibraryMove.under(p, $0) }.max { $0.count < $1.count }
            if let owner, empty.contains(owner) { return false }
        }
        return true
    }

    /// The version this book was last refiled at.
    nonisolated static func doneVersion(_ settings: [String: JSONValue]) -> Double {
        guard case .object(let l)? = settings["printLibrary"], case .number(let n)? = l["linkedGrouping"] else { return 0 }
        return n
    }

    nonisolated static func markDone(_ root: inout [String: JSONValue]) {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        library["linkedGrouping"] = .number(version)
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
    }
}
