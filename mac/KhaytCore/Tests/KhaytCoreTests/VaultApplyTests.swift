import Foundation
import Testing
@testable import KhaytCore

/// What another Mac did in the vault, brought into this Mac's library
/// (`VaultSync.pending` + `VaultApply`), against `VaultStub`: two "Macs", each
/// with its own state folder and its own library folder on disk. No network,
/// no book — `VaultApply` returns the record edits; `fold` stands in for the
/// app writing them (`Shop.applyVaultEdits`, tested in KhaytAppTests).
struct VaultApplyTests {

    static let engine: KhaytEngine = try! KhaytEngine()
    static let key = "print-files/PF-1/part.stl"

    typealias Bench = VaultClientTests.Bench

    /// One Mac: its vault remote, its library root, and its records.
    struct Mac {
        let remote: VaultRemote
        let root: URL
        var records: [VaultApply.Record]
        var sync: VaultSync { remote.sync }
        var folder: URL { root.appending(path: "PF-1") }
        var model: URL { folder.appending(path: "part.stl") }
        var sidecar: URL { folder.appending(path: "part.stl.cloud") }

        init(_ b: Bench, _ device: String, records: [VaultApply.Record] = [.init(id: "PF-1", folderName: "PF-1")]) {
            root = b.dir.appending(path: "Library-\(device)")
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sync = VaultSync(client: b.stub.client(), keys: b.keys, appFolder: b.appFolder(device),
                                 libraryRoot: root, deviceId: device)
            remote = VaultRemote(sync: sync, spoolRoot: b.dir.appending(path: "spool-\(device)"))
            self.records = records
        }

        var library: VaultApply.Library {
            let root = root
            return VaultApply.Library(records: records) { r in r.inPlace ? nil : root.appending(path: r.folderName) }
        }

        /// A pull, then a pass, as the app does it; the edits folded into
        /// the records and the applied changes settled, as the app does once
        /// the book is written.
        mutating func pass(now: Date = Date()) async throws -> VaultApply.Outcome {
            try await sync.pull()
            let out = await VaultApply.run(sync, library: library, engine: VaultApplyTests.engine, now: now)
            fold(out.edits)
            try await sync.settle(out.settled)
            return out
        }

        mutating func fold(_ edits: [VaultApply.Edit]) {
            for e in edits {
                guard let i = records.firstIndex(where: { $0.id == e.recordId }) else { continue }
                switch e {
                case .holds(_, let f, let sha, _): records[i].vaultFileId = f; records[i].contentHash = sha
                case .trashed(_, let f): records[i].vaultFileId = f; records[i].vaultTrashed = true
                case .restored: records[i].vaultTrashed = false
                case .purged: records[i].vaultFileId = nil; records[i].vaultTrashed = false
                }
            }
        }

        func write(_ data: Data) {
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try! data.write(to: model)
        }
    }

    static func bytes(_ seed: UInt8) -> Data { VaultClientTests.bytes(30_000, seed: seed) }
    static func sha(_ d: Data) -> String { VaultCrypto.hex(VaultCrypto.sha256(d)) }

    /// Mac A puts `data` up as a new version of the model.
    static func upload(_ a: Mac, _ b: Bench, _ data: Data, name: String) async throws {
        try await a.remote.putFile(key, file: b.file(name, data))
    }

    static func sidecar(_ m: Mac) async throws -> KhaytEngine.Sidecar? {
        guard let text = try? String(contentsOf: m.sidecar, encoding: .utf8) else { return nil }
        return try await engine.parseSidecar(text)
    }

    // MARK: - Another Mac adds, edits, trashes, restores, purges

