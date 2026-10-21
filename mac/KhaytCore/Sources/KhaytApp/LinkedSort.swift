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
        /// The print each loose top-level model belongs to, by its path
        /// (`LooseCache`).
        var loose: [String: String] = [:]
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
        /// When each top-level file was created, by path — the copy order the
        /// loose models are read in (`LooseSort`).
        var births: [String: Double] = [:]
        /// The prints found among the loose top-level models, by print key.
        var loose: [String: LooseSort.Cluster] = [:]
        /// Loose models in no print with pictures of their own name, by path.
        var looseSingles: [String: [String]] = [:]
        /// A loose print's member with a picture of exactly its name, by path.
        var looseOwn: [String: String] = [:]
        /// Loose pictures nothing claimed.
        var looseUnattached: [String] = []
        /// Pictures to check: offered in "Sort linked folders…", never put on
        /// by themselves. A print target is a print KEY.
        var suggestions: [LooseSort.Suggestion] = []

        /// The pictures at the top of the linked folder, in copy order.
        var looseImages: [String] {
            LooseSort.order(images.compactMap(rel).filter { !$0.contains("/") }, births: births)
        }

        /// The models at the top of the linked folder, in no sub-folder, in
        /// copy order.
        var looseModels: [String] {
            LooseSort.order(models.compactMap(rel).filter { !$0.contains("/") }, births: births)
        }

        /// A print's name: the loose print's, the assistant's, or its folder's.
        func name(ofPrint key: String) -> String {
            loose[key]?.name ?? names[key] ?? PrintSort.cleanName(tree[key]?.name ?? key)
        }

        /// A print's pictures, best first, by path below the linked folder.
        func pictures(ofPrint key: String) -> [String] {
            if let c = loose[key] { return c.pictures }
            return PrintSort.pictures(of: key, in: tree, roles: roles, name: name(ofPrint: key))
        }

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
    ///
    /// `births` (seconds, by path) is when each top-level file was created —
    /// the order a copy job dropped the loose models in (`LooseSort`).
    static func plan(root: URL, models: [URL], images: [URL], answers: Answers = Answers(),
                     births: [String: Double] = [:]) -> Plan {
        let modelRels = models.compactMap { rel($0, under: root) }
        let imageRels = images.compactMap { rel($0, under: root) }
        let tree = Tree(models: modelRels, images: imageRels)
        let roles = classify(tree, answers: answers.roles)
        // THE LOOSE ONES, sorted by their names in the order they arrived.
        let sorted = LooseSort.sort(models: modelRels.filter { !$0.contains("/") },
                                    images: imageRels.filter { !$0.contains("/") },
                                    births: births, assistant: answers.loose)
        let clusters = sorted.clusters
        var loose: [String: LooseSort.Cluster] = [:]
        var printOf: [String: String] = [:]
        var names = answers.names
        for c in clusters {
            let key = looseKey(c.name)
            if let had = loose[key] {
                loose[key] = LooseSort.Cluster(name: had.name, members: had.members + c.members,
                                               pictures: had.pictures + c.pictures,
                                               byAssistant: had.byAssistant || c.byAssistant)
            } else {
                loose[key] = c
            }
            names[key] = loose[key]?.name
            for m in c.members { printOf[m] = key }
        }
        let placed = placements(tree, roles: roles, models: modelRels, names: names, loose: printOf)
        return Plan(root: root, models: models, images: images, tree: tree, roles: roles,
                    names: answers.names, placed: placed, births: births, loose: loose,
                    looseSingles: sorted.singles, looseOwn: sorted.own, looseUnattached: sorted.unattached,
                    suggestions: sorted.suggestions.map { s in
                        guard case .print(let name) = s.target else { return s }
                        return LooseSort.Suggestion(image: s.image, target: .print(looseKey(name)),
                                                    reason: s.reason, ticked: s.ticked)
                    } + folderSuggestions(tree, roles: roles, names: answers.names))
    }

    /// The key a print found among the loose models goes by. Never a
    /// folder's: a folder key is a path below the linked folder, and no
    /// model sits in a folder called `#loose` at the top of one.
    nonisolated static func looseKey(_ name: String) -> String { "#loose/" + LooseSort.identity(name) }

    /// The folder prints' pictures to check: a pack media folder's picture
    /// that names a print with a word more, or names two prints equally
    /// (`mediaPictures`), for a print with no picture of its own.
    static func folderSuggestions(_ tree: Tree, roles: [String: Role],
                                  names: [String: String]) -> [LooseSort.Suggestion] {
        var out: [LooseSort.Suggestion] = []
        for (key, role) in roles where role == .print {
            let name = names[key] ?? cleanName(tree[key]?.name ?? key)
            guard pictures(of: key, in: tree, roles: roles, name: name).isEmpty else { continue }
            for o in mediaPictures(of: key, in: tree, roles: roles, name: name).offered {
                out.append(LooseSort.Suggestion(image: o.rel, target: .print(key), reason: .named, ticked: o.ticked))
            }
        }
        return out.sorted { $0.image < $1.image }
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

// MARK: - The loose files: what was sent, and what came back

/// The assistant's grouping of the LOOSE models at the top of a linked
/// folder (`LooseSort`), cached in the book so a name is never sent twice:
/// `settings.printLibrary.looseSort`, one entry per linked folder (its
/// absolute path), holding the prints it named — `{name: [path…]}` — and
/// `none`, the names it was asked about and put in no print.
///
/// ── NAMES ONLY, A FEW HUNDRED AT A TIME ───────────────────────────────────
///
/// A request carries at most `perRequest` names (`lib/ai-library.js
/// LIMITS.looseNames`) and a scan at most `perScan`; the rest wait for the
/// next scan. Each name is the file's own, below the linked folder — never a
/// path above it — in the order the files were created, because that is
/// where a kit's parts sit together.
enum LooseCache {

    nonisolated static let settingsKey = "looseSort"
    /// `lib/ai-library.js LIMITS.looseNames` — `LooseSortTests` holds them equal.
    nonisolated static let perRequest = 300
    /// `lib/ai-library.js LIMITS.looseNamesPerScan`.
    nonisolated static let perScan = 3000

    private nonisolated static func entry(_ settings: [String: JSONValue], _ root: URL) -> [String: JSONValue]? {
        guard case .object(let library)? = settings["printLibrary"],
              case .object(let map)? = library[settingsKey],
              case .object(let e)? = map[root.standardizedFileURL.path] else { return nil }
        return e
    }

    /// Every loose name the assistant was already asked about, for one
    /// linked folder.
    nonisolated static func asked(_ settings: [String: JSONValue], root: URL) -> Set<String> {
        guard let e = entry(settings, root) else { return [] }
        var out = Set<String>()
        if case .object(let prints)? = e["prints"] {
            for case .array(let rows) in prints.values {
                for case .string(let r) in rows { out.insert(r) }
            }
        }
        if case .array(let rows)? = e["none"] { for case .string(let r) in rows { out.insert(r) } }
        return out
    }

    /// The print each loose model was put in, for the models still there.
    /// Read back from settings that sync from every device, so each name is
    /// held to the group rule again (`PrintSort.assistantName`) and each
    /// path must be one the walk found.
    nonisolated static func answers(_ settings: [String: JSONValue], root: URL,
                                    present: Set<String>) -> [String: String] {
        guard let e = entry(settings, root), case .object(let prints)? = e["prints"] else { return [:] }
        var out: [String: String] = [:]
        for (raw, rows) in prints {
            guard let name = PrintSort.assistantName(raw), case .array(let list) = rows else { continue }
            for case .string(let r) in list where present.contains(r) && out[r] == nil { out[r] = name }
        }
        return out
    }

    /// The loose names still to ask about — models and pictures, so the
    /// assistant can say which print a picture shows (only ever an offer) —
    /// in copy order, at most `perScan`.
    nonisolated static func pending(_ plan: PrintSort.Plan, settings: [String: JSONValue]) -> [String] {
        let done = asked(settings, root: plan.root)
        let all = LooseSort.order(plan.looseModels + plan.looseImages, births: plan.births)
        return Array(all.filter { !done.contains($0) }.prefix(perScan))
    }

    /// Every loose name of a plan, for `store`'s `present`.
    nonisolated static func present(_ plan: PrintSort.Plan) -> Set<String> {
        Set(plan.looseModels).union(plan.looseImages)
    }

    /// The requests a list of names makes: at most `perRequest` each, and a
    /// cut made where the copy job paused longest near the end of a full
    /// batch — so one kit is less often split over two requests.
    nonisolated static func batches(_ names: [String], births: [String: Double] = [:],
                                    limit: Int = perRequest) -> [[String]] {
        var out: [[String]] = []
        var start = 0
        while start < names.count {
            var end = min(start + limit, names.count)
            if end < names.count, !births.isEmpty {
                let from = max(start + limit * 4 / 5, start + 1)
                var best = end, gap = -1.0
                for i in from..<end {
                    guard let a = births[names[i - 1]], let b = births[names[i]] else { continue }
                    if b - a > gap { gap = b - a; best = i }
                }
                end = best
            }
            out.append(Array(names[start..<end]))
            start = end
        }
        return out
    }

    /// What one request came back with, by path.
    struct Answered: Sendable, Equatable {
        let root: URL
        let sent: [String]
        /// Print name → its members' paths.
        let prints: [String: [String]]
    }

    /// The assistant's prints as paths: indices into the batch that was sent.
    nonisolated static func answered(root: URL, sent: [String],
                                     prints: [KhaytEngine.AiLooseAnswer.Print]) -> Answered {
        var out: [String: [String]] = [:]
        for p in prints {
            guard let name = PrintSort.assistantName(p.name) else { continue }
            let members = p.members.filter { sent.indices.contains($0) }.map { sent[$0] }
            guard members.count >= 2 else { continue }
            out[name, default: []] += members
        }
        return Answered(root: root, sent: sent, prints: out)
    }

    /// Write answers into the book's settings (inside the store's chain).
    /// Names no longer under the linked folder (`present`) are let go, so the
    /// entry never outgrows the folder.
    nonisolated static func store(_ answers: [Answered], present: [String: Set<String>],
                                  at: Date = Date(), into root: inout [String: JSONValue]) {
        guard !answers.isEmpty else { return }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        var map: [String: JSONValue] = [:]
        if case .object(let m)? = library[settingsKey] { map = m }
        for (folder, group) in Dictionary(grouping: answers, by: { $0.root.standardizedFileURL.path }) {
            let here = present[folder] ?? []
            var prints: [String: [String]] = [:]
            var none: [String] = []
            if case .object(let e)? = map[folder] {
                if case .object(let p)? = e["prints"] {
                    for (name, rows) in p {
                        if case .array(let list) = rows {
                            prints[name] = list.compactMap { if case .string(let s) = $0, here.contains(s) { s } else { nil } }
                        }
                    }
                }
                if case .array(let rows)? = e["none"] {
                    none = rows.compactMap { if case .string(let s) = $0, here.contains(s) { s } else { nil } }
                }
            }
            for a in group {
                var placed = Set<String>()
                for (name, members) in a.prints {
                    prints[name, default: []] += members
                    placed.formUnion(members)
                }
                none += a.sent.filter { !placed.contains($0) }
            }
            let kept = prints.filter { !$0.value.isEmpty }
            map[folder] = .object([
                "at": .string(StoreWriter.iso(at)),
                "prints": .object(kept.mapValues { .array($0.map(JSONValue.string)) }),
                "none": .array(none.map(JSONValue.string)),
            ])
        }
        library[settingsKey] = .object(map)
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
    }

    /// A request's signature, for `SortFailures`.
    nonisolated static func signature(_ names: [String]) -> String {
        let text = "loose\n" + names.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Requests that keep failing

/// Requests the assistant failed on, so a failing one is not paid for on
/// every launch: `settings.printLibrary.folderSortFailed`, keyed by the
/// request's signature (`SortCache.signature` of its folders), holding how
/// many times it failed and the last day (`YYYY-MM-DD`, the book's calendar).
///
/// The launch pass skips a request that failed today, and one that failed
/// `giveUpAfter` times until its folders change (a new signature). "Sort
/// linked folders…" pressed by hand always tries. A request that succeeds is
/// forgotten.
enum SortFailures {

    nonisolated static let settingsKey = "folderSortFailed"
    nonisolated static let giveUpAfter = 3

    struct Mark: Sendable, Equatable {
        var count: Int
        var last: String
    }

    nonisolated static func today(_ now: Date = Date()) -> String { Calendar.book.dayString(now) }

    nonisolated static func read(_ settings: [String: JSONValue]) -> [String: Mark] {
        guard case .object(let library)? = settings["printLibrary"],
              case .object(let map)? = library[settingsKey] else { return [:] }
        var out: [String: Mark] = [:]
        for (sig, v) in map {
            guard case .object(let o) = v, case .number(let n)? = o["count"], case .string(let d)? = o["last"] else { continue }
            out[sig] = Mark(count: Int(saturating: n), last: d)
        }
        return out
    }

    /// Whether the launch pass leaves this request alone.
    nonisolated static func held(_ signature: String, in marks: [String: Mark], today: String) -> Bool {
        guard let m = marks[signature] else { return false }
        return m.count >= giveUpAfter || m.last == today
    }

    /// The marks after a pass: one more for each that failed, none for each
    /// that came back, and none for a request this pass no longer makes (its
    /// folders changed, or were answered) — so the map never outgrows the
    /// folders still waiting.
    nonisolated static func after(_ marks: [String: Mark], asked: Set<String>, failed: Set<String>,
                                  pending: Set<String>, today: String) -> [String: Mark] {
        var out = marks.filter { pending.contains($0.key) }
        for sig in asked where !failed.contains(sig) { out[sig] = nil }
        for sig in failed { out[sig] = Mark(count: (marks[sig]?.count ?? 0) + 1, last: today) }
        return out
    }

    /// The folder sort's marks, with the "Check pictures" ones (`picture:…`)
    /// as the book holds them now. The two passes share this map: the sort's
    /// `after` keeps only its own pending requests, and wrote the pictures'
    /// failures away (review of #1844).
    nonisolated static func keepingPictures(_ marks: [String: Mark], from settings: [String: JSONValue]) -> [String: Mark] {
        var out = marks.filter { !$0.key.hasPrefix("picture:") }
        for (k, v) in read(settings) where k.hasPrefix("picture:") { out[k] = v }
        return out
    }

    nonisolated static func write(_ marks: [String: Mark], into root: inout [String: JSONValue]) {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        library[settingsKey] = marks.isEmpty ? nil
            : .object(marks.mapValues { .object(["count": .number(Double($0.count)), "last": .string($0.last)]) })
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
                let pics = plan.pictures(ofPrint: key)
                let models = plan.models(ofPrint: key)
                let own: [String: String] = plan.loose[key] != nil
                    ? plan.looseOwn.filter { models.contains($0.key) }
                    : PrintSort.modelPictures(of: key, in: plan.tree, models: models)
                // Nothing to put on: not a job, and not looked at — a picture
                // that turns up later is still found (alpha.67: a print looked
                // at once with nothing was never looked at again).
                guard !pics.isEmpty || !own.isEmpty else { continue }
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
            // A loose model in no print, with a picture certainly its own.
            for (model, pics) in plan.looseSingles.sorted(by: { $0.key < $1.key }) {
                let path = plan.root.appending(path: model).standardizedFileURL.path
                let abs = path + "#photo"
                guard !looked.contains(abs), !pics.isEmpty else { continue }
                out.append(Job(print: abs, group: nil, candidates: pics.map { plan.root.appending(path: $0) },
                               modelPictures: [:], only: path))
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

    /// One print's share of a pass: what to fetch for it, and whether it is
    /// settled — remembered as looked at — once those pictures are on.
    struct Step: Sendable, Equatable {
        let print: String
        /// The group that wears the picture, and the picture it gets.
        var group: String?
        var groupPick: URL?
        /// A print of one model: that model's path, and its picture.
        var only: String?
        var onlyPick: URL?
        /// Pictures named exactly for one model, by the model's path.
        var models: [String: URL] = [:]
        var settled = true
    }

    /// ── LOOKED AT ONLY ONCE SETTLED (Oct 2026, review of #1844) ──────────
    ///
    /// What one pass fetches, decided before a byte is read: at most `limit`
    /// pictures, over EVERY print still waiting (a print that cannot be
    /// settled yet costs nothing, so it cannot hold the pass up). A print is
    /// settled when its picture goes on, or it already wears one; it is NOT
    /// when its group has nobody filed in it yet (the picture would be thrown
    /// away), its pictures are all too big, or its model is not in the book
    /// yet — those are tried again next pass, without a download now.
    nonisolated static func pass(_ jobs: [Job], covered: Set<String>, live: Set<String>,
                                 photoless: Set<String>, indexed: Set<String>, limit: Int = perPass,
                                 pick: ([URL]) -> URL? = { PrintPhotos.pick($0) }) -> [Step] {
        var out: [Step] = []
        var fetched = 0
        var planned = Set<String>()
        for job in jobs {
            if fetched >= limit { break }
            var step = Step(print: job.print)
            if let group = job.group, !covered.contains(group) {
                if !live.contains(where: { Shop.isUnder($0, group) }) {
                    step.settled = false                         // nobody filed there yet
                } else if let p = pick(job.candidates) {
                    step.group = group
                    step.groupPick = p
                    fetched += 1
                } else {
                    step.settled = false                         // every picture too big
                }
            }
            if let only = job.only {
                if photoless.contains(only) {
                    if fetched < limit, let p = pick(job.candidates) {
                        step.only = only
                        step.onlyPick = p
                        planned.insert(only)
                        fetched += 1
                    } else {
                        step.settled = false
                    }
                } else if !indexed.contains(only) {
                    step.settled = false                         // not in the book yet
                }
            }
            for (model, image) in job.modelPictures.sorted(by: { $0.key < $1.key })
            where photoless.contains(model) && !planned.contains(model) && fetched < limit {
                guard let p = pick([image]) else { continue }
                step.models[model] = p
                planned.insert(model)
                fetched += 1
            }
            if step.settled || step.groupPick != nil || step.onlyPick != nil || !step.models.isEmpty {
                out.append(step)
            }
        }
        return out
    }

    /// The prints a pass may remember as looked at, once the write said which
    /// group pictures went on: one whose group turned out to have nobody in
    /// it (no picture went on) is not settled.
    nonisolated static func settled(_ steps: [Step], notWorn: Set<String>) -> [String] {
        steps.filter { $0.settled && !($0.group.map(notWorn.contains) ?? false) }.map(\.print)
    }
}
