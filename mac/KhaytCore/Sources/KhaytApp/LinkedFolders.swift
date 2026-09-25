import Foundation
import KhaytCore

/// Folders the library INDEXES WHERE THEY ARE — a NAS, an external drive, a
/// Dropbox folder — instead of copying their models into the vault.
///
/// Asked for by the shop (Sep 2026) after looking at LayerMate, which works
/// this way. Kept in `settings.printLibrary.linked` (a list of paths).
///
/// ── THE FILES ARE THE SHOP'S, AND STAY WHERE THEY ARE ──────────────────
///
/// A linked model's record points at its file (`externalPath`); only its
/// picture goes into the vault. Nothing here copies, moves or removes a
/// linked file: deleting the model deletes the RECORD (the vault folder holds
/// only the picture), unlinking a folder removes its records, and online
/// storage and library moves walk the vault and never see a linked file.
extension Shop {

    /// The folders linked on this book.
    var linkedFolders: [String] {
        guard case .object(let l)? = settingsDict["printLibrary"], case .array(let rows)? = l["linked"] else { return [] }
        return rows.compactMap { if case .string(let s) = $0, !s.isEmpty { s } else { nil } }
    }

    private func writeLinked(_ paths: [String]) throws {
        guard let build = source.build else { throw CocoaError(.fileWriteNoPermission) }
        try StoreWriter.update(build) { root in
            var settings = Self.settings(root)
            var library: [String: JSONValue] = [:]
            if case .object(let l)? = settings["printLibrary"] { library = l }
            library["linked"] = .array(paths.map(JSONValue.string))
            settings["printLibrary"] = .object(library)
            root["settings"] = .object(settings)
        }
    }

    /// Link a folder and index what is in it.
    func linkFolder(_ url: URL) async {
        libraryMoveProblem = nil
        let path = url.standardizedFileURL.path
        guard !linkedFolders.contains(path) else { await rescanLinkedFolders(); return }
        // Not inside the library's own folders, nor around them: those are
        // the vault, and linking them would index every model twice.
        if let roots = libraryRoots, roots.roots.contains(where: {
            LibraryMove.under(path, $0) || LibraryMove.under($0, path)
        }) {
            libraryMoveProblem = words.callIt("mac.linked_not_vault"); return
        }
        do { try writeLinked(linkedFolders + [path]) }
        catch { libraryMoveProblem = String(describing: error); return }
        await load(source)
        await rescanLinkedFolders()
    }

    /// Stop indexing a folder. Its models leave the library; its FILES are
    /// not touched.
    func unlinkFolder(_ path: String) async {
        libraryMoveProblem = nil
        guard let build = source.build else { return }
        do {
            try writeLinked(linkedFolders.filter { $0 != path })
            let gone = Set(files.filter { $0.isLinked && LibraryMove.under($0.externalPath ?? "", path) }.map(\.id))
            try StoreWriter.update(build) { root in
                var rows = Self.rows(root, "printFiles")
                rows.removeAll { Self.recordId($0).map(gone.contains) ?? false }
                root["printFiles"] = .array(rows)
            }
            // The vault folders of those records hold only their pictures.
            if let roots = libraryRoots {
                for id in gone {
                    let dir = URL(fileURLWithPath: roots.primary).appending(path: LibraryLocation.itemDirName(id))
                    let inside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                    if inside.allSatisfy({ ["png", "jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) }) {
                        try? Self.trash(dir)
                    }
                }
            }
            await load(source)
            libraryMoveNote = words.callIt("mac.linked_unlinked", ["n": .number(Double(gone.count))])
        } catch {
            libraryMoveProblem = String(describing: error)
        }
    }

    /// Index what is new in every linked folder, in place. A file already
    /// indexed (by its path) is left alone; one whose bytes the library
    /// already holds is counted as a duplicate, as an import would.
    func rescanLinkedFolders() async {
        guard let build = source.build, StoreLock.weOwnIt(build), let roots = libraryRoots, let engine else { return }
        let folders = linkedFolders.filter { FileManager.default.fileExists(atPath: $0) }
        guard !folders.isEmpty, !libraryMoveBusy else { return }
        libraryMoveBusy = true
        defer { libraryMoveBusy = false; libraryMoveProgress = nil }
        let known = Set(files.compactMap(\.externalPath))
        let vaults = roots.roots + [roots.primary]
        let found = await Task.detached {
            Shop.modelsUnder(folders.map { URL(fileURLWithPath: $0) }, skippingAll: vaults)
        }.value
        let fresh = found.filter { !known.contains($0.url.standardizedFileURL.path) }
        guard !fresh.isEmpty else { libraryMoveNote = words.callIt("mac.linked_up_to_date"); return }
        let report = await LibraryImport.addMany(
            fresh, storeURL: build.storeURL, libraryRoot: URL(fileURLWithPath: roots.primary),
            knownHashes: Set(files.compactMap(\.contentHash)),
            nameOfExisting: { [files] hash in files.first { $0.contentHash == hash }?.title },
            engine: engine, keepOriginal: true, inPlace: true,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            progress: { [weak self] done, total, url in
                self?.libraryMoveProgress = (done, total, url.lastPathComponent)
            })
        await load(source)
        libraryMoveNote = words.callIt("mac.linked_scanned", ["n": .number(Double(report.moved)),
                                                              "same": .number(Double(report.duplicates))])
        if !report.failures.isEmpty {
            libraryMoveProblem = report.failures.prefix(3).joined(separator: "\n")
        }
    }
}
