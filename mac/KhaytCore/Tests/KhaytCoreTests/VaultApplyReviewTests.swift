import Foundation
import Testing
@testable import KhaytCore

/// The beta.8 review's findings in `VaultApply`, each as the scenario that
/// found it, against `VaultStub` (no network, no book).
struct VaultApplyReviewTests {
    typealias T = VaultApplyTests

    static func freeUpSpace(_ m: T.Mac, key: String = T.key) async throws {
        let data = try Data(contentsOf: m.model)
        let text = try await T.engine.sidecarText(size: data.count, sha256: T.sha(data), key: key, provider: "vault",
                                                  at: "2026-10-26T09:00:00Z")
        try Data(text.utf8).write(to: m.sidecar)
        try FileManager.default.removeItem(at: m.model)
    }

    // MARK: H1: a purge is decided by what this Mac holds, not by `vaultFileId`

    @Test("H1: this Mac's own upload, moved online by Free Up Space, then purged: the last copy here, said so")
    func purgeAfterOwnFreeUpSpace() async throws {
        let b = T.Bench()
        var a = T.Mac(b, "mac-a", records: [.init(id: "PF-1", folderName: "PF-1", contentHash: T.sha(T.bytes(1)),
                                                  filename: "part.stl")])
        a.write(T.bytes(1))
        try await a.remote.putFile(T.key, file: a.model)
        try await Self.freeUpSpace(a)
        let first = try await a.pass()
        #expect(first.edits.isEmpty, "the book already says these bytes")
        #expect(a.records[0].vaultFileId == nil, "never linked: the case the review found")
        let fileId = try #require(a.sync.load().keys[T.key])
        try await b.stub.client().purge(fileId: fileId)
        let out = try await a.pass()
        #expect(out.edits == [.purged(recordId: "PF-1", onlyCopy: true)])
        // Library Health's rule, on this folder as it is now.
        let found: [VaultOnlyCopies.Found] = [.init(name: "part.stl", provider: "vault", bytesHere: false)]
        #expect(VaultOnlyCopies.deletedByPlan(purgedAt: "T", vaultFileId: nil, found: found, own: "part.stl"))
    }

    @Test("H1: another Mac's model this Mac only ever held as the vault's sidecar, purged: the last copy here")
    func purgeAfterMatchingSidecar() async throws {
        let b = T.Bench()
        let a = T.Mac(b, "mac-a")
        var z = T.Mac(b, "mac-b")
        try await T.upload(a, b, T.bytes(1), name: "v1.stl")
        z.records[0].contentHash = T.sha(T.bytes(1))
        _ = try await z.pass()                      // the sidecar written
        var y = T.Mac(b, "mac-c")
        y.records[0].contentHash = T.sha(T.bytes(1))
        try FileManager.default.createDirectory(at: y.folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: z.sidecar, to: y.sidecar)
        #expect(try await y.pass().edits.isEmpty)
        let fileId = try #require(a.sync.load().keys[T.key])
        try await b.stub.client().purge(fileId: fileId)
        #expect(try await y.pass().edits == [.purged(recordId: "PF-1", onlyCopy: true)])
    }

    @Test("H1: a purge of a model whose bytes are here changes nothing; seen again in the vault, the mark goes")
    func purgeWithBytesHere() async throws {
        let b = T.Bench()
        let a = T.Mac(b, "mac-a")
        var z = T.Mac(b, "mac-b")
        try await T.upload(a, b, T.bytes(1), name: "v1.stl")
        z.records[0].contentHash = T.sha(T.bytes(1))
        z.write(T.bytes(1))
        _ = try await z.pass()
        let fileId = try #require(a.sync.load().keys[T.key])
        try await b.stub.client().purge(fileId: fileId)
        #expect(try await z.pass().edits.isEmpty, "not the last copy, never linked: nothing to write")
        // A record still marked purged, whose copy is seen in the vault again.
        var y = T.Mac(b, "mac-c", records: [.init(id: "PF-1", folderName: "PF-1", contentHash: T.sha(T.bytes(2)),
                                                  vaultPurged: true)])
        y.write(T.bytes(2))
        try await T.upload(a, b, T.bytes(2), name: "v2.stl")
        let out = try await y.pass()
        #expect(out.edits.count == 1 && !y.records[0].vaultPurged)
    }

    // MARK: H2: another Mac's new version waits for its record

    @Test("H2: a new version is not applied, and the book not written, until the record here names its hash")
    func newVersionWaitsForTheBook() async throws {
        let b = T.Bench()
        let a = T.Mac(b, "mac-a")
        var z = T.Mac(b, "mac-b")
        try await T.upload(a, b, T.bytes(1), name: "v1.stl")
        z.records[0].contentHash = T.sha(T.bytes(1))
        z.write(T.bytes(1))
        _ = try await z.pass()
        try await T.upload(a, b, T.bytes(2), name: "v2.stl")
        // Mac A's record (v2's hash, its new figures, its new name) has not
        // come through the book's sync yet.
        let early = try await z.pass()
        #expect(early.held == 1 && early.edits.isEmpty && early.replaced.isEmpty)
        #expect(try Data(contentsOf: z.model) == T.bytes(1), "no bytes either: the two stay in step")
        // It arrives. The bytes come down, and NOTHING is written to the
        // book: Mac A's record is what this book holds, and stays the newest.
        z.records[0].contentHash = T.sha(T.bytes(2))
        let out = try await z.pass()
        #expect(try Data(contentsOf: z.model) == T.bytes(2))
        #expect(out.edits.isEmpty, "edits: \(out.edits)")
        #expect(z.sync.pendingChanges().isEmpty)
    }

