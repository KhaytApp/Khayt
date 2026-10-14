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

/// A scan's progress, drawn a few times a second rather than once per file.
///
/// `libraryMoveProgress` is observed, and every change to it redraws what
/// reads it. Set once per file, a drive of ten thousand models asked for ten
/// thousand redraws while it was indexed (Oct 2026). The first and the last
/// are always drawn, so a count never stops short of where it ended.
@MainActor
final class ScanProgress {
    private var last: UInt64 = 0
    private let every: UInt64

    init(perSecond: Double = 8) { every = UInt64(1_000_000_000 / perSecond) }

    func due(_ done: Int, of total: Int) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard done == 0 || done >= total - 1 || now &- last >= every else { return false }
        last = now
        return true
    }
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
    ///
    /// 3 (Oct 2026): prints are the groups (`PrintSort`) — the collections a
    /// file came from leave the group and become a tag.
    ///
    /// 4 (Oct 2026): the models loose at the top of a linked folder are
    /// sorted into prints by their names (`LooseSort`).
    nonisolated static let version = 4.0

    struct Change: Equatable, Sendable {
        let id: String
        let group: String
        /// A new name, when the record still had the one the old rule gave.
        let name: String?
        /// The collection it came from, added to its tags when missing.
        var tag: String? = nil
    }

    /// The name a file gets when its folder does not name it.
    nonisolated static func stem(_ url: URL) -> String {
        url.lastPathComponent.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
    }

    /// The changes one linked folder needs, by the heuristic alone — what a
    /// test that has no pictures to list wants.
    nonisolated static func changes(rows: [JSONValue], root: URL, models: [URL]) -> [Change] {
        changes(rows: rows, plan: PrintSort.plan(root: root, models: models, images: []))
    }

    /// The changes one linked folder needs.
    ///
    /// - Parameters:
    ///   - rows: the book's `printFiles`.
    ///   - plan: the linked folder sorted — every model under it, as the
    ///     scan's walk found them, indexed or not, so a print of one model and
    ///     a print of several are judged over all of them.
    ///
    /// ── EVERY RULE THE APP HAS FILED BY IS THE APP'S ──────────────────────
    ///
    /// A record moves when its group is still one the app gave it: what the
    /// first rule produced (`ImportGrouping.V1`), what the alpha.66 rule
    /// produced (`ImportGrouping.placements` without the linked folder's
    /// name), or the `autoGroup` this app last wrote. Anything else the shop
    /// chose, and it stays. The same for its name.
    nonisolated static func changes(rows: [JSONValue], plan: PrintSort.Plan) -> [Change] {
        let root = plan.root
        let models = plan.models
        let v1 = ImportGrouping.V1.placements(for: models, chosen: root)
        let v2 = ImportGrouping.placements(for: models, chosen: root, includeChosen: false)
        func key(_ u: URL) -> String { u.standardizedFileURL.path }
        let byPath = Dictionary(models.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        // Every tag the book already uses, first spelling first (`Tags`' rule):
        // a collection the shop has tagged "aug26 giga tier" elsewhere is that
        // tag, not a second chip beside it.
        var spelled: [String: String] = [:]
        for case .object(let o) in rows {
            for t in Tags.normalise(o["tags"]) where spelled[Tags.key(t)] == nil { spelled[Tags.key(t)] = t }
        }
        var out: [Change] = []
        for case .object(let o) in rows {
            guard case .string(let id)? = o["id"], case .string(let path)? = o["externalPath"], !path.isEmpty,
                  LibraryMove.under(path, root.path),
                  let url = byPath[key(URL(fileURLWithPath: path))],
                  let now = plan.placement(of: url) else { continue }
            func text(_ k: String) -> String? { if case .string(let s)? = o[k] { s } else { nil } }
            let current = LibraryFile.groupName(folder: text("folder"), group: text("group")) ?? ""
            let older = [v1[url]?.group, v2[url]?.group].map { LibraryFile.normalise($0) }
            let fromOldRule = older.contains(current)
            let fromThisApp = text("autoGroup").map { LibraryFile.normalise($0) == current } ?? false
            guard fromOldRule || fromThisApp else { continue }          // the shop's own
            // Taken OUT of the group this app gave it: ungrouped by hand. A
            // loose model's old rule is "no group", so without this the next
            // refile put it straight back (version 4, loose models).
            if current.isEmpty, let auto = text("autoGroup"), !LibraryFile.normalise(auto).isEmpty { continue }
            let group = LibraryFile.normalise(now.group)
            var name: String?
            let oldNames = Set([v1[url]?.title, v2[url]?.title, nil].map { $0 ?? stem(url) })
            let newName = now.title ?? stem(url)
            if let had = text("name"), had != newName,
               oldNames.contains(had) || text("autoName") == had { name = newName }
            var tag: String?
            if let collection = now.collection, !collection.isEmpty {
                // Read the way every tag box reads them (`Tags.normalise`), so
                // a record whose tags are still one comma-separated string is
                // judged by the tags in it, not as having none.
                let tags = Tags.normalise(o["tags"])
                if !tags.contains(where: { Tags.key($0) == Tags.key(collection) }) {
                    // In the spelling the shop already uses for it, when it does.
                    tag = spelled[Tags.key(collection)] ?? collection
                }
            }
            guard group != current || name != nil || tag != nil else { continue }
            out.append(Change(id: id, group: group, name: name, tag: tag))
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
            if let name = c.name {
                o["name"] = .string(name)
                // So a later refile can tell this name from one the shop types.
                o["autoName"] = .string(name)
            }
            if let tag = c.tag {
                // ADDED to what is there, never instead of it: a list keeps
                // every entry as spelled, and the older comma-separated string
                // is read into its tags first rather than written over.
                var tags: [JSONValue] = []
                if case .array(let t)? = o["tags"] { tags = t }
                else { tags = Tags.normalise(o["tags"]).map(JSONValue.string) }
                if !tags.contains(where: { Tags.key($0) == Tags.key(tag) }) { tags.append(.string(tag)) }
                o["tags"] = .array(tags)
            }
            rows[i] = .object(o)
        }
        root["printFiles"] = .array(rows)
        carryEntries(went, rows: rows, into: &root)
    }

    /// The `settings.libraryGroups` entries of groups the refile emptied.
    ///
    /// ── NOT ONLY A GROUP THAT MOVED WHOLE (alpha.67 review) ───────────────
    ///
    /// Version 3 takes the collections OUT of the path, so alpha.66's
    /// `Aug26 Giga Tier/Life Size Gambit/{Large Cuts, Small Cuts}` becomes
    /// `Life Size Gambit/{Large Cuts, Small Cuts}`. A kind or picture the shop
    /// set on `Aug26 Giga Tier/Life Size Gambit` sat on a group no record is
    /// filed in DIRECTLY, so it was in no record's `from` and never carried;
    /// one set on a group whose records went to two parts had two
    /// destinations and was skipped. Either way the entry stayed on a dead
    /// path, and the next write of the map — the prints' pictures, moments
    /// later in the same pass — pruned it. The shop's choice was gone.
    ///
    /// So every entry the refile empties goes to the deepest group ALL of its
    /// records now share: the print, for a print's old path; the same group as
    /// before, for one that moved whole. A collection's entry has nowhere to
    /// go — its prints went their separate ways and it is a tag now — and is
    /// left where it was. A destination with an entry of its own keeps it (that
    /// is the shop's). Two old groups arriving at one new one: the deeper
    /// one's entry, with the other's picture if it has none (`joining`).
    nonisolated static func carryEntries(_ went: [String: Set<String>], rows: [JSONValue],
                                         into root: inout [String: JSONValue]) {
        guard case .object(var settings)? = root["settings"],
              case .object(var map)? = settings[GroupKinds.settingsKey] else { return }
        // Every group path still in use.
        var inUse: Set<String> = []
        for case .object(let o) in rows {
            func text(_ k: String) -> String? { if case .string(let s)? = o[k] { s } else { nil } }
            guard let g = LibraryFile.groupName(folder: text("folder"), group: text("group")) else { continue }
            inUse.insert(g)
        }
        let original = map
        var arrived: Set<String> = []
        // Deepest first: when a wrapper and the group inside it arrive at the
        // same print (`Tier/Buzz` and `Tier/Buzz/Buzz STLs`, or a tier that
        // held one print), the entry set on the nearer group is the print's.
        let keys = original.keys.sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a != b ? a > b : $0 < $1
        }
        var changed = false
        for from in keys {
            guard let entry = original[from],
                  // Something still filed at or below it keeps the group — and its entry.
                  !inUse.contains(where: { Shop.isUnder($0, from) }) else { continue }
            var destinations = Set<String>()
            for (was, to) in went where Shop.isUnder(was, from) { destinations.formUnion(to) }
            guard let to = sharedGroup(destinations), to != from else { continue }
            if arrived.contains(to) {
                map[to] = GroupKinds.joining(map[to], picture: entry)
            } else if original[to] != nil {
                continue                                                   // the shop's own
            } else {
                map[to] = entry
                arrived.insert(to)
            }
            map[from] = nil
            changed = true
        }
        guard changed else { return }
        settings[GroupKinds.settingsKey] = .object(map)
        root["settings"] = .object(settings)
    }

    /// The deepest group every one of `paths` is at or under — nil when they
    /// share none, or there are none, or one of them is no group at all.
    nonisolated static func sharedGroup(_ paths: Set<String>) -> String? {
        guard let first = paths.first, !paths.contains("") else { return nil }
        var common = first.components(separatedBy: ImportGrouping.separator)
        for p in paths.dropFirst() {
            let parts = p.components(separatedBy: ImportGrouping.separator)
            var n = 0
            while n < min(common.count, parts.count), common[n] == parts[n] { n += 1 }
            common = Array(common.prefix(n))
            if common.isEmpty { return nil }
        }
        let out = common.joined(separator: ImportGrouping.separator)
        return out.isEmpty ? nil : out
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
