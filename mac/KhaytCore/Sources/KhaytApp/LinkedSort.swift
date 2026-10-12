import Foundation
import CryptoKit
import KhaytCore

// MARK: - One linked folder, sorted

extension PrintSort {

    /// What the shop's assistant said about some folders, by folder key (the
    /// path below the linked folder). Empty when it said nothing — the
    /// heuristic then stands everywhere.
    struct Answers: Sendable, Equatable {
        var roles: [String: Role] = [:]
        var names: [String: String] = [:]
    }

    /// A linked folder, its tree, every folder's role and every model's place.
    struct Plan: Sendable {
        let root: URL
        let models: [URL]
        let images: [URL]
        let tree: Tree
        let roles: [String: Role]
        let names: [String: String]
        /// By model path below the linked folder.
        let placed: [String: Placement]

        func rel(_ url: URL) -> String? { PrintSort.rel(url, under: root) }

        func placement(of url: URL) -> Placement? { rel(url).flatMap { placed[$0] } }

        /// The print folders that hold models, by key.
        var prints: [String] { Array(Set(placed.values.compactMap(\.print))).sorted() }

        /// The group a print's models are filed under at its top level — its
        /// name — or nil for a print of one model.
        func group(ofPrint key: String) -> String? {
            for (_, p) in placed where p.print == key {
                guard let g = p.group else { return nil }
                return g.components(separatedBy: ImportGrouping.separator).first
            }
            return nil
        }

        /// The models of one print, by path below the linked folder.
        func models(ofPrint key: String) -> [String] {
            placed.filter { $0.value.print == key }.map(\.key).sorted()
        }
    }

    /// `url`'s path below `root`, or nil when it is not inside it.
    nonisolated static func rel(_ url: URL, under root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Sort one linked folder: the heuristic, with whatever the assistant
    /// said laid over it.
    static func plan(root: URL, models: [URL], images: [URL], answers: Answers = Answers()) -> Plan {
        let modelRels = models.compactMap { rel($0, under: root) }
        let imageRels = images.compactMap { rel($0, under: root) }
        let tree = Tree(models: modelRels, images: imageRels)
        let roles = classify(tree, answers: answers.roles)
        let placed = placements(tree, roles: roles, models: modelRels, names: answers.names)
        return Plan(root: root, models: models, images: images, tree: tree, roles: roles,
                    names: answers.names, placed: placed)
    }
}

// MARK: - What the assistant is sent, and what it said, remembered

/// The assistant's sorting, cached in the book so the same tree is never sent
/// twice: `settings.printLibrary.folderSort`, one entry per TOP-LEVEL folder
/// of a linked folder, keyed by that folder's path and holding a signature of
/// every folder name and model count beneath it. A folder that gains or loses
/// a sub-folder, or a model, has a new signature, and is asked about again.
enum SortCache {

    nonisolated static let settingsKey = "folderSort"

    /// A top-level folder, as one unit of asking.
    struct Unit: Sendable, Equatable {
        /// The top-level folder's absolute path — the cache key.
        let key: String
        let signature: String
        /// What is sent, one per folder, parents first.
        let entries: [Entry]
    }

    /// One folder as the assistant reads it (`lib/ai-library.js
    /// buildLibraryRequest`).
    struct Entry: Sendable, Equatable {
        let path: String
        let models: Int
        let folders: [String]
        let samples: [String]

        var json: JSONValue {
            .object(["path": .string(path), "models": .number(Double(models)),
                     "folders": .array(folders.map(JSONValue.string)),
                     "samples": .array(samples.map(JSONValue.string))])
        }
    }