    @Test("H2: when the other Mac's record never comes, the change is applied after the wait, and said")
    func newVersionAfterTheWait() async throws {
        let b = T.Bench()
        let a = T.Mac(b, "mac-a")
        var z = T.Mac(b, "mac-b")
        try await T.upload(a, b, T.bytes(1), name: "v1.stl")
        z.records[0].contentHash = T.sha(T.bytes(1))
        z.write(T.bytes(1))
        _ = try await z.pass()
        try await T.upload(a, b, T.bytes(2), name: "v2.stl")
        #expect(try await z.pass().held == 1)
        let out = try await z.pass(now: Date().addingTimeInterval(VaultApply.bookWait + 60))
        #expect(try Data(contentsOf: z.model) == T.bytes(2))
        #expect(out.replaced == ["PF-1"] && out.edits.count == 1)
        #expect(z.records[0].contentHash == T.sha(T.bytes(2)))
    }

    // MARK: M7: this Mac's own unbacked edit is not another Mac's change

    @Test("M7: a model edited here after this Mac's own upload is left for the backup, never kept both")
    func ownEditIsNotAConflict() async throws {
        let b = T.Bench()
        var a = T.Mac(b, "mac-a", records: [.init(id: "PF-1", folderName: "PF-1", contentHash: T.sha(T.bytes(9)))])
        a.write(T.bytes(1))
        try await a.remote.putFile(T.key, file: a.model)
        a.write(T.bytes(9))                         // edited, not uploaded yet
        // The first pass after the update: every file seeded as `.appeared`.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: a.sync.stateURL)) as? [String: Any])
        json["pending"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: a.sync.stateURL)
        let out = try await a.pass()
        #expect(out.conflicts.isEmpty && out.edits.isEmpty, "conflicts: \(out.conflicts)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.folder.path) == ["part.stl"])
        #expect(try Data(contentsOf: a.model) == T.bytes(9))
        #expect(a.sync.pendingChanges().isEmpty)
    }

    // MARK: Security M2: a folder's other files are not the record's

    @Test("security M2: a second vault file in the record's folder never writes its hash onto the record")
    func partIsNotTheRecord() async throws {
        let b = T.Bench()
        let a = T.Mac(b, "mac-a")
        var z = T.Mac(b, "mac-b", records: [.init(id: "PF-1", folderName: "PF-1", filename: "part.stl")])
        try await T.upload(a, b, T.bytes(1), name: "v1.stl")
        try await a.remote.putFile("print-files/PF-1/part.gcode", file: b.file("g.gcode", T.bytes(5)))
        let out = try await z.pass()
        #expect(out.edits.map(\.recordId) == ["PF-1"])
        if case .holds(_, _, let sha, _)? = out.edits.first { #expect(sha == T.sha(T.bytes(1)), "the model's, not the G-code's") }
        #expect(FileManager.default.fileExists(atPath: z.folder.appending(path: "part.gcode.cloud").path),
                "the part is still brought into line, as a file")
        // The part trashed elsewhere does not archive the record.
        try await a.remote.delete("print-files/PF-1/part.gcode")
        let later = try await z.pass(now: Date().addingTimeInterval(VaultApply.trashGrace + 60))
        #expect(later.edits.isEmpty, "edits: \(later.edits)")
    }

    // MARK: Security M3: the kept-copy marker names one file of its folder

    @Test("security M3: a kept-copy marker whose `of` is a path, hidden or the copy itself is ignored")
    func markerIsOneSafeLeaf() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kept-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appending(path: "part (vault v2).stl")
        try Data("x".utf8).write(to: copy)
        for bad in ["../../Library/x", "a/b.stl", ".hidden", "..", "part (vault v2).stl", "a\\b", "x\u{0}y"] {
            try JSONEncoder().encode(VaultApply.KeptMarker(of: bad, fileId: "f", version: 2))
                .write(to: VaultApply.keptMarkerURL(for: copy))
            #expect(VaultApply.keptMarker(of: copy) == nil, Comment(rawValue: bad))
        }
        try JSONEncoder().encode(VaultApply.KeptMarker(of: "part.stl", fileId: "", version: 2))
            .write(to: VaultApply.keptMarkerURL(for: copy))
        #expect(VaultApply.keptMarker(of: copy) == nil, "no file id")
        try JSONEncoder().encode(VaultApply.KeptMarker(of: "part.stl", fileId: "f", version: 2))
            .write(to: VaultApply.keptMarkerURL(for: copy))
        #expect(VaultApply.keptMarker(of: copy)?.of == "part.stl")
    }

    // MARK: M6: a file is hashed once while it is unchanged

    @Test("M6: a digest is remembered by size and modification time, across passes, and forgotten on change")
    func digestsAreRemembered() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "digests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "m.stl"), memo = dir.appending(path: "d.json")
        try T.bytes(1).write(to: file)
        let one = DigestMemo(file: memo)
        #expect(try await one.digest(file).sha256 == T.sha(T.bytes(1)))
        one.save()
        // What the next pass remembers is what it uses: no second read.
        var saved = try JSONDecoder().decode([String: DigestMemo.Seen].self, from: Data(contentsOf: memo))
        let key = file.standardizedFileURL.path
        saved[key]?.sha256 = "remembered"
        try JSONEncoder().encode(saved).write(to: memo)
        #expect(try await DigestMemo(file: memo).digest(file).sha256 == "remembered")
        // Changed (another size): read again.
        try T.bytes(2).prefix(100).write(to: file)
        #expect(try await DigestMemo(file: memo).digest(file).sha256 == T.sha(T.bytes(2).prefix(100)))
    }
}
