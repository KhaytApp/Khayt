import Foundation
import AppKit
import KhaytCore

/// The sync paths' half of `SyncSafety.swift`: a restore held against the
/// cloud, a baseline the shared rule can measure edits against, and a copy of
/// everything a merge takes, with the window saying so.
extension Shop {

    // MARK: - The restore, held

    /// Make a pending restore win over what the cloud holds, before anything
    /// is sent or merged. A no-op when there is no restore waiting.
    ///
    /// `recordingDeletes: false`: moving a restored record to a new id is not
    /// a delete of the old one — the cloud's tombstone already says that — and
    /// the stamping here is the restore's, not an edit's.
    func holdRestore(build: StoreReader.Build, cloud: [String: JSONValue]) async throws {
        guard let pending = RestoreGuard.pending(for: build.storeURL) else { return }
        let restored = Set(pending.records)
        try await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            recordingDeletes: false
        ) { root in
            root = RestoreGuard.prevail(root, over: cloud, restored: restored)
        }
    }

    // MARK: - The baseline

    /// Hand the shared rule what this Mac last agreed with the cloud on, so a
    /// merge can tell an edit made here from a copy that is simply older.
    func installSyncBaseline(build: StoreReader.Build, shopId: String, engine: KhaytEngine) async {
        let baseline = SyncBaseline.load(for: build.storeURL, shopId: shopId)
        _ = try? await engine.markSynced(baseline.revs)
    }

    /// After an exchange that succeeded: what the two copies now agree on.
    func noteSyncAgreement(build: StoreReader.Build, shopId: String, engine: KhaytEngine,
                           book: [String: JSONValue], cloud: [String: JSONValue]) async {
        let next = SyncBaseline.load(for: build.storeURL, shopId: shopId)
            .agreeing(book: book, cloud: cloud)
        next.save(for: build.storeURL)
        _ = try? await engine.markSynced(next.revs)
    }

    // MARK: - What a merge took

    /// Merge the cloud into `root`, keeping a copy of everything the merge
    /// removes or overwrites-after-an-edit in `sync-conflicts/` FIRST. The one
    /// merge both the button and automatic sync run.
    static func mergeKeepingLosses(_ root: inout [String: JSONValue], cloud: [String: JSONValue],
                                   engine: KhaytEngine, keepAt file: URL)
    async throws -> (merged: KhaytEngine.Merged, losses: [SyncLoss]) {
        let before = root
        let merged = try await engine.mergeFromCloud(local: root, server: cloud)
        let losses = SyncLosses.compute(before: before, after: merged.store, conflicts: merged.conflicts)
        // Before the book is replaced, and fatal to the merge if it fails: a
        // merge that cannot keep what it is about to take does not go ahead.
        try SyncLosses.keep(losses, at: file)
        root = merged.store
        return (merged, losses)
    }

    /// Put the window's notice up, or add to the one already there.
    func announceSyncLosses(_ losses: [SyncLoss], file: URL) {
        guard !losses.isEmpty else { return }
        syncLossNotice = (syncLossNotice ?? SyncLossNotice(files: [], losses: []))
            .adding(losses, file: file)
    }

    /// Put one kept record back in the book.
    func putBackSyncLoss(_ loss: SyncLoss) async {
        moveProblem = nil
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                SyncLosses.putBack(loss, into: &root)
            }
            syncLossesPutBack.insert(loss.id)
            await load(source)
        } catch {
            moveProblem = words.callIt("mac.sync_put_back_failed") + " " + String(describing: error)
        }
    }

    /// Show the kept copies on disk.
    func revealSyncLosses() {
        guard let build = source.build else { return }
        let files = syncLossNotice?.files ?? []
        if files.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([SyncLosses.directory(for: build.storeURL)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    func dismissSyncLosses() {
        syncLossNotice = nil
        syncLossesPutBack = []
        reviewingSyncLosses = false
    }
}