    /// Every top-level folder of a sorted linked folder, ready to send.
    /// Folders with no model at or below them are left out: the heuristic
    /// already knows what a folder of pictures is.
    nonisolated static func units(_ plan: PrintSort.Plan) -> [Unit] {
        let tree = plan.tree
        var out: [Unit] = []
        for top in tree[""]?.children ?? [] where (tree[top]?.under ?? 0) > 0 {
            var entries: [Entry] = []
            func walk(_ key: String) {
                guard let n = tree[key], n.under > 0 else { return }
                let kids = n.children.filter { (tree[$0]?.under ?? 0) > 0 || !(tree[$0]?.images.isEmpty ?? true) }
                entries.append(Entry(path: key, models: n.models,
                                     folders: kids.compactMap { tree[$0]?.name },
                                     samples: n.samples))
                for child in n.children { walk(child) }
            }
            walk(top)
            let abs = plan.root.appending(path: top).standardizedFileURL.path
            out.append(Unit(key: abs, signature: signature(entries), entries: entries))
        }
        return out
    }

    /// A short digest of a unit's folder names and counts.
    nonisolated static func signature(_ entries: [Entry]) -> String {
        let text = entries.map { "\($0.path)|\($0.models)|\($0.folders.joined(separator: ","))" }
            .sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The requests a set of units makes: whole units together up to
    /// `limit` folders, and a unit bigger than that in pieces of `limit`.
    nonisolated static func batches(_ units: [Unit], limit: Int = 150) -> [[Entry]] {
        var out: [[Entry]] = []
        var current: [Entry] = []
        for unit in units {
            if unit.entries.count > limit {
                stride(from: 0, to: unit.entries.count, by: limit).forEach {
                    out.append(Array(unit.entries[$0..<min($0 + limit, unit.entries.count)]))
                }
                continue
            }
            if current.count + unit.entries.count > limit, !current.isEmpty {
                out.append(current)
                current = []
            }
            current += unit.entries
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The cached answers for one linked folder, for the folders still there.
    ///
    /// ── A STALE ANSWER STILL STANDS UNTIL A NEW ONE COMES (alpha.67 review) ──
    ///
    /// A unit whose tree changed (a model added under it) is ASKED again —
    /// `isCached` holds it to its signature — but until that answer arrives
    /// its last one is used for every folder it named that is still there.
    /// Dropping it the moment the signature moved put the heuristic back for
    /// the whole unit: the new model was filed under the heuristic's name for
    /// its print while its siblings sat under the assistant's, and with the
    /// assistant off or unreachable "Regroup from folders" moved every record
    /// of the unit back — the library flipping between two sorts of the same
    /// folders. A folder renamed or gone is a path no longer in the unit, and
    /// its answer is not used.
    nonisolated static func answers(_ settings: [String: JSONValue], for units: [Unit]) -> PrintSort.Answers {
        guard case .object(let library)? = settings["printLibrary"],
              case .object(let map)? = library[settingsKey] else { return PrintSort.Answers() }
        var out = PrintSort.Answers()
        for unit in units {
            guard case .object(let entry)? = map[unit.key] else { continue }
            let here = Set(unit.entries.map(\.path))
            if case .object(let roles)? = entry["roles"] {
                for (path, role) in roles where here.contains(path) {
                    if case .string(let r) = role, let parsed = PrintSort.Role(rawValue: r) { out.roles[path] = parsed }
                }
            }
            if case .object(let names)? = entry["names"] {
                for (path, name) in names where here.contains(path) {
                    if case .string(let n) = name, !n.isEmpty { out.names[path] = n }
                }
            }
        }
        return out
    }

    /// Whether a unit's answer is already in the book.
    nonisolated static func isCached(_ unit: Unit, in settings: [String: JSONValue]) -> Bool {
        guard case .object(let library)? = settings["printLibrary"],
              case .object(let map)? = library[settingsKey],
              case .object(let entry)? = map[unit.key], case .string(let sig)? = entry["sig"] else { return false }
        return sig == unit.signature
    }

    /// Write units' answers into the book's settings (inside the store's chain).
    nonisolated static func store(_ answered: [(unit: Unit, answers: PrintSort.Answers)],
                                  at: Date = Date(), into root: inout [String: JSONValue]) {
        guard !answered.isEmpty else { return }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        var map: [String: JSONValue] = [:]
        if case .object(let m)? = library[settingsKey] { map = m }
        for (unit, answers) in answered {
            let mine = Set(unit.entries.map(\.path))
            map[unit.key] = .object([
                "sig": .string(unit.signature),
                "at": .string(StoreWriter.iso(at)),
                "roles": .object(answers.roles.filter { mine.contains($0.key) }.mapValues { .string($0.rawValue) }),
                "names": .object(answers.names.filter { mine.contains($0.key) }.mapValues(JSONValue.string)),
            ])
        }
        library[settingsKey] = .object(map)
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
    }
}

// MARK: - The prints' pictures

/// Which prints have been looked at for a picture, so the drive is not asked
/// for them again: `settings.printLibrary.printPhotos`, a list of print
/// folder paths.
enum PrintPhotos {

    nonisolated static let settingsKey = "printPhotos"

    /// A picture bigger than this is passed over (the drive's listed size,
    /// so nothing is fetched to find out).
    nonisolated static let maxBytes = 8 * 1024 * 1024

    /// Pictures fetched in one pass at most. A shop's drive of 300 prints
    /// fills in over a few scans rather than downloading at once.
    nonisolated static let perPass = 40

    nonisolated static func looked(_ settings: [String: JSONValue]) -> Set<String> {
        guard case .object(let library)? = settings["printLibrary"],
              case .array(let rows)? = library[settingsKey] else { return [] }
        return Set(rows.compactMap { if case .string(let s) = $0 { s } else { nil } })
    }

    nonisolated static func markLooked(_ paths: [String], into root: inout [String: JSONValue]) {
        guard !paths.isEmpty else { return }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        var have: [JSONValue] = []
        if case .array(let rows)? = library[settingsKey] { have = rows }
        let known = Set(have.compactMap { if case .string(let s) = $0 { s } else { nil } })
        for p in paths where !known.contains(p) { have.append(.string(p)) }
        library[settingsKey] = .array(have)
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
    }

    /// One print to picture: where it is, the group that wears the picture
    /// (nil for a print of one model, whose model wears it), and its
    /// pictures best first.
    struct Job: Sendable, Equatable {
        let print: String
        let group: String?
        let candidates: [URL]
        /// A picture named exactly as one model, by that model's path.
        let modelPictures: [String: URL]
        /// The model of a print of one model.
        let only: String?
    }

    /// What a pass would look at, in order, at most `limit` of them.
    nonisolated static func jobs(_ plans: [PrintSort.Plan], looked: Set<String>, limit: Int = perPass) -> [Job] {
        var out: [Job] = []
        for plan in plans {
            for key in plan.prints {
                let abs = plan.root.appending(path: key).standardizedFileURL.path
                guard !looked.contains(abs) else { continue }
                let name = plan.names[key] ?? PrintSort.cleanName(plan.tree[key]?.name ?? key)
                let pics = PrintSort.pictures(of: key, in: plan.tree, roles: plan.roles, name: name)
                let models = plan.models(ofPrint: key)
                let own = PrintSort.modelPictures(of: key, in: plan.tree, models: models)
                let group = plan.group(ofPrint: key)
                var ownPictures: [String: URL] = [:]
                for (model, image) in own {
                    ownPictures[plan.root.appending(path: model).standardizedFileURL.path] = plan.root.appending(path: image)
                }
                let only = group == nil ? models.first.map { plan.root.appending(path: $0).standardizedFileURL.path } : nil
                out.append(Job(print: abs, group: group,
                               candidates: pics.map { plan.root.appending(path: $0) },
                               modelPictures: ownPictures, only: only))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// The first candidate small enough to fetch. Listed size only — reading
    /// it is the download.
    nonisolated static func pick(_ candidates: [URL], size: (URL) -> Int = LinkedCloud.listedSize) -> URL? {
        candidates.first { let s = size($0); return s > 0 && s <= maxBytes }
    }
}
