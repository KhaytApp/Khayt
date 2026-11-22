import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A restore the next sync cannot undo, and a sync that cannot take a record
/// without keeping a copy and saying so.
///
/// Every merge here is the engine's real one (`lib/cloud-inbox.js` over
/// `lib/sync.js`), run against books in a temp directory.
@MainActor
struct SyncSafetyTests {

    static func rows(_ root: [String: JSONValue], _ collection: String) -> [[String: JSONValue]] {
        guard case .array(let a)? = root[collection] else { return [] }
        return a.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    static func string(_ o: [String: JSONValue], _ k: String) -> String? {
        if case .string(let s)? = o[k] { return s } else { return nil }
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    static func object(_ json: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }

    // MARK: - 1. A restore survives the next sync

    /// The book as it stands: Aisha deleted since the backup (and the delete
    /// synced), P-1 edited since.
    static let current = """
    {"version":10,
     "printLog":[{"id":"P-1","rev":3,"project":"edited after the backup"}],
     "clients":[],
     "jobs":[{"id":"J-1","rev":1,"clientId":"C-1"}],
     "tombstones":[{"id":"C-1","collection":"clients","rev":2,"deletedAt":"2026-09-20T10:00:00.000Z"}],
     "settings":{"bizEn":"The Shop"}}
    """

    /// The backup the shop wants back.
    static let backup = """
    {"version":10,"exportedAt":"2026-09-03T10:00:00.000Z",
     "printLog":[{"id":"P-1","rev":2,"project":"as it was"},{"id":"P-2","rev":1,"project":"bracket"}],
     "clients":[{"id":"C-1","rev":2,"nameEn":"Aisha"}],
     "jobs":[{"id":"J-1","rev":1,"clientId":"C-1"}],
     "settings":{"bizEn":"The Shop"}}
    """

    /// What the cloud holds by the time the next sync runs: the delete this
    /// Mac knew about, one it did not (P-2, deleted on a phone), and P-1 edited
    /// further still on another device.
    static let cloud = """
    {"printLog":[{"id":"P-1","rev":7,"project":"edited on the phone"}],
     "clients":[],
     "jobs":[{"id":"J-1","rev":1,"clientId":"C-1"}],
     "tombstones":[{"id":"C-1","collection":"clients","rev":2,"deletedAt":"2026-09-20T10:00:00.000Z"},
                   {"id":"P-2","collection":"printLog","rev":1,"deletedAt":"2026-09-21T10:00:00.000Z"}]}
    """

    static func restoreOnBench() async throws -> RestoreTests.Bench {
        let b = try RestoreTests.bench(book: current, backup: backup)
        try await RestoreTests.run(b)
        return b
    }

    /// What `sendToCloud` and `pullFromCloud` do with a pending restore, then
    /// the merge every whole-book sync runs.
    static func syncAfterRestore(_ b: RestoreTests.Bench, engine: KhaytEngine,
                                 cloud: [String: JSONValue]) async throws -> KhaytEngine.Merged {
        let pending = try #require(RestoreGuard.pending(for: b.store), "the restore left no marker")
        var report: KhaytEngine.Merged?
        try await StoreWriter.update(storeURL: b.store, owns: { true }, whoHasIt: { nil },
                                     recordingDeletes: false) { root in
            root = RestoreGuard.prevail(root, over: cloud, restored: Set(pending.records))
            let merged = try await engine.mergeFromCloud(local: root, server: cloud)
            root = merged.store
            report = merged
        }
        return try #require(report)
    }

    @Test("a restored record the cloud has tombstoned, or holds at a higher rev, survives the next merge")
    func restoreSurvivesTheMerge() async throws {
        let b = try await Self.restoreOnBench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let engine = try KhaytEngine()

        _ = try await Self.syncAfterRestore(b, engine: engine, cloud: try Self.object(Self.cloud))
        let after = try Self.read(b.store)

        // Aisha: tombstoned here AND in the cloud. Back, under a new id, and
        // the job that pointed at her points at the new one.
        let clients = Self.rows(after, "clients")
        let aisha = try #require(clients.first { Self.string($0, "nameEn") == "Aisha" },
                                 "the restored customer was deleted again by the merge")
        let newId = try #require(Self.string(aisha, "id"))
        #expect(newId != "C-1", "a tombstoned id cannot live again; it must be revived under a new one")
        #expect(newId.hasPrefix("C-"))
        #expect(Self.rows(after, "jobs").first.flatMap { Self.string($0, "clientId") } == newId,
                "the job still points at the dead id")

        // P-1: the cloud held rev 7. The restored copy is still here.
        let p1 = try #require(Self.rows(after, "printLog").first { Self.string($0, "id") == "P-1" })
        #expect(Self.string(p1, "project") == "as it was", "the cloud's higher rev replaced the restored record")
        #expect(BookRecords.rev(p1) > 7)

        // P-2: tombstoned only in the cloud — this Mac never knew. Still here.
        #expect(Self.rows(after, "printLog").contains { Self.string($0, "project") == "bracket" },
                "a cloud-only tombstone deleted a restored record")
    }

    @Test("without the guard, the same merge undoes the restore — what this fixes")
    func theMergeUndoesABareRestore() async throws {
        // The backup's bytes written as they were, which is what restore did.
        let dir = try RestoreTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try KhaytEngine()
        let merged = try await engine.mergeFromCloud(local: try Self.object(Self.backup),
                                                     server: try Self.object(Self.cloud))
        #expect(!Self.rows(merged.store, "clients").contains { Self.string($0, "nameEn") == "Aisha" })
        let p1 = Self.rows(merged.store, "printLog").first { Self.string($0, "id") == "P-1" }
        #expect(p1.flatMap { Self.string($0, "project") } == "edited on the phone")
    }

    @Test("the delta outbox sends every restored record the cloud deleted or holds older")
    func restoreGoesOutAsDeltas() async throws {
        let b = try await Self.restoreOnBench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let engine = try KhaytEngine()
        let cloud = try Self.object(Self.cloud)
        let pending = try #require(RestoreGuard.pending(for: b.store))
        try await StoreWriter.update(storeURL: b.store, owns: { true }, whoHasIt: { nil },
                                     recordingDeletes: false) { root in
            root = RestoreGuard.prevail(root, over: cloud, restored: Set(pending.records))
        }
        let outbox = try await engine.changesToSend(local: try Self.read(b.store), server: cloud)
        let sent: [String] = outbox.deltas.compactMap {
            guard case .object(let d) = $0, case .object(let r)? = d["record"] else { return nil }
            return Self.string(r, "project") ?? Self.string(r, "nameEn")
        }
        #expect(sent.contains("as it was"))
        #expect(sent.contains("bracket"))
        #expect(sent.contains("Aisha"))
    }

    @Test("a restore leaves a marker, carries the replaced book's deletes, and stamps nothing the old book agreed with")
    func restoreMarker() async throws {
        let b = try await Self.restoreOnBench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let pending = try #require(RestoreGuard.pending(for: b.store))
        #expect(pending.records.contains("printLog:P-1"))
        let after = try Self.read(b.store)
        #expect(BookRecords.tombstoneKeys(after).contains("clients:C-1"),
                "the replaced book's delete was dropped, so another device would hand it back")
        // J-1 was identical in both books; it moved only because it was relinked.
        RestoreGuard.clear(for: b.store)
        #expect(RestoreGuard.pending(for: b.store) == nil)
    }

    @Test("prevail leaves alone a restored record the other side agrees with")
    func prevailIsQuietWhenNothingDiffers() {
        let book: [String: JSONValue] = ["printLog": .array([.object(["id": .string("P-1"), "rev": .number(4),
                                                                       "project": .string("same")])])]
        let out = RestoreGuard.prevail(book, over: book, restored: ["printLog:P-1"])
        #expect(out == book)
    }

    // MARK: - 2a. The baseline

    @Test("the baseline records what both copies hold at the same rev, and forgets what left the book")
    func baselineAgreement() {
        let book: [String: JSONValue] = [
            "clients": .array([.object(["id": .string("A"), "rev": .number(3)]),
                               .object(["id": .string("B"), "rev": .number(5)])]),
        ]
        let cloud: [String: JSONValue] = [
            "clients": .array([.object(["id": .string("A"), "rev": .number(3)]),
                               .object(["id": .string("B"), "rev": .number(4)])]),
        ]
        let was = SyncBaseline(shopId: "s", revs: ["clients:B": 4, "clients:GONE": 9])
        let next = was.agreeing(book: book, cloud: cloud)
        #expect(next.revs == ["clients:A": 3, "clients:B": 4])
    }

    @Test("the baseline survives on disk, and belongs to one shop")
    func baselineOnDisk() throws {
        let dir = try RestoreTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        SyncBaseline(shopId: "shop-1", revs: ["clients:A": 2]).save(for: store)
        #expect(SyncBaseline.load(for: store, shopId: "shop-1").revs == ["clients:A": 2])
        #expect(SyncBaseline.load(for: store, shopId: "shop-2").revs.isEmpty)
    }

    /// The edit made here, and the newer copy from elsewhere.
    static let edited = """
    {"clients":[{"id":"C-A","rev":3,"nameEn":"Aisha","phone":"0501 corrected here"},
                {"id":"C-B","rev":1,"nameEn":"Badr"}]}
    """
    static let theirs = """
    {"clients":[{"id":"C-A","rev":4,"nameEn":"Aisha","phone":"0500 old, edited twice elsewhere"}],
     "tombstones":[{"id":"C-B","collection":"clients","rev":1,"deletedAt":"2026-09-30T10:00:00.000Z"}]}
    """

    @Test("an edit overwritten by a higher rev is reported once the baseline is installed, and not before")
    func baselineMakesOverwritesVisible() async throws {
        let unseeded = try KhaytEngine()
        let blind = try await unseeded.mergeFromCloud(local: try Self.object(Self.edited),
                                                      server: try Self.object(Self.theirs))
        #expect(!blind.conflicts.contains { Self.kind($0) == "remote_over_local_edit" },
                "without a baseline the rule says nothing — the bug")

        let seeded = try KhaytEngine()
        try await seeded.markSynced(["clients:C-A": 2, "clients:C-B": 1])
        #expect(try await seeded.syncedRev(collection: "clients", id: "C-A") == 2)
        let seen = try await seeded.mergeFromCloud(local: try Self.object(Self.edited),
                                                   server: try Self.object(Self.theirs))
        #expect(seen.conflicts.contains { Self.kind($0) == "remote_over_local_edit" })
    }

    static func kind(_ conflict: JSONValue) -> String? {
        if case .object(let o) = conflict, case .string(let k)? = o["kind"] { return k }
        return nil
    }

    // MARK: - 2b/c. What a merge takes is kept, announced, and can be put back

    @Test("a merge keeps a copy of every record it removes or overwrites after a local edit, before the book changes")
    func mergeKeepsWhatItTakes() async throws {
        let dir = try RestoreTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        try Data(Self.edited.utf8).write(to: store)

        let engine = try KhaytEngine()
        try await engine.markSynced(["clients:C-A": 2, "clients:C-B": 1])
        let file = SyncLosses.fileURL(for: store)
        var losses: [SyncLoss] = []
        try await StoreWriter.update(storeURL: store, owns: { true }, whoHasIt: { nil },
                                     recordingDeletes: false) { root in
            let before = root
            let merged = try await engine.mergeFromCloud(local: root, server: try Self.object(Self.theirs))
            losses = try Shop.keepLosses(before: before, merged: merged, at: file)
            root = merged.store
        }

        #expect(losses.count == 2)
        let replaced = try #require(losses.first { $0.kind == .replaced })
        #expect(replaced.recordId == "C-A")
        guard case .object(let mine) = replaced.record else { Issue.record("shape"); return }
        #expect(Self.string(mine, "phone") == "0501 corrected here", "the copy kept is not this Mac's edit")
        #expect(losses.contains { $0.kind == .removed && $0.recordId == "C-B" })

        let kept = try #require(SyncLosses.read(file), "nothing was written to sync-conflicts/")
        #expect(kept.losses == losses)
        #expect(file.deletingLastPathComponent().lastPathComponent == "sync-conflicts")

        // The book did change — the cloud's rule still wins the merge.
        let after = try Self.read(store)
        #expect(Self.rows(after, "clients").count == 1)

        // c. The notice.
        let notice = SyncLossNotice(files: [], losses: []).adding(losses, file: file)
        #expect(notice.replaced == 1 && notice.removed == 1 && notice.files == [file])

        // And each comes back — the removed one under a new id, because its old
        // id is tombstoned; the replaced one above the cloud's rev.
        for loss in losses {
            try StoreWriter.update(storeURL: store, owns: { true }, whoHasIt: { nil }) { root in
                SyncLosses.putBack(loss, into: &root)
            }
        }
        let back = Self.rows(try Self.read(store), "clients")
        let a = try #require(back.first { Self.string($0, "id") == "C-A" })
        #expect(Self.string(a, "phone") == "0501 corrected here")
        #expect(BookRecords.rev(a) > 4, "put back below the cloud's rev, so the next sync undoes it")
        let badr = try #require(back.first { Self.string($0, "nameEn") == "Badr" })
        #expect(Self.string(badr, "id") != "C-B")

        // A merge that took nothing writes nothing.
        let quiet = SyncLosses.fileURL(for: store, at: Date().addingTimeInterval(5))
        try SyncLosses.keep([], at: quiet)
        #expect(!FileManager.default.fileExists(atPath: quiet.path))
    }

    @Test("a record deleted here whose later edit from elsewhere was kept out is kept too")
    func keptDeletedIsKept() {
        let before: [String: JSONValue] = ["clients": .array([])]
        let conflict: JSONValue = .object([
            "collection": .string("clients"), "id": .string("C-Z"), "kind": .string("delete_over_edit"),
            "discarded": .object(["id": .string("C-Z"), "rev": .number(5), "nameEn": .string("Zaid")]),
        ])
        let losses = SyncLosses.compute(before: before, after: before, conflicts: [conflict])
        #expect(losses.map(\.kind) == [.keptDeleted])
        #expect(losses.first?.title == "Zaid")
    }

    // MARK: - 3. A restore that does not hold on for ever (pre-alpha.58 review)

    @Test("a restore marks only the records it changed, not every record in the book")
    func markerIsOnlyWhatChanged() async throws {
        let book = """
        {"version":10,
         "printLog":[{"id":"P-1","rev":3,"project":"edited after the backup"}],
         "clients":[{"id":"C-9","rev":1,"nameEn":"Same in both"}],
         "settings":{"bizEn":"The Shop"}}
        """
        let backup = """
        {"version":10,"exportedAt":"2026-09-03T10:00:00.000Z",
         "printLog":[{"id":"P-1","rev":2,"project":"as it was"},{"id":"P-2","rev":1,"project":"new"}],
         "clients":[{"id":"C-9","rev":1,"nameEn":"Same in both"}],
         "settings":{"bizEn":"The Shop"}}
        """
        let b = try RestoreTests.bench(book: book, backup: backup)
        defer { try? FileManager.default.removeItem(at: b.dir) }
        try await RestoreTests.run(b)
        let pending = try #require(RestoreGuard.pending(for: b.store))
        #expect(Set(pending.records) == ["printLog:P-1", "printLog:P-2"],
                "a record the restore did not change must not override other devices: \(pending.records)")
    }

    @Test("the hold prevails only over cloud copies at or below the rev it first saw, and says what it overrode")
    func holdIsBoundedByTheFirstCloudRev() async throws {
        let b = try await Self.restoreOnBench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        var pending = try #require(RestoreGuard.pending(for: b.store))
        var book = try Self.read(b.store)

        let first = RestoreGuard.hold(book, over: try Self.object(Self.cloud), pending: &pending)
        book = first.book
        #expect(pending.cloudRevs?["printLog:P-1"] == 7, "the first hold must remember the cloud's rev")
        let p1 = try #require(Self.rows(book, "printLog").first { Self.string($0, "id") == "P-1" })
        #expect(Self.string(p1, "project") == "as it was")
        #expect(BookRecords.rev(p1) == 8)
        // What it overrode is kept, like every other record sync takes.
        let lost = try #require(first.overridden.first { $0.recordId == "P-1" })
        #expect(lost.kind == .replaced)
        guard case .object(let theirs) = lost.record else { Issue.record("shape"); return }
        #expect(Self.string(theirs, "project") == "edited on the phone")

        // A push failed; the phone edits P-1 AFTER the restore. That edit stands.
        let later = """
        {"printLog":[{"id":"P-1","rev":9,"project":"edited on the phone after the restore"}],
         "clients":[], "jobs":[{"id":"J-1","rev":1,"clientId":"C-1"}]}
        """
        let second = RestoreGuard.hold(book, over: try Self.object(later), pending: &pending)
        let again = try #require(Self.rows(second.book, "printLog").first { Self.string($0, "id") == "P-1" })
        #expect(BookRecords.rev(again) == 8, "a cloud edit made after the restore was overridden")
        #expect(second.overridden.isEmpty)
    }

    @Test("a restore marker expires, and is cleared for a role that can never push it")
    func markerEnds() throws {
        let dir = try RestoreTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        let then = Date().addingTimeInterval(-8 * 86_400)
        try RestoreGuard.markPending(["printLog:P-1"], for: store, now: then)
        let taken = RestoreGuard.take(for: store)
        #expect(taken.pending == nil)
        #expect(taken.expired)
        #expect(RestoreGuard.pending(for: store) == nil, "an expired marker stays on disk")

        try RestoreGuard.markPending(["printLog:P-1"], for: store)
        #expect(RestoreGuard.take(for: store).pending != nil)
        #expect(!RestoreGuard.afterPull(canWrite: true, storeURL: store))
        #expect(RestoreGuard.pending(for: store) != nil)
        #expect(RestoreGuard.afterPull(canWrite: false, storeURL: store))
        #expect(RestoreGuard.pending(for: store) == nil, "a viewer's marker would hold for ever")
    }

    // MARK: - 4. The files beside the book hold customer records

    static func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("sync-conflicts, the baseline and the restore marker are readable by this user only")
    func sideFilesArePrivate() throws {
        let dir = try RestoreTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        try RestoreGuard.markPending(["clients:C-1"], for: store)
        #expect(try Self.mode(RestoreGuard.pendingURL(for: store)) == 0o600)
        SyncBaseline(shopId: "s", revs: ["clients:A": 1]).save(for: store)
        #expect(try Self.mode(SyncBaseline.url(for: store)) == 0o600)
        let file = SyncLosses.fileURL(for: store)
        let loss = SyncLoss(kind: .removed, collection: "clients", recordId: "C-1",
                            record: .object(["id": .string("C-1"), "phone": .string("0500")]), replacedBy: nil)
        try SyncLosses.keep([loss], at: file)
        #expect(try Self.mode(file) == 0o600)
        #expect(try Self.mode(SyncLosses.directory(for: store)) == 0o700)
    }

    @Test("sync-conflicts is pruned: nothing older than 60 days, never more than 200 files")
    func conflictsArePruned() throws {
        let dir = try RestoreTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        let folder = SyncLosses.directory(for: store)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let old = folder.appending(path: "sync-old.json")
        try Data("{}".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-61 * 86_400)],
                                              ofItemAtPath: old.path)
        for i in 0..<205 {
            let f = folder.appending(path: String(format: "sync-%03d.json", i))
            try Data("{}".utf8).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(i - 300))],
                                                  ofItemAtPath: f.path)
        }
        SyncLosses.prune(for: store, now: now)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left.count == 200)
        #expect(!left.contains("sync-old.json"))
        #expect(!left.contains("sync-000.json"), "the oldest go first")
        #expect(left.contains("sync-204.json"))
    }
}
