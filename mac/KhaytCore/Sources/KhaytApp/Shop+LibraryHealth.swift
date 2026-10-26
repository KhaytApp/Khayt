import AppKit
import Foundation
import KhaytCore

/// One Library Health group's models, put on the grid by its Show button.
///
/// A filter like the other Show-menu ones: on the Show menu while it is on
/// (`LibraryFilterBar`), cleared by Clear filters, and in the grid's memo key.
/// The ids in the GROUP'S order, so the copies of one model stand together.
struct LibraryHealthFocus: Hashable, Sendable {
    let kind: LibraryHealth.Kind
    let ids: [String]
    /// What its chip says, when it is not a Health group's own title — an
    /// archive's name, from its folder tile's Remove (`askToRemoveArchive`).
    var label: String? = nil
    /// A word key said above the grid while it is on — the mirror caveat for
    /// a same-shape group or a Find Similar that matched by shape.
    var note: String? = nil
}

/// ── LIBRARY HEALTH, ON THE MAC ──────────────────────────────────────────
///
/// The groups are `LibraryHealth.groups` (KhaytCore), from facts gathered
/// here: where each model's bytes are (the disk and the sync index, asked off
/// the main actor), what its slicer said, its key, the beds and the
/// catalogue. Every fix is a door the app already has:
///
///   Show in Library    — a filter (`libraryHealthFocus`), nothing written.
///   Remove from Library — the grid, narrowed to exactly those models and
///                        drawn flat, then `askToDeleteFromLibrary` — the
///                        same question, with the same names and the same
///                        count of how many are filed in groups, and the same
///                        refusal if any of them is not on screen (27 Sep 2026).
///   Measure            — the bytes read the way a model brought down is
///                        (`readDownloaded` / `applyDownloaded`), one write.
///   Measure online…    — `measureOnlineModels`, behind its own question.
///   Locate…            — the shop points at the file; only the SAME bytes
///                        (`contentHash`) are taken.
///   Open (a product)   — the product sheet (`productForEditing`).
///
/// Duplicates are never merged: the page lists them, and Show puts each set
/// side by side for the shop to decide.
extension Shop {

    // MARK: - The facts

    /// Where each model's bytes are. Linked models: their own path (and a
    /// drive's placeholder is online). Vault models: their folder, unless the
    /// sync index says the file is online. With no library folder at all
    /// (the sample) nothing is known, and nothing is called missing.
    ///
    /// A file is only MISSING when the place it lives is there to ask: a
    /// linked folder (or a `/Volumes` drive) that is gone or empty, or a
    /// library folder that is not there, makes its models `.unreachable` —
    /// an unplugged drive is not a reason to remove a thousand records. A
    /// vault model not on disk while the sync index has not loaded yet, with
    /// online storage set up, is `.unknown`: it may well be online.
    nonisolated static func healthPresence(_ files: [LibraryFile], roots: [String]?, online: Set<String>,
                                           linkedRoots: [String] = [], indexPending: Bool = false,
                                           linkedOnline: @Sendable (URL) -> Bool) -> [String: LibraryHealth.Presence] {
        var out: [String: LibraryHealth.Presence] = [:]
        // A compressed file is asked about ONCE, however many models it holds.
        var archives: [String: LibraryHealth.Presence] = [:]
        var reach = HealthReach(linkedRoots: linkedRoots)
        var vaultReachable: Bool?
        for file in files {
            if file.isWebOnly { out[file.id] = .web; continue }
            if online.contains(file.id) { out[file.id] = .online; continue }
            if let path = file.archivePath {
                // No library folder (the sample): nothing is known, as below.
                guard let roots, !roots.isEmpty else { out[file.id] = .unknown; continue }
                // A changed archive that no longer holds it: gone, on its own.
                if file.archiveGone == true { out[file.id] = .missing; continue }
                if let known = archives[path] { out[file.id] = known; continue }
                let p: LibraryHealth.Presence = !FileManager.default.fileExists(atPath: path)
                    ? (reach.isReachable(path) ? .missing : .unreachable)
                    : linkedOnline(URL(fileURLWithPath: path)) ? .online : .here
                archives[path] = p
                out[file.id] = p
                continue
            }
            if let path = file.externalPath, !path.isEmpty {
                guard FileManager.default.fileExists(atPath: path) else {
                    out[file.id] = reach.isReachable(path) ? .missing : .unreachable; continue
                }
                out[file.id] = linkedOnline(URL(fileURLWithPath: path)) ? .online : .here
                continue
            }
            guard let roots, !roots.isEmpty else { out[file.id] = .unknown; continue }
            guard LibraryLocation.directory(for: file.id, roots: roots) == nil else { out[file.id] = .here; continue }
            if vaultReachable == nil { vaultReachable = roots.allSatisfy { reach.folderIsThere($0) } }
            out[file.id] = vaultReachable == false ? .unreachable : indexPending ? .unknown : .missing
        }
        return out
    }

