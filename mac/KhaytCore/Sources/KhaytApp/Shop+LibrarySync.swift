import Foundation
import KhaytCore

/// The cloud state index, as the library uses it: opened with the book, kept
/// up to date where this app moves a model's bytes, and read by the tiles, the
/// Show menu and the inspector. See `LibrarySyncIndex`.
extension Shop {

    typealias FileStates = [String: [String: LibrarySyncIndex.FileEntry]]

    /// Where the library has its online copy, read again whenever the
    /// settings change (`settingsValue`): a tile's "on this Mac only" and a
    /// "backed up" proved on a remote that is no longer the one in use both
    /// turn on it.
    func refreshLibraryRemote() {
        let settings = settingsDict
        let has = CloudLibrary.remoteInUse(settings) != .none
        if has != libraryHasRemote { libraryHasRemote = has }
        guard let driveKey = CloudLibrary.driveSettingsKey(settings) else {
            let id = CloudLibrary.remoteIdentity(settings)
            if id != libraryRemoteId { libraryRemoteId = id }
            return
        }
        // Drive: the account is in the sign-in, which has to be opened.
        if let held = driveIdentityCache, held.key == driveKey {
            if libraryRemoteId != held.id { libraryRemoteId = held.id }
            return
        }
        if libraryRemoteId != nil { libraryRemoteId = nil }
        let build = source.build
        Task { [weak self] in
            guard let d = await CloudLibrary.libraryDrive(settings: settings, build: build) else { return }
            let id = CloudLibrary.driveIdentity(d.config, folder: CloudLibrary.driveFolder(settings))
            guard let self, CloudLibrary.driveSettingsKey(self.settingsDict) == driveKey else { return }
            self.driveIdentityCache = (driveKey, id)
            if self.libraryRemoteId != id {
                self.libraryRemoteId = id
                self.syncIndexChanged()
            }
        }
    }

    /// Open this library's index — or, the first time, build it from the
    /// sidecars — and bring it level with the book. Off the main actor; the
    /// tiles draw without badges until it lands. Called once the book's
    /// settings are on screen, so the remote it is read against is this
    /// book's.
    ///
    /// Only for a real book: the sample has no library folder to describe.
    func openSyncIndex() {
        guard source.isReal, let roots = libraryRoots, let folder = source.build?.storeURL.deletingLastPathComponent()
        else {
            syncIndex = nil
            return
        }
        refreshLibraryRemote()
        let probes = files.map { LibrarySyncIndex.Probe(id: $0.id, externalPath: $0.externalPath) }
        let primary = roots.primary, all = roots.roots
        let current = syncIndex?.root == primary && syncIndex?.url.deletingLastPathComponent() == folder ? syncIndex : nil
        let previous = syncIndexTask
        syncIndexTask = Task { [weak self] in
            await previous?.value
            let (index, changed) = await PinWork.run { () -> (LibrarySyncIndex, Bool) in
                if let open = current ?? LibrarySyncIndex.open(primary: primary, folder: folder) {
                    return (open, open.reconcile(roots: all, models: probes))
                }
                let keep = LibrarySyncIndex.takeLegacy(primary: primary, folder: folder, ids: Set(probes.map(\.id)))
                return (LibrarySyncIndex.migrate(primary: primary, folder: folder, roots: all,
                                                 models: probes, keep: keep), true)
            }
            guard let self else { return }
            let fresh = self.syncIndex !== index
            self.syncIndex = index
            if fresh || changed { self.syncIndexChanged() }
        }
    }

    /// Wait for the index to be open — for a test, and for anything that must
    /// read it right after a load.
    func settleSyncIndex() async {
        while let task = syncIndexTask {
            await task.value
            if syncIndexTask == task { syncIndexTask = nil }
        }
    }

    /// The index moved: redraw the badges, and recount the Show menu.
    func syncIndexChanged() {
        librarySyncRevision &+= 1
        if libraryStorage != nil { pruneSelectionToVisible() }
        recountLibrarySoon()
    }

    /// Record files' states — a whole pass's at once: one write, one recount.
    func recordSync(_ changes: FileStates) {
        guard let index = syncIndex, !changes.isEmpty else { return }
        index.record(changes)
        syncIndexChanged()
    }

