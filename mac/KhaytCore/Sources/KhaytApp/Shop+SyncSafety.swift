import Foundation
import AppKit
import KhaytCore

/// The sync paths' half of `SyncSafety.swift`: a restore held against the
/// cloud, a baseline the shared rule can measure edits against, and a copy of
/// everything a merge takes, with the window saying so.
extension Shop {

    // MARK: - The restore, held

    /// Make a pending restore win over what the cloud holds, before anything
    /// is sent or merged. Without this the whole-book merge deleted every
    /// restored record the cloud had tombstoned and replaced every one it held
    /// at a higher rev, and the delta outbox never sent a restored record the
    /// cloud had deleted. Returns whether a restore was pending.
    ///
    /// `recordingDeletes: false`: moving a restored record to a new id is not
    /// a delete of the old one — the cloud's tombstone already says that — and
    /// the stamping here is the restore's, not an edit's.
    ///
    /// Bounded three ways (pre-alpha.58 review): it prevails only over cloud
    /// copies at or below the rev it first saw (`RestoreGuard.hold`), every
    /// cloud copy it overrides is kept in `sync-conflicts/` and announced like
    /// any other sync loss, and a marker older than `RestoreGuard.lifetime` is
    /// dropped with a notice instead of overriding other devices for ever.
    @discardableResult
    func holdRestore(build: StoreReader.Build, cloud: [String: JSONValue]) async throws -> Bool {
        guard var pending = liveRestoreMarker(build) else { return false }
        let keepAt = SyncLosses.fileURL(for: build.storeURL)
        var losses: [SyncLoss] = []
        try await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            recordingDeletes: false
        ) { root in
            var held = pending
            let out = RestoreGuard.hold(root, over: cloud, pending: &held)
            try SyncLosses.keep(out.overridden, at: keepAt)
            losses = out.overridden
            pending = held
            root = out.book
        }
        try? RestoreGuard.save(pending, for: build.storeURL)
        announceSyncLosses(losses, file: keepAt)
        return true
    }

    /// The restore marker if it is still live; an expired one is dropped and
    /// the window says the restore is no longer being held.
    func liveRestoreMarker(_ build: StoreReader.Build) -> RestoreGuard.Pending? {
        let taken = RestoreGuard.take(for: build.storeURL)
        if taken.expired { restoreHoldNote = words.callIt("mac.restore_hold_expired") }
        return taken.pending
    }

    /// Nothing to send: the cloud already holds everything here, a pending
    /// restore included, so the restore is done and the baseline moves up.
    func cloudAgrees(build: StoreReader.Build, shopId: String, engine: KhaytEngine,
                     book: [String: JSONValue], cloud: [String: JSONValue], restored: Bool) async {
        if restored { RestoreGuard.clear(for: build.storeURL) }
        await noteSyncAgreement(build: build, shopId: shopId, engine: engine, book: book, cloud: cloud)
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

    /// What a merge took from `before`, kept in `sync-conflicts/` FIRST — called
    /// inside the write, before the merged book replaces this one, by both the
    /// button and automatic sync. Throws, and the merge does not go ahead, when
    /// the copies cannot be written.
    static func keepLosses(before: [String: JSONValue], merged: KhaytEngine.Merged,
                           at file: URL) throws -> [SyncLoss] {
        let losses = SyncLosses.compute(before: before, after: merged.store, conflicts: merged.conflicts)
        try SyncLosses.keep(losses, at: file)
        return losses
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
            moveProblem = words.callIt("mac.losses_put_back_failed") + " " + String(describing: error)
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