    @Test("VaultApply: a model added on another Mac is online here (a sidecar for it), fetched on use")
    func added() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        let out = try await z.pass()
        let side = try #require(try await Self.sidecar(z))
        #expect(side.sha256 == Self.sha(Self.bytes(1)) && Int(side.size) == 30_000)
        #expect(side.provider == "vault" && side.key == Self.key)
        #expect(!FileManager.default.fileExists(atPath: z.model.path), "nothing downloaded until it is used")
        #expect(out.online == ["PF-1"])
        let fileId = try #require(a.sync.load().keys[Self.key])
        #expect(out.edits == [.holds(recordId: "PF-1", fileId: fileId, sha256: Self.sha(Self.bytes(1)), size: 30_000)])
        #expect(z.sync.pendingChanges().isEmpty, "settled")
        // Bring Back's own path: the vault remote fetches it by the sidecar's key, and it proves.
        let got = try #require(try await z.remote.getFile(side.key))
        #expect(try Data(contentsOf: got) == Self.bytes(1))
        // Again: nothing more to do, nothing written.
        let again = try await z.pass()
        #expect(again.edits.isEmpty && again.settled.isEmpty)
    }

    @Test("VaultApply: a new version over a copy untouched since the last sync replaces it")
    func newVersionReplaces() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        z.write(Self.bytes(1))
        let first = try await z.pass()
        #expect(first.edits.isEmpty, "already the same bytes: the book is not written just for a link")
        try await Self.upload(a, b, Self.bytes(2), name: "v2.stl")
        let pending = try await { try await z.sync.pull(); return z.sync.pendingChanges() }()
        #expect(pending.count == 1 && pending[0].base == Self.sha(Self.bytes(1)), "the version this Mac held")
        let out = try await z.pass()
        #expect(try Data(contentsOf: z.model) == Self.bytes(2))
        #expect(out.replaced == ["PF-1"] && out.conflicts.isEmpty)
        #expect(out.edits.count == 1 && z.records[0].contentHash == Self.sha(Self.bytes(2)))
        let left = try FileManager.default.contentsOfDirectory(atPath: z.folder.path)
        #expect(left == ["part.stl"], "no download left beside it: \(left)")
    }

    @Test("VaultApply: a new version of a model moved online renews its sidecar")
    func newVersionWhileOnline() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        _ = try await z.pass()
        try await Self.upload(a, b, Self.bytes(2), name: "v2.stl")
        let out = try await z.pass()
        #expect(try await Self.sidecar(z)?.sha256 == Self.sha(Self.bytes(2)))
        #expect(out.online == ["PF-1"] && z.records[0].contentHash == Self.sha(Self.bytes(2)))
        #expect(!FileManager.default.fileExists(atPath: z.model.path))
    }

    @Test("VaultApply: a model edited here and changed elsewhere keeps both, and says so")
    func localEditKeepsBoth() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        z.write(Self.bytes(1))
        _ = try await z.pass()
        z.write(Self.bytes(9))                      // the shop edits it here
        try await Self.upload(a, b, Self.bytes(2), name: "v2.stl")
        let out = try await z.pass()
        #expect(try Data(contentsOf: z.model) == Self.bytes(9), "the shop's own edit is never overwritten")
        let copy = z.folder.appending(path: "part (vault v2).stl")
        #expect(try Data(contentsOf: copy) == Self.bytes(2))
        #expect(out.conflicts == [VaultApply.Conflict(recordId: "PF-1", kept: z.model, copies: [copy])])
        #expect(out.edits.isEmpty && out.replaced.isEmpty, "the record still names the shop's file")
        // Settled, and a second pass makes no second copy.
        let again = try await z.pass()
        #expect(again.conflicts.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: z.folder.path).sorted()
                == [".part (vault v2).stl.vault-kept", "part (vault v2).stl", "part.stl"])
        // Marked as the vault's copy (so no backup uploads it); the shop's is not.
        let fileId = try #require(a.sync.load().keys[Self.key])
        #expect(VaultApply.keptMarker(of: copy) == VaultApply.KeptMarker(of: "part.stl", fileId: fileId, version: 2))
        #expect(!VaultApply.isKeptCopy(z.model))
        #expect(VaultApply.keptCopies(in: z.folder).map(\.copy) == [copy])
    }

    @Test("VaultApply: this Mac's own upload that conflicted keeps the other Mac's version beside it")
    func ownUploadConflict() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        z.write(Self.bytes(1))
        _ = try await z.pass()
        try await Self.upload(a, b, Self.bytes(2), name: "v2.stl")
        // B edits and uploads on the v1 it knew, before it has seen v2.
        z.write(Self.bytes(3))
        let job = VaultUpload.Job(source: z.model, spoolKey: "b", fileId: z.sync.load().keys[Self.key],
                                  baseVersion: 1, lastSeq: 1, name: "part.stl", key: Self.key, deviceId: "mac-b")
        let o = try await VaultUpload.run(job, client: z.sync.client, keys: b.keys, spoolRoot: b.dir.appending(path: "sb"))
        let changes = try await z.sync.record(o, key: Self.key, recordId: nil)
        #expect(changes.contains { if case .conflict = $0 { true } else { false } })
        let out = try await z.pass()
        #expect(try Data(contentsOf: z.model) == Self.bytes(3))
        let copy = z.folder.appending(path: "part (vault v2).stl")
        #expect(try Data(contentsOf: copy) == Self.bytes(2))
        #expect(!FileManager.default.fileExists(atPath: z.folder.appending(path: "part (vault v3).stl").path),
                "its own version is not copied beside itself")
        #expect(out.conflicts.count == 1)
    }

    @Test("VaultApply: a trash elsewhere archives the record after the grace period, and deletes no bytes")
    func trashed() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        z.write(Self.bytes(1))
        _ = try await z.pass()
        try await a.remote.delete(Self.key)
        let early = try await z.pass()
        #expect(early.edits.isEmpty && early.held == 1, "the book's own sync gets the first go")
        let out = try await z.pass(now: Date().addingTimeInterval(VaultApply.trashGrace + 60))
        let fileId = try #require(a.sync.load().keys[Self.key])
        #expect(out.edits == [.trashed(recordId: "PF-1", fileId: fileId)])
        #expect(try Data(contentsOf: z.model) == Self.bytes(1), "the local copy stays")
        #expect(z.sync.pendingChanges().isEmpty)
    }

    @Test("VaultApply: a restore elsewhere restores the record; a trash undone before it applied does nothing")
    func restored() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        _ = try await z.pass()
        try await a.remote.delete(Self.key)
        _ = try await z.pass(now: Date().addingTimeInterval(VaultApply.trashGrace + 60))
        #expect(z.records[0].vaultTrashed)
        #expect(try await a.remote.restoreFromTrash(Self.key))
        let out = try await z.pass()
        #expect(out.edits == [.restored(recordId: "PF-1")])
        #expect(!z.records[0].vaultTrashed)

        // Trashed and restored again before the trash was due: nothing archived.
        try await a.remote.delete(Self.key)
        _ = try await z.pass()
        #expect(try await a.remote.restoreFromTrash(Self.key))
        let late = try await z.pass(now: Date().addingTimeInterval(VaultApply.trashGrace + 60))
        #expect(late.edits.isEmpty)
        #expect(z.sync.pendingChanges().isEmpty)
    }

    @Test("VaultApply: a purge drops the link and keeps the record and the local copy")
    func purged() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        _ = try await z.pass()                      // online here: linked
        z.write(Self.bytes(1))                      // and brought back
        let fileId = try #require(a.sync.load().keys[Self.key])
        try await b.stub.client().purge(fileId: fileId)
        let out = try await z.pass()
        #expect(out.edits == [.purged(recordId: "PF-1")])
        #expect(z.records[0].vaultFileId == nil)
        #expect(try Data(contentsOf: z.model) == Self.bytes(1))
    }

    // MARK: - What must not happen

    @Test("VaultApply: a pull made by anything else no longer uses a change up")
    func incidentalPull() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        // A share sheet or a backup's read-back pulls first, and throws its answer away.
        _ = try await z.remote.head(Self.key)
        _ = try await z.remote.keys(under: "print-files/")
        let out = try await z.pass()
        #expect(out.online == ["PF-1"])
    }

    @Test("VaultApply: a Mac that cannot apply yet (the staff lock) loses nothing, and catches up in one pass")
    func lockedLosesNothing() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        z.write(Self.bytes(1))
        _ = try await z.pass()
        // Locked: pulls happen (other screens), nothing is applied or settled.
        for seed in [2, 3] as [UInt8] {
            try await Self.upload(a, b, Self.bytes(seed), name: "v\(seed).stl")
            _ = try await z.sync.pull()
        }
        #expect(z.sync.pendingChanges().count == 2)
        #expect(try Data(contentsOf: z.model) == Self.bytes(1))
        let out = try await z.pass()
        #expect(try Data(contentsOf: z.model) == Self.bytes(3), "the newest, over the untouched copy")
        #expect(out.conflicts.isEmpty && z.sync.pendingChanges().isEmpty)
    }

    @Test("VaultApply: a change for a record not in this book yet waits for it, then gives up")
    func recordNotHereYet() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b", records: [])
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        let out = try await z.pass()
        #expect(out.held == 1 && out.settled.isEmpty)
        // The book's sync brings the record: the next pass applies it.
        z.records = [.init(id: "PF-1", folderName: "PF-1")]
        #expect(try await z.pass().online == ["PF-1"])
        // One that never comes is dropped after the wait.
        try await a.remote.putFile("print-files/PF-9/x.stl", file: b.file("x.stl", Self.bytes(5)))
        _ = try await z.pass()
        let late = try await z.pass(now: Date().addingTimeInterval(VaultApply.recordWait + 60))
        #expect(late.settled.count == 1 && z.sync.pendingChanges().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: z.root.appending(path: "PF-9").path))
    }

    @Test("VaultApply: a model kept in the shop's own folder is never written")
    func inPlaceNeverWritten() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b", records: [.init(id: "PF-1", folderName: "PF-1", inPlace: true)])
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        let out = try await z.pass()
        #expect(out.edits.isEmpty && out.online.isEmpty && out.settled.count == 1)
        #expect(!FileManager.default.fileExists(atPath: z.folder.path))
    }

    @Test("VaultApply: a state file from before `pending` is seeded once, so what it used up is applied")
    func oldStateIsSeeded() async throws {
        let b = Bench()
        let a = Mac(b, "mac-a")
        var z = Mac(b, "mac-b")
        try await Self.upload(a, b, Self.bytes(1), name: "v1.stl")
        // The old build: pulled, threw the answer away, and wrote no
        // `pending` and no `sha256`.
        try await z.sync.pull()
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: z.sync.stateURL)) as? [String: Any])
        json["pending"] = nil
        var files = try #require(json["files"] as? [String: [String: Any]])
        for k in files.keys { files[k]?["sha256"] = nil }
        json["files"] = files
        try JSONSerialization.data(withJSONObject: json).write(to: z.sync.stateURL)
        #expect(z.sync.load().pending == nil)
        let out = try await z.pass()
        #expect(out.online == ["PF-1"], "seeded and applied")
        #expect(z.sync.load().pending == [], "seeded once: the key is there now")
        // An entry without `sha256` still knows the version it held.
        try await Self.upload(a, b, Self.bytes(2), name: "v2.stl")
        try await z.sync.pull()
        #expect(z.sync.pendingChanges().last?.base == Self.sha(Self.bytes(1)))
    }

    @Test("VaultApply: keys outside a record folder are never a place on disk")
    func places() {
        for good in ["print-files/PF-1/part.stl", "shop/print-files/PF-1/part.stl"] {
            let p = VaultApply.place(of: good)
            #expect(p?.folder == "PF-1" && p?.filename == "part.stl", Comment(rawValue: good))
        }
        for bad in ["print-files/../x.stl", "print-files/PF-1/../../x", "print-files/PF-1/.hidden",
                    "print-files/PF-1", "print-files/PF-1/a/b.stl", "k", "print-files//x.stl"] {
            #expect(VaultApply.place(of: bad) == nil, Comment(rawValue: bad))
        }
        #expect(VaultApply.keptName("part.stl", version: 3) == "part (vault v3).stl")
        #expect(VaultApply.keptName("README", version: 2) == "README (vault v2)")
    }
}
