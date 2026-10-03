import Foundation
import KhaytCore

/// Which of the kept merges in `sync-conflicts/` the shop has dealt with.
///
/// ── WHY THE NOTICE IS REBUILT FROM DISK ───────────────────────────────────
///
/// The banner that offers back what a sync took was MEMORY ONLY: a relaunch,
/// or one press of its ✕, and the only way back to those records was gone —
/// while the copies sat untouched beside the backups, for nobody. Now the
/// copies on disk ARE the notice. Every load reads `sync-conflicts/` and puts
/// up whatever has not been reviewed, so quitting the app does not count as
/// having looked.
///
/// Reviewed is a decision the shop makes: closing the banner (asked first,
/// while anything in it has not been put back). Putting a record back is
/// remembered too, so the sheet does not offer it again after a relaunch.
/// Kept beside the copies, in `reviewed.json`, never in the book: it is about
/// this Mac's copies, and the book syncs.
struct SyncLossReview: Codable, Equatable {
    /// The kept-merge files (by name) the shop has closed.
    var reviewed: [String] = []
    /// The losses (by `SyncLoss.id`) already put back.
    var putBack: [String] = []

    static let fileName = "reviewed.json"

    static func url(for storeURL: URL) -> URL {
        SyncLosses.directory(for: storeURL).appending(path: fileName)
    }

    static func load(for storeURL: URL) -> SyncLossReview {
        guard let data = try? Data(contentsOf: url(for: storeURL)),
              let review = try? JSONDecoder().decode(SyncLossReview.self, from: data) else {
            return SyncLossReview()
        }
        return review
    }

    /// The shop closed this notice: every file in it is reviewed.
    static func markReviewed(_ notice: SyncLossNotice, storeURL: URL) throws {
        var review = load(for: storeURL)
        review.reviewed = Set(review.reviewed).union(notice.files.map(\.lastPathComponent)).sorted()
        // Every unreviewed file was in the notice, so none is left: the
        // put-back list has nothing to describe, and keeping it would mark a
        // LATER merge's loss of the same record as already back.
        review.putBack = []
        try review.save(for: storeURL)
    }

    func save(for storeURL: URL) throws {
        try FileManager.default.createDirectory(at: SyncLosses.directory(for: storeURL),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url(for: storeURL), options: .atomic)
    }
}

extension SyncLosses {

    /// Every kept-merge file beside this book, oldest first. The names carry
    /// the moment in a sortable form (`fileURL`), so name order is time order.
    static func keptFiles(for storeURL: URL) -> [URL] {
        let dir = directory(for: storeURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix("sync-") && $0.hasSuffix(".json") }
            .sorted()
            .map { dir.appending(path: $0) }
    }

    /// The notice as the disk says it should be: every kept merge not yet
    /// reviewed, and which of their records are already back. Nil when there
    /// is nothing to say.
    static func unreviewed(for storeURL: URL) -> (notice: SyncLossNotice?, putBack: Set<String>) {
        let review = SyncLossReview.load(for: storeURL)
        let done = Set(review.reviewed)
        var notice: SyncLossNotice?
        for file in keptFiles(for: storeURL) where !done.contains(file.lastPathComponent) {
            guard let kept = read(file), !kept.losses.isEmpty else { continue }
            notice = (notice ?? SyncLossNotice(files: [], losses: [])).adding(kept.losses, file: file)
        }
        return (notice, Set(review.putBack))
    }
}

extension SyncLossNotice {
    /// The records in it that have not been put back.
    func outstanding(putBack: Set<String>) -> [SyncLoss] {
        losses.filter { !putBack.contains($0.id) }
    }
}

extension Shop {

    /// Put the notice back up from `sync-conflicts/`, on every load of a real
    /// book. Called from `load`, so a relaunch shows what was never reviewed.
    ///
    /// What was put back this session is carried over and written down, so a
    /// reload in the middle of a review (putting a record back IS a write,
    /// and a write reloads) does not offer it again.
    func reloadSyncLosses(for build: StoreReader.Build?) {
        guard let build else {
            syncLossNotice = nil
            syncLossesPutBack = []
            return
        }
        let disk = SyncLosses.unreviewed(for: build.storeURL)
        // Only this book's: another book's put-back ids mean nothing here.
        let here = SyncLosses.directory(for: build.storeURL).standardizedFileURL.path
        let kept = syncLossNotice.map { notice in
            notice.files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == here }
        } ?? false
        let putBack = disk.putBack.union(kept ? syncLossesPutBack : [])
        if putBack != disk.putBack {
            var review = SyncLossReview.load(for: build.storeURL)
            review.putBack = putBack.sorted()
            try? review.save(for: build.storeURL)
        }
        syncLossNotice = disk.notice
        syncLossesPutBack = putBack
    }

    /// The records the banner still holds that have not been put back.
    var unreviewedSyncLosses: Int {
        syncLossNotice?.outstanding(putBack: syncLossesPutBack).count ?? 0
    }

    /// The shop has dealt with these: close the notice and remember that it
    /// did, so the next launch does not put it up again. The copies stay on
    /// disk either way.
    func closeSyncLosses() {
        if let build = source.build, let notice = syncLossNotice {
            do { try SyncLossReview.markReviewed(notice, storeURL: build.storeURL) }
            catch {
                // Not remembered means it comes back on the next launch, which
                // is the safe way round — but the shop is told why.
                moveProblem = words.callIt("mac.losses_review_unsaved") + " " + String(describing: error)
            }
        }
        dismissSyncLosses()
    }
}
