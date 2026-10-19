import Foundation
import KhaytCore

/// Measuring the linked models a cloud drive keeps online only.
///
/// ── WHY A BUTTON AND NOT A PASS ON LOAD ───────────────────────────────────
///
/// A linked drive is indexed from its listing (`LinkedCloud`): a placeholder's
/// name and size are free, its bytes are a download. So a model the shop
/// never opened has no `geometryKey`, and with no key there is no price — on
/// the Mac's calculator, or on the phone (`GET /api/library/{id}/estimate`).
/// On the book this was written against that was 6,521 of 10,176 models, all
/// in one Google Drive, 103 GB of them. Measuring them is downloading them,
/// which the shop chose against when it left the drive online — so this runs
/// when the shop presses it (Settings → Library), never by itself, and says
/// how much it will fetch before it starts (Oct 2026: the shop asked for the
/// button over a background download).
///
/// ── WHAT IT LEAVES BEHIND ─────────────────────────────────────────────────
///
/// One model at a time: read (which is what makes the provider fetch it),
/// measured, hashed and pictured the way a model brought down by hand is
/// (`readDownloaded`), then handed back to the drive (`evictUbiquitousItem`,
/// which Google Drive's File Provider honours) when it was online only before
/// — so the disk holds one model at a time, not the drive. Written to the
/// book a batch at a time, because one write per model is the whole 16 MB
/// book rewritten six thousand times. Stop keeps every batch already written,
/// and a model that was read is not read again: its record has a hash now.
enum OnlineMeasure {
    static let measurable: Set<String> = ["stl", "3mf", "obj"]
    /// Models read between writes to the book.
    static let batch = 25

    struct Due: Equatable, Sendable {
        let id: String
        let path: String
        let name: String
        let size: Int
    }

    /// Linked models never read: no measurement, and no hash — a record that
    /// was read and still has no key is one this reader cannot measure, and
    /// fetching it again would not change that. Only files under a folder
    /// this book links: `externalPath` arrives by sync, and a path anywhere
    /// else on this Mac is not read unasked (as `fillNowLocal`).
    nonisolated static func due(_ files: [LibraryFile], linked: [String]) -> [Due] {
        files.compactMap { file in
            guard !file.isArchived, (file.geometryKey ?? "").isEmpty, (file.contentHash ?? "").isEmpty,
                  let path = file.externalPath, !path.isEmpty,
                  measurable.contains(Shop.libraryExt(file)),
                  linked.contains(where: { !$0.isEmpty && LibraryMove.under(path, $0) }) else { return nil }
            return Due(id: file.id, path: path, name: file.title, size: Int(file.sourceFile?.size ?? 0))
        }
    }
}

extension Shop {
    /// What the button offers — how many models, and how much it would
    /// fetch — worked out again into `onlineUnmeasured`. Off the main actor:
    /// it looks at every record against every linked folder, ten thousand of
    /// them on a linked drive, and Settings asks after every load.
    func countOnlineUnmeasured() async {
        let files = self.files, linked = linkedFolders
        onlineUnmeasured = await PinWork.run {
            let due = OnlineMeasure.due(files, linked: linked)
            return (due.count, due.reduce(0) { $0 + $1.size })
        }
    }

    /// "Measure online models": see `OnlineMeasure`.
    func measureOnlineModels() async {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, StoreLock.weOwnIt(build), let roots = libraryRoots, let engine,
              !libraryMoveBusy else { return }
        let due = OnlineMeasure.due(files, linked: linkedFolders)
        libraryMoveProblem = nil
        libraryMoveNote = nil
        guard !due.isEmpty else {
            libraryMoveNote = words.callIt("mac.measure_online_none")
            return
        }
        libraryMoveBusy = true
        let stop = ScanStop()
        libraryScanStop = stop
        defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }
        let owns: @Sendable () -> Bool = { StoreLock.weOwnIt(build) }
        let who: @Sendable () -> String? = { StoreLock.describe(StoreLock.verdict(for: build)) }
        let isOnline = linkedIsOnline, evict = linkedEvict
        var bookAt = Self.bookStamp(build.storeURL)
        var pending: [String: DownloadedRead] = [:]
        // Counted once their batch is in the book: a batch the book refused
        // was measured for nothing.
        var measured = 0, skipped = 0, pendingMeasured = 0, pendingSkipped = 0
        let progress = ScanProgress()

        // One batch to the book, then the library reloaded, so the models
        // just measured price on the Mac and the phone while the rest go on.
        func flush() async -> Bool {
            guard !pending.isEmpty else { return true }
            let batch = pending
            pending = [:]
            do {
                // lock: callers — measureOnlineModels
                try await StoreWriter.updateOffMain(storeURL: build.storeURL, owns: owns, whoHasIt: who) { book in
                    Shop.applyDownloaded(batch, to: &book)
                }
            } catch {
                libraryMoveProblem = String(describing: error)
                return false
            }
            measured += pendingMeasured; skipped += pendingSkipped
            pendingMeasured = 0; pendingSkipped = 0
            await reloadIfWritten(since: &bookAt)
            return true
        }

        for (i, item) in due.enumerated() {
            if stop.isStopped || Task.isCancelled { break }
            if progress.due(i, of: due.count) { libraryMoveProgress = (i, due.count, item.name) }
            let url = URL(fileURLWithPath: item.path)
            let wasOnline = await PinWork.run { FileManager.default.fileExists(atPath: url.path) ? isOnline(url) : nil }
            guard let wasOnline else { skipped += 1; continue }
            let pictures = Self.vaultFolder(item.id, roots: roots)
            try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
            if let read = try? await Self.readDownloaded(file: url, pictures: pictures, engine: engine) {
                pending[item.id] = read
                if read.key == nil { pendingSkipped += 1 } else { pendingMeasured += 1 }
            } else {
                skipped += 1
            }
            if wasOnline { await PinWork.run { evict(url) } }
            // A refused write ends the pass with the book's reason on screen
            // (`libraryMoveProblem`), not a count of models it did not keep.
            if pending.count >= OnlineMeasure.batch, await !flush() { return }
        }
        guard await flush() else { return }
        let stopped = stop.isStopped || Task.isCancelled
        libraryMoveNote = words.callIt(stopped ? "mac.measure_online_stopped" : "mac.measure_online_done",
                                       ["n": .number(Double(measured)), "skipped": .number(Double(skipped))])
    }
}
