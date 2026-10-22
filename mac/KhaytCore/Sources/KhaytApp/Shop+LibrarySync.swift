import Foundation
import KhaytCore

/// The cloud state index, as the library uses it: opened with the book, kept
/// up to date where this app moves a model's bytes, and read by the tiles, the
/// Show menu and the inspector. See `LibrarySyncIndex`.
extension Shop {

    /// Open this library's index — or, the first time, build it from the
    /// sidecars — and bring it level with the book. Off the main actor; the
    /// tiles draw without badges until it lands.
    ///
    /// Only for a real book: the sample has no library folder to describe.
    func openSyncIndex() {
        guard source.isReal, let roots = libraryRoots else {
            syncIndex = nil
            return
        }
        libraryHasRemote = CloudLibrary.remoteInUse(settingsDict) != .none
        let probes = files.map { LibrarySyncIndex.Probe(id: $0.id, externalPath: $0.externalPath) }
        let primary = roots.primary, all = roots.roots
        let current = syncIndex?.root == primary ? syncIndex : nil
        let previous = syncIndexTask
        syncIndexTask = Task { [weak self] in
            await previous?.value
            let (index, changed) = await PinWork.run { () -> (LibrarySyncIndex, Bool) in
                if let open = current ?? LibrarySyncIndex.open(primary: primary) {
                    return (open, open.reconcile(roots: all, models: probes))
                }
                return (LibrarySyncIndex.migrate(primary: primary, roots: all, models: probes), true)
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

    /// Record where models' bytes are now.
    func recordSync(_ changes: [String: LibrarySyncIndex.State]) {
        guard let index = syncIndex, !changes.isEmpty else { return }
        index.set(changes)
        syncIndexChanged()
    }

    /// The book's model id for a vault folder name.
    func modelIdsByFolder() -> [String: String] {
        Dictionary(files.map { (LibraryLocation.itemDirName($0.id), $0.id) }, uniquingKeysWith: { a, _ in a })
    }

    /// Where this model's bytes are, from the index alone — no disk. Nil
    /// before the index is open.
    func storageState(for file: LibraryFile) -> LibrarySyncIndex.State? {
        _ = librarySyncRevision
        return syncIndex?.state(file.id)
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

    /// Free up this one model's space: prove it is online, then remove the
    /// local copy — `moveOut`, the same verified path "Free up space now"
    /// takes for many. A vault model only: a linked model is in the shop's own
    /// folder, which this app never deletes from.
    func freeUpSpace(model file: LibraryFile) async {
        cloudLibraryProblem = nil
        cloudLibraryNote = nil
        // Deleting this Mac's copy is the storage setting's business, as the
        // whole-library pass is (the staff lock).
        guard permitted("settings", "edit") else { cloudLibraryProblem = moveProblem; return }
        guard !file.isLinked, let url = modelFile(for: file) else { return }
        guard let engine, let config = await cloudConfig() else {
            cloudLibraryProblem = words.callIt("mac.cloudlib_not_set_up"); return
        }
        cloudLibraryBusy = true
        defer { cloudLibraryBusy = false }
        let key = S3.objectKey(prefix: config.prefix, id: LibraryLocation.itemDirName(file.id),
                               filename: url.lastPathComponent)
        do {
            let size = try await moveOut(url, key: key, config: config, engine: engine)
            syncIndex?.setKeep(file.id, false)
            recordSync([file.id: .online])
            let human = (try? await engine.formatBytes(Double(size))) ?? ""
            cloudLibraryNote = words.callIt("mac.storage_freed_one", ["size": .string(human)])
        } catch {
            cloudLibraryProblem = url.lastPathComponent + ": " + cloudSay(error)
        }
        await load(source)
    }

    /// Keep this model on this Mac — Free up space then never moves it out —
    /// bringing it back first when it is online only. Off again, it is left
    /// where it is.
    func keepOnThisMac(_ file: LibraryFile, _ keep: Bool) async {
        guard let index = syncIndex else { return }
        if keep, storageState(for: file) == .online || isInCloudOnly(file) {
            await bringBack(file)
            // Not back (the bucket refused, the drive is offline): not kept,
            // and `bringBack` has said why.
            guard let now = libraryFile(id: file.id), !isInCloudOnly(now) else { return }
        }
        index.setKeep(file.id, keep)
        syncIndexChanged()
    }
}