    /// A library record as the rule reads it.
    nonisolated static func healthModel(_ file: LibraryFile, presence: LibraryHealth.Presence) -> LibraryHealth.Model {
        let sliced = LibraryFacts.sliced(file)
        return LibraryHealth.Model(id: file.id, title: file.title, presence: presence,
                                   contentHash: file.contentHash, geometryKey: file.geometryKey,
                                   slicedMinutes: sliced.minutes, slicedGrams: sliced.grams,
                                   tags: file.tags ?? [], category: file.category, archived: file.isArchived,
                                   inArchive: file.archivePath)
    }

    /// The catalogue, as the rule reads it: each product and the library
    /// models its parts print from.
    nonisolated static func healthProducts(_ rows: [JSONValue]) -> [LibraryHealth.Product] {
        rows.compactMap { row in
            guard case .object(let o) = row, let id = recordId(row) else { return nil }
            var ids: [String] = []
            if case .array(let parts)? = o["parts"] {
                for case .object(let p) in parts {
                    if case .string(let f)? = p["printFileId"], !f.isEmpty { ids.append(f) }
                }
            }
            return .init(id: id, name: plainString(o["name"]) ?? id, printFileIds: ids)
        }
    }

    /// The machines in use and their beds, with each one's kind, so the rule
    /// can leave the lasers and UV printers out.
    var healthMachines: [LibraryHealth.Machine] {
        machinesInUse.map { .init(id: $0.id, kind: kind(of: $0)?.kind, bed: bed(of: $0.id)) }
    }

    // MARK: - Checking

    /// Work the groups out again. The disk is asked off the main actor — a
    /// stat per model, ten thousand on a linked drive.
    func checkLibraryHealth() async {
        let files = self.files
        let roots = libraryRoots?.roots
        let index = syncIndex, remote = libraryRemoteId
        let online = Set(files.lazy.filter { index?.state($0.id, remote: remote) == .online }.map(\.id))
        let pretend = pretendHealthPresence
        let linkedOnline = linkedIsOnline
        let linkedRoots = linkedFolders
        let indexPending = index == nil && remote != nil
        let presence = await PinWork.run {
            pretend ?? Shop.healthPresence(files, roots: roots, online: online, linkedRoots: linkedRoots,
                                           indexPending: indexPending, linkedOnline: linkedOnline)
        }
        let models = files.map { Self.healthModel($0, presence: presence[$0.id] ?? .here) }
        libraryHealthGroups = LibraryHealth.groups(models: models, machines: healthMachines,
                                                   products: Self.healthProducts(productRows))
        await countOnlineUnmeasured()
    }

    /// The page, over the library's grid. Nothing is written by opening it.
    func openLibraryHealth() {
        if !showingLibrary { shelf = .library(nil) }
        libraryHealthNote = nil
        libraryHealthOpen = true
    }

    /// One group's models, as the book holds them, in the group's order.
    func healthFiles(_ group: LibraryHealth.Group) -> [LibraryFile] {
        let byId = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return group.modelIds.compactMap { byId[$0] }
    }

    // MARK: - The fixes

    /// Put exactly this group on the grid: every other filter and the search
    /// cleared, the top of the library, drawn flat — a filter is on, so
    /// `libraryShowsFlat` holds and no model of the group is folded inside a
    /// folder tile. `select` chooses them all, for the multi-select pane.
    func showHealthGroup(_ group: LibraryHealth.Group, select: Bool = false) {
        clearLibraryFilter()
        search = ""
        shelf = .library(nil)
        libraryFlat = true
        libraryHealthFocus = LibraryHealthFocus(kind: group.kind, ids: group.modelIds,
                                                note: group.kind == .looksSame ? "mac.lh_mirror_note" : nil)
        libraryHealthOpen = false
        fileSelection = select ? Set(visibleFiles.map(\.id)) : []
    }

