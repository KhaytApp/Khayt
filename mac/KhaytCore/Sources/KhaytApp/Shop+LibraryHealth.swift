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
    nonisolated static func healthPresence(_ files: [LibraryFile], roots: [String]?, online: Set<String>,
                                           linkedOnline: @Sendable (URL) -> Bool) -> [String: LibraryHealth.Presence] {
        var out: [String: LibraryHealth.Presence] = [:]
        for file in files {
            if file.isWebOnly { out[file.id] = .web; continue }
            if online.contains(file.id) { out[file.id] = .online; continue }
            if let path = file.externalPath, !path.isEmpty {
                guard FileManager.default.fileExists(atPath: path) else { out[file.id] = .missing; continue }
                out[file.id] = linkedOnline(URL(fileURLWithPath: path)) ? .online : .here
                continue
            }
            guard let roots, !roots.isEmpty else { out[file.id] = .unknown; continue }
            out[file.id] = LibraryLocation.directory(for: file.id, roots: roots) == nil ? .missing : .here
        }
        return out
    }

    /// A library record as the rule reads it.
    nonisolated static func healthModel(_ file: LibraryFile, presence: LibraryHealth.Presence) -> LibraryHealth.Model {
        let sliced = LibraryFacts.sliced(file)
        return LibraryHealth.Model(id: file.id, title: file.title, presence: presence,
                                   contentHash: file.contentHash, geometryKey: file.geometryKey,
                                   slicedMinutes: sliced.minutes, slicedGrams: sliced.grams,
                                   tags: file.tags ?? [], category: file.category, archived: file.isArchived)
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
        let presence = await PinWork.run {
            pretend ?? Shop.healthPresence(files, roots: roots, online: online, linkedOnline: linkedOnline)
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
        libraryHealthFocus = LibraryHealthFocus(kind: group.kind, ids: group.modelIds)
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
        panel.message = words.callIt("mac.lh_locate_prompt", ["name": .string(file.title)])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let hash = await PinWork.run { try? LibraryImport.contentHash(of: url) } ?? nil
        guard Self.locatedFileMatches(file, hash: hash) else {
            libraryHealthNote = words.callIt("mac.lh_locate_wrong", ["name": .string(file.title)])
            return
        }
        if file.isLinked {
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