    /// `url` is now online only.
    nonisolated static func movedOut(_ url: URL, remote: String?) -> LibrarySyncIndex.FileEntry {
        .init(state: .online, remote: remote, at: StoreWriter.iso(Date()))
    }

    /// The book's model id for a vault folder name.
    func modelIdsByFolder() -> [String: String] {
        Dictionary(files.map { (LibraryLocation.itemDirName($0.id), $0.id) }, uniquingKeysWith: { a, _ in a })
    }

    /// Where this model's bytes are, from the index alone — no disk. Nil
    /// before the index is open.
    func storageState(for file: LibraryFile) -> LibrarySyncIndex.State? {
        _ = librarySyncRevision
        return syncIndex?.state(file.id, remote: libraryRemoteId)
    }

    /// What its tile says, if anything. "On this Mac only" only when the
    /// library has somewhere online to be: on a shop with no cloud it would be
    /// on every tile and mean nothing.
    func storageBadge(for file: LibraryFile) -> LibrarySyncIndex.State? {
        guard let state = storageState(for: file) else { return nil }
        if state == .local, !libraryHasRemote { return nil }
        return state
    }

    func isKeptOnThisMac(_ file: LibraryFile) -> Bool {
        _ = librarySyncRevision
        return syncIndex?.isKept(file.id) == true
    }

    /// Of these model ids, the ones set to Keep on this Mac.
    func keptAmong(_ ids: [String]) -> [String] {
        guard let index = syncIndex else { return [] }
        return ids.filter { index.isKept($0) }
    }

    /// The delete question's line for models set to Keep on This Mac, which
    /// Remove from This Mac would take off this Mac anyway.
    func deleteKeptLine(_ plan: LibraryDeletePlan) -> String? {
        let kept = keptAmong(plan.keptOnline)
        guard !kept.isEmpty else { return nil }
        return kept.count == 1
            ? words.callIt("mac.delete_kept_single")
            : words.callIt("mac.delete_kept_many", ["n": .number(Double(kept.count))])
    }

    /// The disk said something the index did not: put the index right from
    /// the folder, read by the SAME per-file rule (`LibrarySyncIndex.files`).
    ///
    /// Scheduled, never done in the call that noticed — that is a view's
    /// body — and once per model while one is pending. A correction that
    /// changes no file's state writes nothing and redraws nothing
    /// (`LibrarySyncIndex.correct`), so a reading the two agree on cannot
    /// start a loop.
    func scheduleSyncCorrection(_ file: LibraryFile) {
        guard let index = syncIndex, let roots = libraryRoots?.roots,
              !syncCorrecting.contains(file.id) else { return }
        syncCorrecting.insert(file.id)
        let probe = LibrarySyncIndex.Probe(id: file.id, externalPath: file.externalPath)
        Task { @MainActor [weak self] in
            let read = await PinWork.run { LibrarySyncIndex.read(probe, roots: roots, at: StoreWriter.iso(Date())) }
            let changed = index.correct(probe.id, found: read.files, dirMtimeMs: read.dirMtimeMs)
            guard let self else { return }
            self.syncCorrecting.remove(probe.id)
            if changed { self.syncIndexChanged() }
        }
    }

    /// The words for a state: the tile's VoiceOver label and the inspector's line.
    nonisolated static func storageWordKey(_ state: LibrarySyncIndex.State) -> String {
        switch state {
        case .local: "mac.storage_state_local"
        case .backedUp: "mac.storage_state_backed_up"
        case .online: "mac.storage_state_online"
        }
    }

    nonisolated static func storageSymbol(_ state: LibrarySyncIndex.State) -> String {
        switch state {
        case .local: "laptopcomputer"
        case .backedUp: "checkmark.icloud"
        case .online: "icloud"
        }
    }

    /// The tier plan's models, less the ones the shop asked to keep here.
    func notKept(_ candidates: [KhaytEngine.TierFile]) -> [KhaytEngine.TierFile] {
        guard let index = syncIndex else { return candidates }
        let ids = modelIdsByFolder()
        return candidates.filter { file in
            guard let id = ids[file.id ?? ""] else { return true }
            return !index.isKept(id)
        }
    }

    // MARK: - One model, by hand