    /// "Remove from Library…" for the files that are gone: the group on the
    /// grid, then the library's own delete question over EXACTLY those
    /// models. Returns any the grid could not show — then nothing is asked
    /// (`askToDeleteFromLibrary` refuses), and the shop is told how many.
    @discardableResult
    func askToRemoveHealthGroup(_ group: LibraryHealth.Group) -> [LibraryFile] {
        guard group.kind == .missing, permitted("inventory", "delete") else { return [] }
        let chosen = healthFiles(group)
        guard !chosen.isEmpty else { return [] }
        showHealthGroup(group)
        return askToDeleteFromLibrary(chosen)
    }

    /// "Measure": each model's own file read again — hashed, measured, its
    /// slicer's figures and colours read — the way a model brought down is
    /// (`readDownloaded`), and all of them written in ONE change to the book
    /// (`applyDownloaded`, which never replaces what the shop wrote). Only
    /// files on this Mac: a drive's online placeholder is never downloaded
    /// from here (that is Measure online, which asks first).
    func measureHealthModels(_ chosen: [LibraryFile]) async {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, StoreLock.weOwnIt(build), let engine, let roots = libraryRoots else {
            libraryHealthNote = words.callIt("mac.move_sample"); return
        }
        guard !libraryHealthBusy, !chosen.isEmpty else { return }
        libraryHealthBusy = true
        defer { libraryHealthBusy = false }
        libraryHealthNote = nil
        let isOnline = linkedIsOnline
        var reads: [String: DownloadedRead] = [:]
        var skipped = 0
        for file in chosen {
            // A member of a compressed file: its copy, extracted if the
            // cache had let it go. A locked one has nothing to measure.
            if file.inArchive { await materialise(file) }
            let found = await PinWork.run { () -> URL? in
                guard let url = Shop.modelFile(for: file, roots: roots.roots) else { return nil }
                return file.isLinked && isOnline(url) ? nil : url
            }
            guard let url = found else { skipped += 1; continue }
            // A linked model's picture goes in its vault folder, never the shop's.
            let pictures = file.isLinked ? Self.vaultFolder(file.id, roots: roots) : nil
            if let pictures { try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true) }
            if let read = try? await Self.readDownloaded(file: url, pictures: pictures, engine: engine) {
                reads[file.id] = read
            } else {
                skipped += 1
            }
        }
        let measured = reads.values.count { $0.key != nil }
        skipped += reads.count - measured
        if !reads.isEmpty {
            let batch = reads
            do {
                _ = try await StoreWriter.updateOffMain(storeURL: build.storeURL, owns: { StoreLock.weOwnIt(build) },
                                                    whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }) { book in
                    Shop.applyDownloaded(batch, to: &book)
                }
            } catch {
                libraryHealthNote = said(error)
                return
            }
            await load(source)
        }
        libraryHealthNote = words.callIt("mac.measure_online_done",
                                         ["n": .number(Double(measured)), "skipped": .number(Double(skipped))])
        await checkLibraryHealth()
    }

    /// "Measure online models…", once the shop has said yes to the download.
    func measureOnlineFromHealth() async {
        await measureOnlineModels()
        libraryHealthNote = libraryMoveProblem ?? libraryMoveNote
        await checkLibraryHealth()
    }

    /// Is this file the one the record was made from? The bytes decide when
    /// the record has a hash; a record with none cannot say, and takes it.
    nonisolated static func locatedFileMatches(_ file: LibraryFile, hash: String?) -> Bool {
        guard let want = file.contentHash, !want.isEmpty else { return true }
        return hash == want
    }

    /// The same, for a member: the ARCHIVE's bytes decide (`archiveHash`).
    nonisolated static func locatedArchiveMatches(_ file: LibraryFile, hash: String?) -> Bool {
        guard let want = file.archiveHash, !want.isEmpty else { return true }
        return hash == want
    }

    /// "Locate…": the shop points at where the file is now. A linked model's
    /// path is changed on its record; a vault model's file is COPIED back
    /// into its own folder (the original is left where it was). Refused when
    /// the bytes are not the record's — a different file under the same name
    /// would quietly change what past jobs were printed from.
    func locateMissing(_ file: LibraryFile) async {
        guard permitted("inventory", "edit") else { return }
        guard source.build != nil, let roots = libraryRoots else {
            libraryHealthNote = words.callIt("mac.move_sample"); return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = words.callIt("mac.lh_locate_prompt",
                                     ["name": .string(file.archivePath.map { ($0 as NSString).lastPathComponent } ?? file.title)])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let hash = await PinWork.run { try? LibraryImport.contentHash(of: url) } ?? nil
        guard file.inArchive ? Self.locatedArchiveMatches(file, hash: hash) : Self.locatedFileMatches(file, hash: hash) else {
            libraryHealthNote = words.callIt("mac.lh_locate_wrong", ["name": .string(file.title)])
            return
        }
        // A LOCKED member has no archive hash to compare: the file chosen must
        // at least be a compressed file that lists this member — not any
        // file at all, every member of the archive re-pointed at it.
        if file.inArchive, (file.archiveHash ?? "").isEmpty {
            let member = file.archiveMember ?? ""
            let holds = await PinWork.run {
                ArchiveFolder.kind(of: url.lastPathComponent) != nil
                    && ((try? ArchiveMembers.list(url))?.contains { $0.path == member } ?? false)
            }
            guard holds else {
                libraryHealthNote = words.callIt("mac.lh_locate_wrong", ["name": .string(file.title)])
                return
            }
        }
        if let gone = file.archivePath {
            // A member's ARCHIVE was moved: every model it holds follows it,
            // the archive's own bytes deciding (`archiveHash`).
            let path = url.standardizedFileURL.path
            let ids = files.filter { $0.archivePath == gone }.map(\.id)
            editFiles(Set(ids), named: words.callIt("mac.lh_locate")) { record in
                record["externalPath"] = .string(path)
            }
            await settleLibraryWrites()
        } else if file.isLinked {
            let path = url.standardizedFileURL.path
            editFiles([file.id], named: words.callIt("mac.lh_locate")) { record in
                record["externalPath"] = .string(path)
            }
            await settleLibraryWrites()
        } else {
            let name = file.sourceFile?.filename.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
            let dir = URL(fileURLWithPath: roots.primary).appending(path: LibraryLocation.itemDirName(file.id))
            let copied = await PinWork.run { () -> Bool in
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let target = dir.appending(path: name)
                    guard !FileManager.default.fileExists(atPath: target.path) else { return true }
                    try FileManager.default.copyItem(at: url, to: target)
                    return true
                } catch { return false }
            }
            guard copied else { libraryHealthNote = words.callIt("mac.lh_locate_failed"); return }
        }
        libraryHealthNote = words.callIt("mac.lh_locate_done", ["name": .string(file.title)])
        await checkLibraryHealth()
    }

    /// "Open" on a product whose model is gone: its own sheet, where a part
    /// can be pointed at another file or taken out.
    func openHealthProduct(_ id: String) async {
        editingProduct = await productForEditing(id)
    }

    /// A product's name, for the page.
    func healthProductName(_ id: String) -> String {
        Self.healthProducts(productRows).first { $0.id == id }?.name ?? id
    }
}

/// Whether the place a library path lives is there to be asked, each folder
/// asked once per check (`Shop.healthPresence`).
struct HealthReach {
    let linkedRoots: [String]
    private var known: [String: Bool] = [:]

    init(linkedRoots: [String]) {
        self.linkedRoots = linkedRoots.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    /// A folder that exists and holds something. An EMPTY one is a mount
    /// point with nothing mounted on it, or a drive's folder with its drive
    /// signed out — never a reason to call what was in it gone.
    mutating func folderIsThere(_ path: String) -> Bool {
        if let k = known[path] { return k }
        var dir: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
            && !((try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty ?? true)
        known[path] = there
        return there
    }

    /// The linked folder the path is under (the deepest), and the
    /// `/Volumes/<name>` drive it is on, are both there.
    mutating func isReachable(_ path: String) -> Bool {
        let under = linkedRoots.filter { path.hasPrefix($0 == "/" ? $0 : $0 + "/") }.max { $0.count < $1.count }
        if let under, !folderIsThere(under) { return false }
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes", !folderIsThere("/Volumes/\(parts[1])") { return false }
        return true
    }
}