    /// What freeing one model's space would move: its model files in its own
    /// folder under the PRIMARY root, listed with the guards the tier pass
    /// has (`CloudLibrary.files(in:)` — regular files only, no symlinks,
    /// nothing outside the root), each marked when an open job needs it.
    /// Nil when the model is not a vault model in the primary folder.
    func freeUpFiles(for file: LibraryFile, engine: KhaytEngine) async -> [KhaytEngine.TierFile]? {
        guard !file.isLinked, let roots = libraryRoots else { return nil }
        let primary = roots.primary
        let folder = URL(fileURLWithPath: primary).appending(path: LibraryLocation.itemDirName(file.id))
        let listed = await PinWork.run { CloudLibrary.files(in: folder, root: primary, includingMarkers: false) }
            .filter { f in
                let ext = (f.filename as NSString).pathExtension.lowercased()
                return LibraryImport.kinds.contains(ext) && !f.filename.contains(".part-")
            }
        guard !listed.isEmpty else { return nil }
        return (try? await CloudLibrary.annotated(CloudLibrary.ownFoldersOnly(listed, printFiles: fileRows,
                                                                              orders: orderRows),
                                                  engine: engine, printFiles: fileRows, orders: orderRows))
    }

    /// Free up this one model's space: prove each of its files is online,
    /// then remove the local copy — `moveOut`, the same verified path "Free
    /// up space now" takes for many, under the same guards.
    ///
    /// A model an open job needs is asked about first (`pendingFreeUp`);
    /// `anyway` is the answer. Nothing runs while another cloud pass is.
    func freeUpSpace(model file: LibraryFile, anyway: Bool = false) async {
        guard !cloudLibraryBusy else { cloudLibraryProblem = words.callIt("mac.storage_busy"); return }
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        // Deleting this Mac's copy is the storage setting's business, as the
        // whole-library pass is (the staff lock).
        guard permitted("settings", "edit") else { cloudLibraryProblem = moveProblem; return }
        guard let engine, let config = await cloudConfig() else {
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return
        }
        guard !cloudLibraryBusy else { return }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false }
        guard let moving = await freeUpFiles(for: file, engine: engine), !moving.isEmpty else {
            cloudLibraryProblem = words.callIt("mac.storage_free_not_here"); return
        }
        if !anyway, moving.contains(where: { $0.inUse == true }) {
            pendingFreeUp = file
            return
        }
        let remote = libraryRemoteId
        var moved: [String: LibrarySyncIndex.FileEntry] = [:]
        var freed = 0, failures: [String] = []
        for f in moving {
            let url = URL(fileURLWithPath: f.fullPath)
            let key = S3.objectKey(prefix: config.prefix, id: LibraryLocation.itemDirName(file.id),
                                   filename: f.filename)
            do {
                freed += try await moveOut(url, key: key, config: config, engine: engine)
                moved[f.filename] = Self.movedOut(url, remote: remote)
            } catch {
                failures.append(f.filename + ": " + cloudSay(error))
            }
        }
        if !moved.isEmpty {
            syncIndex?.setKeep(file.id, false)
            recordSync([file.id: moved])
            let human = (try? await engine.formatBytes(Double(freed))) ?? ""
            cloudLibraryNote = words.callIt("mac.storage_freed_one", ["size": .string(human)])
        }
        if !failures.isEmpty { cloudLibraryProblem = failures.prefix(3).joined(separator: "\n") }
        await load(source)
    }

    /// Keep this model on this Mac — Free up space then never moves it out —
    /// bringing it back first when it is online only. Off again, it is left
    /// where it is.
    func keepOnThisMac(_ file: LibraryFile, _ keep: Bool) async {
        guard let index = syncIndex else { return }
        if keep, storageState(for: file) == .online || isInCloudOnly(file) {
            guard !cloudLibraryBusy else { cloudLibraryProblem = words.callIt("mac.storage_busy"); return }
            await bringBack(file)
            // Not back (the bucket refused, the drive is offline): not kept,
            // and `bringBack` has said why.
            guard let now = libraryFile(id: file.id), !isInCloudOnly(now) else { return }
        }
        index.setKeep(file.id, keep)
        syncIndexChanged()
    }
}
