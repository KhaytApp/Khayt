import Foundation
import Testing
@testable import KhaytCore

/// The vault client engine (`VaultClient`, `VaultUpload`, `VaultDownload`,
/// `VaultSync`, `VaultRemote`) against `VaultStub`, the contract in memory.
/// No network, no book.
struct VaultClientTests {

    static let dek = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })

    /// A scratch directory per test, and the file to upload in it.
    struct Bench {
        let dir: URL
        let stub = VaultStub()
        let keys = try! VaultKeys(shopDek: VaultClientTests.dek)

        init() {
            dir = FileManager.default.temporaryDirectory.appending(path: "vault-test-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        func file(_ name: String, _ data: Data) -> URL {
            let u = dir.appending(path: name)
            try! data.write(to: u)
            return u
        }
        var spool: URL { dir.appending(path: "spool") }
        var library: URL { dir.appending(path: "Library") }
        /// Each device's own app folder, as each Mac has its own book folder.
        func appFolder(_ device: String) -> URL { dir.appending(path: "Support \(device)/khayt") }
        func sync(_ device: String = "mac-a") -> VaultSync {
            VaultSync(client: stub.client(), keys: keys, appFolder: appFolder(device), libraryRoot: library,
                      deviceId: device)
        }
        func remote(_ device: String = "mac-a") -> VaultRemote {
            VaultRemote(sync: sync(device), spoolRoot: dir.appending(path: "spool-\(device)"))
        }
        func job(_ src: URL, key: String = "k", fileId: String? = nil, base: Int? = nil) -> VaultUpload.Job {
            VaultUpload.Job(source: src, spoolKey: key, fileId: fileId, baseVersion: base, name: src.lastPathComponent,
                            kind: "stl", deviceId: "mac-a")
        }
        func feedRow(_ fileId: String) async throws -> VaultClient.FeedFile {
            try #require(try await stub.client().files(since: 0).files.first { $0.fileId == fileId })
        }
    }

    /// Two full chunks and a short one: 8 MiB + 1000 bytes.
    static func bytes(_ n: Int = 2 * VaultCrypto.chunkBytes + 1000, seed: UInt8 = 1) -> Data {
        var a = [UInt8](repeating: 0, count: n)
        var x = UInt32(seed) &* 2654435761
        for i in 0..<n { x = x &* 1664525 &+ 1013904223; a[i] = UInt8(truncatingIfNeeded: x >> 24) }
        return Data(a)
    }

    final class Seen: @unchecked Sendable {
        let lock = NSLock(); var list: [VaultUpload.Progress] = []
        func add(_ p: VaultUpload.Progress) { lock.lock(); list.append(p); lock.unlock() }
    }

    func committed(_ o: VaultUpload.Outcome) throws -> (VaultClient.Committed, VaultMeta) {
        guard case .committed(let c, let m) = o else { Issue.record("not committed: \(o)"); throw VaultStub.Crash() }
        return (c, m)
    }

    // MARK: - Upload and download

    @Test("Vault: upload streams three chunks in pages, completes, and downloads back verified")
    func uploadAndDownload() async throws {
        let b = Bench()
        b.stub.partsPerPage = 2   // the third part's URL comes from GET …/parts?from=2
        let data = Self.bytes()
        let src = b.file("bracket.stl", data)
        let seen = Seen()
        let (c, meta) = try committed(try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys,
                                                                 spoolRoot: b.spool, progress: { seen.add($0) }))
        #expect(c.version == 1 && !c.conflict)
        #expect(meta.seq == 1 && meta.size == data.count)
        #expect(b.stub.puts == 3)
        #expect(seen.list.contains { $0.phase == .sending && $0.done == 3 && $0.total == 3 })
        // The spool is gone once the upload commits.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: b.spool.path))?.isEmpty ?? true)

        let row = try await b.feedRow(c.fileId)
        #expect(row.headVersion?.bytes == data.count + 3 * 16)
        let out = b.dir.appending(path: "back.stl")
        let r = try await VaultDownload.run(row, client: b.stub.client(), keys: b.keys, lastSeenSeq: nil,
                                            to: out)
        #expect(try Data(contentsOf: out) == data)
        #expect(r.sha256 == meta.sha256 && r.seq == 1)
    }

    @Test("Vault: a 0-byte file is one 16-byte chunk and round-trips")
    func emptyFile() async throws {
        #expect(try VaultUpload.sealedSizes(size: 0) == [16])
        #expect(try VaultUpload.sealedSizes(size: VaultCrypto.chunkBytes) == [VaultCrypto.chunkBytes + 16])
        #expect(try VaultUpload.sealedSizes(size: VaultCrypto.chunkBytes + 1) == [VaultCrypto.chunkBytes + 16, 17])
        let b = Bench()
        let (c, _) = try committed(try await VaultUpload.run(b.job(b.file("empty.stl", Data())), client: b.stub.client(),
                                                              keys: b.keys, spoolRoot: b.spool))
        let out = b.dir.appending(path: "empty-back")
        try await VaultDownload.run(try await b.feedRow(c.fileId), client: b.stub.client(), keys: b.keys,
                                    lastSeenSeq: nil, to: out)
        #expect(try Data(contentsOf: out).isEmpty)
    }

    // MARK: - Resume

    @Test("Vault: after a crash mid-send the upload resumes from the spool, never re-encrypting")
    func resumeAfterCrash() async throws {
        let b = Bench()
        let data = Self.bytes()
        let src = b.file("big.stl", data)
        b.stub.failAfterPuts = 1
        await #expect(throws: VaultStub.Crash.self) {
            try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys, spoolRoot: b.spool,
                                      concurrency: 1)
        }
        let dir = VaultUpload.spoolDir(b.spool, "k")
        let state = try #require(VaultUpload.loadState(dir))
        #expect(state.sealed && state.sent == [0])
        let sealedBefore = try (0..<3).map { try Data(contentsOf: VaultUpload.chunkFile(dir, $0)) }

        b.stub.failAfterPuts = nil
        let (c, _) = try committed(try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys,
                                                              spoolRoot: b.spool))
        #expect(b.stub.starts == 1, "no second upload was started")
        #expect(b.stub.abandoned.isEmpty)
        // Part 0 went once; the others carry exactly the bytes sealed before the crash.
        let keys = (0..<3).map { b.stub.key(c.fileId, 1, $0) }
        #expect(b.stub.putsByKey[keys[0]] == 1)
        for i in 0..<3 { #expect(b.stub.objects[keys[i]] == sealedBefore[i]) }
        let out = b.dir.appending(path: "back")
        try await VaultDownload.run(try await b.feedRow(c.fileId), client: b.stub.client(), keys: b.keys,
                                    lastSeenSeq: nil, to: out)
        #expect(try Data(contentsOf: out) == data)
    }

    @Test("Vault: a spool that was never sealed is abandoned and started again with a new upload")
    func unsealedSpoolIsAbandoned() async throws {
        let b = Bench()
        let src = b.file("m.stl", Self.bytes(5000))
        // A crash during sealing leaves this: an uploadId and no wraps.
        let start = try await b.stub.client().startUpload(fileId: nil, baseVersion: nil, sizes: [5016],
                                                          tag: String(repeating: "a", count: 64), deviceId: nil)
        let dir = VaultUpload.spoolDir(b.spool, "k")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try VaultUpload.saveState(.init(sourceSha256: "x", size: 5000, fileId: start.fileId, uploadId: start.uploadId,
                                        version: 1, sizes: [5016], sealed: false), dir)
        _ = try committed(try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys, spoolRoot: b.spool))
        #expect(b.stub.abandoned == [start.uploadId])
        #expect(b.stub.starts == 2)
    }

    @Test("Vault: 409 parts-missing re-sends the stored ciphertext, byte for byte")
    func partsMissing() async throws {
        let b = Bench()
        let src = b.file("p.stl", Self.bytes())
        b.stub.dropPutsOnce = [1]
        let (c, _) = try committed(try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys,
                                                              spoolRoot: b.spool))
        let k = b.stub.key(c.fileId, 1, 1)
        #expect(b.stub.putsByKey[k] == 2)
        #expect(b.stub.bodiesByKey[k]?[0] == b.stub.bodiesByKey[k]?[1], "the re-PUT is the same sealed bytes")
        #expect(b.stub.droppedBodies[1] == b.stub.objects[k])
    }

    // MARK: - Refusals

    @Test("Vault: the same bytes twice adopt the existing version (409 duplicate) and upload nothing")
    func duplicate() async throws {
        let b = Bench()
        let data = Self.bytes(9000)
        let (c, _) = try committed(try await VaultUpload.run(b.job(b.file("a.stl", data)), client: b.stub.client(),
                                                              keys: b.keys, spoolRoot: b.spool))
        let puts = b.stub.puts
        let o = try await VaultUpload.run(b.job(b.file("copy.stl", data), key: "other"), client: b.stub.client(),
                                          keys: b.keys, spoolRoot: b.spool)
        guard case .adopted(let fileId, let version, _, let size) = o else { Issue.record("\(o)"); return }
        #expect(fileId == c.fileId && version == 1 && size == 9000)
        #expect(b.stub.puts == puts)
    }

    @Test("Vault: vault-full and no-vault are readable errors, and nothing is spooled")
    func vaultFull() async throws {
        let b = Bench()
        b.stub.limitBytes = 1000
        let src = b.file("x.stl", Self.bytes(5000))
        await #expect(throws: VaultClient.Failure.vaultFull(used: 0, limit: 1000)) {
            try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys, spoolRoot: b.spool)
        }
        #expect(!FileManager.default.fileExists(atPath: VaultUpload.spoolDir(b.spool, "k").path))
        #expect(VaultClient.Failure.vaultFull(used: 0, limit: 1000).description.contains("full"))
        b.stub.limitBytes = 0
        await #expect(throws: VaultClient.Failure.noVault) {
            try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys, spoolRoot: b.spool)
        }
    }

    @Test("Vault: a tampered chunk fails the download and leaves the old file in place")
    func tamperedChunk() async throws {
        let b = Bench()
        let (c, _) = try committed(try await VaultUpload.run(b.job(b.file("t.stl", Self.bytes())),
                                                              client: b.stub.client(), keys: b.keys, spoolRoot: b.spool))
        b.stub.tamper(fileId: c.fileId, version: 1, index: 1)
        let out = b.file("existing.stl", Data("keep me".utf8))
        await #expect(throws: VaultCrypto.Failure.self) {
            try await VaultDownload.run(try await b.feedRow(c.fileId), client: b.stub.client(), keys: b.keys,
                                        lastSeenSeq: nil, to: out)
        }
        #expect(try Data(contentsOf: out) == Data("keep me".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: b.dir.path).filter { $0.contains(".vault-") }.isEmpty)
    }

    @Test("Vault: a server that swaps the listed manifestHash is refused before any chunk")
    func serverManifestIsNotTrusted() async throws {
        let b = Bench()
        let (c, _) = try committed(try await VaultUpload.run(b.job(b.file("s.stl", Self.bytes(100))),
                                                              client: b.stub.client(), keys: b.keys, spoolRoot: b.spool))
        b.stub.versions["\(c.fileId)|1"]!.manifestHash = String(repeating: "0", count: 64)
        await #expect(throws: VaultDownload.Failure.serverManifestDiffers) {
            try await VaultDownload.run(try await b.feedRow(c.fileId), client: b.stub.client(), keys: b.keys,
                                        lastSeenSeq: nil, to: b.dir.appending(path: "o"))
        }
    }

    // MARK: - Sync

    @Test("Vault: the feed's purged files are dropped from this device's state")
    func feedWithPurged() async throws {
        let b = Bench()
        let s = b.sync()
        let (c1, _) = try committed(try await VaultUpload.run(b.job(b.file("1.stl", Self.bytes(10, seed: 1)), key: "1"),
                                                               client: b.stub.client(), keys: b.keys, spoolRoot: b.spool))
        let (c2, _) = try committed(try await VaultUpload.run(b.job(b.file("2.stl", Self.bytes(10, seed: 2)), key: "2"),
                                                               client: b.stub.client(), keys: b.keys, spoolRoot: b.spool))
        let first = try await s.pull()
        #expect(first.count == 2 && first.allSatisfy { if case .appeared = $0 { true } else { false } })
        try await b.stub.client().purge(fileId: c1.fileId)
        let second = try await s.pull()
        #expect(second == [.purged(fileId: c1.fileId, recordId: nil)])
        let st = s.load()
        #expect(st.files[c1.fileId] == nil && st.files[c2.fileId] != nil)
        #expect(st.rev == b.stub.rev)
        // The state file is in the app's own folder, named for the shop and the root's path.
        let h = VaultCrypto.hex(VaultCrypto.sha256(Data(b.library.standardizedFileURL.path.utf8))).prefix(16)
        #expect(s.stateURL == b.appFolder("mac-a").appending(path: "vault-state.shop_test.\(h).json"))
        #expect(!s.stateURL.path.hasPrefix(b.library.path))
        #expect(try await s.pull().isEmpty, "nothing new since the last rev")
    }

    @Test("Vault: a stale meta write (409) carries the current record and is merged and retried")
    func metaStale() async throws {
        let b = Bench()
        let (c, _) = try committed(try await VaultUpload.run(b.job(b.file("n.stl", Self.bytes(10))), client: b.stub.client(),
                                                              keys: b.keys, spoolRoot: b.spool))
        let a = b.sync("mac-a"), z = b.sync("mac-b")
        try await a.pull(); try await z.pull()
        // Device A renames; device B, still at the old metaRev, moves it.
        _ = try await a.setMeta(fileId: c.fileId) { var m = $0; m.name = "renamed.stl"; return m }
        // The raw route says stale and hands back the current record.
        let old = try #require(z.load().files[c.fileId]?.row)
        await #expect(throws: VaultClient.Failure.self) {
            try await z.client.setMeta(fileId: c.fileId, meta: Data(base64Encoded: old.meta!)!, baseMetaRev: old.metaRev)
        }
        do {
            _ = try await z.client.setMeta(fileId: c.fileId, meta: Data(base64Encoded: old.meta!)!, baseMetaRev: old.metaRev)
        } catch VaultClient.Failure.stale(let rev, let meta) {
            #expect(rev == 2 && meta == Data(base64Encoded: b.stub.storedMeta(c.fileId)!))
        }
        // VaultSync merges over it.
        let merged = try await z.setMeta(fileId: c.fileId) { var m = $0; m.path = "Brackets"; return m }
        #expect(merged.name == "renamed.stl" && merged.path == "Brackets")
        let row = try await b.feedRow(c.fileId)
        let opened = try VaultMeta.open(row, vaultKey: b.keys.vaultKey, lastSeenSeq: nil).meta
        #expect(opened.name == "renamed.stl" && opened.path == "Brackets" && opened.seq == 1)
    }

    @Test("Vault: an older meta served after a newer one was seen is refused as rollback")
    func rollback() async throws {
        let b = Bench()
        let r = b.remote()
        try await r.putFile("m", file: b.file("v1.stl", Self.bytes(10, seed: 1)))
        let fileId = try #require(r.sync.load().keys["m"])
        let v1meta = try #require(b.stub.storedMeta(fileId))
        try await r.putFile("m", file: b.file("v2.stl", Self.bytes(10, seed: 2)))
        #expect(r.sync.load().files[fileId]?.seq == 2)
        b.stub.setStoredMeta(fileId, v1meta)
        let changes = try await r.sync.pull()
        guard case .refused(let id, let why)? = changes.first else { Issue.record("\(changes)"); return }
        #expect(id == fileId && why.hasPrefix("rollback"))
        #expect(r.sync.load().files[fileId]?.seq == 2)
    }

    @Test("Vault: two devices editing from the same base keep both versions and say conflict")
    func conflictKeepsBoth() async throws {
        let b = Bench()
        let a = b.remote("mac-a"), z = b.remote("mac-b")
        try await a.putFile("m", file: b.file("base.stl", Self.bytes(10, seed: 1)))
        _ = try await z.sync.pull()
        try await a.putFile("m", file: b.file("a.stl", Self.bytes(10, seed: 2)))
        // B never saw A's v2; its upload is based on v1.
        let job = VaultUpload.Job(source: b.file("b.stl", Self.bytes(10, seed: 3)), spoolKey: "b",
                                  fileId: z.sync.load().keys["m"], baseVersion: 1, lastSeq: 1,
                                  name: "m", key: "m", deviceId: "mac-b")
        let o = try await VaultUpload.run(job, client: z.sync.client, keys: b.keys, spoolRoot: b.dir.appending(path: "sb"))
        let (c, _) = try committed(o)
        #expect(c.conflict && c.version == 3)
        let changes = try await z.sync.record(o, key: "m", recordId: nil)
        #expect(changes.contains(.conflict(fileId: c.fileId, recordId: nil, versions: [1, 2, 3])))
        // B's shop record replaced A's, but each version carries its own
        // sealed record, so both still download and verify.
        let row = try await b.feedRow(c.fileId)
        for v in [2, 3] {
            try await VaultDownload.run(row, version: v, client: b.stub.client(), keys: b.keys, lastSeenSeq: nil,
                                        to: b.dir.appending(path: "v\(v)"))
        }
        #expect(try Data(contentsOf: b.dir.appending(path: "v2")) == Self.bytes(10, seed: 2))
        #expect(try Data(contentsOf: b.dir.appending(path: "v3")) == Self.bytes(10, seed: 3))
    }

    @Test("Vault: a version with no record, or one sealed for another upload, is not downloaded")
    func versionMetaIsRequired() async throws {
        let b = Bench()
        let (c1, _) = try committed(try await VaultUpload.run(b.job(b.file("1.stl", Self.bytes(10, seed: 1)), key: "1"),
                                                               client: b.stub.client(), keys: b.keys, spoolRoot: b.spool))
        let (c2, _) = try committed(try await VaultUpload.run(b.job(b.file("2.stl", Self.bytes(10, seed: 2)), key: "2"),
                                                               client: b.stub.client(), keys: b.keys, spoolRoot: b.spool))
        let out = b.dir.appending(path: "o")
        // Another upload's record, served in this one's place.
        b.stub.versions["\(c1.fileId)|1"]!.versionMeta = b.stub.versions["\(c2.fileId)|1"]!.versionMeta
        await #expect(throws: VaultCrypto.Failure.authentication) {
            try await VaultDownload.run(try await b.feedRow(c1.fileId), client: b.stub.client(), keys: b.keys,
                                        lastSeenSeq: nil, to: out)
        }
        // The shop record served as the version record.
        b.stub.versions["\(c1.fileId)|1"]!.versionMeta = b.stub.storedMeta(c1.fileId)!
        await #expect(throws: VaultCrypto.Failure.self) {
            try await VaultDownload.run(try await b.feedRow(c1.fileId), client: b.stub.client(), keys: b.keys,
                                        lastSeenSeq: nil, to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test("Vault: a state file planted beside the library root is never read")
    func plantedStateIgnored() async throws {
        let b = Bench()
        try FileManager.default.createDirectory(at: b.library, withIntermediateDirectories: true)
        var planted = VaultSyncState(shopId: VaultStub.shopId, deviceId: "mac-a"); planted.rev = 999_999
        let beside = b.library.deletingLastPathComponent()
            .appending(path: ".\(b.library.lastPathComponent).khayt-vault.\(VaultStub.shopId).mac-a.json")
        try JSONEncoder().encode(planted).write(to: beside)
        #expect(b.sync("mac-a").load().rev != 999_999)
        #expect(FileManager.default.fileExists(atPath: beside.path), "left alone, not adopted")
    }

    /// A raw /complete, so the stub's refusals can be seen for bodies this
    /// client would never send.
    func rawComplete(_ b: Bench, _ uploadId: String, _ body: [String: Any]) async throws -> Int {
        var r = try CloudReader.request(b.stub.connection, token: VaultStub.token, method: "POST",
                                        tail: "/vault/uploads/\(uploadId)/complete")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return S3.status(try await b.stub.fetch(r).1)
    }

    @Test("Vault: /complete without versionMeta is refused (422), as khayt-cloud #130 does")
    func completeNeedsVersionMeta() async throws {
        let b = Bench()
        let up = try await b.stub.client().startUpload(fileId: nil, baseVersion: nil, sizes: [16],
                                                       tag: String(repeating: "b", count: 64), deviceId: nil)
        try await b.stub.client().put(up.parts[0], body: Data(count: 16))
        let base: [String: Any] = ["manifestHash": String(repeating: "c", count: 64),
                                   "wrappedKey": Data(count: 60).base64EncodedString(),
                                   "meta": Data(count: 40).base64EncodedString()]
        #expect(try await rawComplete(b, up.uploadId, base) == 422)
        var big = base; big["versionMeta"] = Data(count: 256 * 1024).base64EncodedString()
        #expect(try await rawComplete(b, up.uploadId, big) == 422, "over 256 KB")
        #expect(VaultClient.failure(422, Data(#"{"error":"versionMeta is required"}"#.utf8))
                == .invalid("versionMeta is required"))
    }

    @Test("Vault: blobs must be standard base64 with padding; this client always sends that")
    func blobsArePaddedBase64() async throws {
        #expect(VaultStub.paddedBase64(Data([1, 2, 3, 4]).base64EncodedString()))   // "AQIDBA=="
        #expect(!VaultStub.paddedBase64("AQIDBA"))                                  // unpadded
        #expect(!VaultStub.paddedBase64("AQID-_=="))                                // base64url
        #expect(!VaultStub.paddedBase64("AQ=D"))
        let b = Bench()
        let up = try await b.stub.client().startUpload(fileId: nil, baseVersion: nil, sizes: [16],
                                                       tag: String(repeating: "d", count: 64), deviceId: nil)
        try await b.stub.client().put(up.parts[0], body: Data(count: 16))
        let ok = Data(count: 61).base64EncodedString()   // 61 bytes: ends in "="
        let unpadded = String(ok.prefix { $0 != "=" })
        let body: [String: Any] = ["manifestHash": String(repeating: "c", count: 64), "wrappedKey": unpadded,
                                   "versionMeta": ok, "meta": ok]
        #expect(try await rawComplete(b, up.uploadId, body) == 422)
        var v = body; v["wrappedKey"] = ok; v["versionMeta"] = unpadded
        #expect(try await rawComplete(b, up.uploadId, v) == 422)
        // The real client end to end: every blob it sends passes the stub's check.
        _ = try committed(try await VaultUpload.run(b.job(b.file("p.stl", Self.bytes(61))), client: b.stub.client(),
                                                     keys: b.keys, spoolRoot: b.spool))
    }

    @Test("Vault: version numbers can have gaps (an aborted upload uses its number); nothing assumes head-1")
    func versionGaps() async throws {
        let b = Bench()
        let a = b.remote("mac-a"), z = b.remote("mac-b")
        try await a.putFile("m", file: b.file("v1.stl", Self.bytes(10, seed: 1)))
        let fileId = try #require(a.sync.load().keys["m"])
        try await z.sync.pull()
        // v2 is started and given up: the number is gone for good.
        let gone = try await b.stub.client().startUpload(fileId: fileId, baseVersion: 1, sizes: [26],
                                                         tag: String(repeating: "e", count: 64), deviceId: "mac-a")
        #expect(gone.version == 2)
        try await b.stub.client().abandon(uploadId: gone.uploadId)
        try await a.putFile("m", file: b.file("v3.stl", Self.bytes(10, seed: 3)))
        let row = try await b.feedRow(fileId)
        #expect(row.versions.map(\.version) == [1, 3] && row.head == 3)
        // One new version from one device: a change, not a conflict.
        let changes = try await z.sync.pull()
        #expect(changes.count == 1)
        guard case .changed(let id, _)? = changes.first else { Issue.record("\(changes)"); return }
        #expect(id == fileId)
        for v in [1, 3] {
            try await VaultDownload.run(row, version: v, client: b.stub.client(), keys: b.keys, lastSeenSeq: nil,
                                        to: b.dir.appending(path: "g\(v)"))
        }
        #expect(try Data(contentsOf: b.dir.appending(path: "g3")) == Self.bytes(10, seed: 3))
        #expect(try await z.get("m") == Self.bytes(10, seed: 3))
        // Pruning the non-head version leaves a file with one version, number 3.
        try await b.stub.client().prune(fileId: fileId, version: 1)
        await #expect(throws: VaultClient.Failure.isHead) { try await b.stub.client().prune(fileId: fileId, version: 3) }
        #expect(try await b.feedRow(fileId).versions.map(\.version) == [3])
    }

    // MARK: - As a LibraryRemote

    @Test("Vault: LibraryRemote.vault puts, proves by read-back, trashes and restores by key")
    func libraryRemote() async throws {
        let b = Bench()
        let remote = LibraryRemote.vault(b.remote())
        let data = Self.bytes(70_000)
        let fetch = b.stub.fetch
        try await remote.put("lib/abc/part.stl", data: data, fetch: fetch)
        let head = try #require(try await remote.head("lib/abc/part.stl", fetch: fetch))
        #expect(head.size == data.count && head.etag == nil, "no etag, so ensureInBucket reads back")
        #expect(try await remote.get("lib/abc/part.stl", fetch: fetch) == data)
        #expect(try await b.remote().verify("lib/abc/part.stl", sha256: VaultCrypto.hex(VaultCrypto.sha256(data)),
                                            size: data.count))
        #expect(try await remote.keys(under: "lib/", fetch: fetch) == ["lib/abc/part.stl"])
        // Putting the same bytes again is a dedupe hit, not a second upload.
        let puts = b.stub.puts
        try await remote.put("lib/abc/part.stl", data: data, fetch: fetch)
        #expect(b.stub.puts == puts)

        try await remote.delete("lib/abc/part.stl", fetch: fetch)
        #expect(try await remote.head("lib/abc/part.stl", fetch: fetch) == nil)
        #expect(try await remote.trashedCopy("lib/abc/part.stl", fetch: fetch)?.size == data.count)
        #expect(try await remote.restoreFromTrash("lib/abc/part.stl", fetch: fetch))
        #expect(try await remote.head("lib/abc/part.stl", fetch: fetch)?.size == data.count)
        #expect(remote.isVault && !remote.isDrive)
    }

    @Test("Vault: the client sends the delta header and never the token to object storage")
    func tokenStaysHome() async throws {
        final class Log: @unchecked Sendable {
            private var list: [URLRequest] = []; private let lock = NSLock()
            func add(_ r: URLRequest) { lock.withLock { list.append(r) } }
            var requests: [URLRequest] { lock.withLock { list } }
        }
        let b = Bench(), log = Log()
        let inner = b.stub.fetch
        let client = VaultClient(connection: b.stub.connection, token: VaultStub.token, fetch: { r in
            log.add(r)
            return try await inner(r)
        })
        _ = try await VaultUpload.run(b.job(b.file("h.stl", Self.bytes(10))), client: client, keys: b.keys, spoolRoot: b.spool)
        let store = log.requests.filter { $0.url?.host == "store.test" }
        #expect(!store.isEmpty && store.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(log.requests.filter { $0.url?.host == "cloud.test" }.allSatisfy {
            $0.value(forHTTPHeaderField: "x-delta-capable") == "1"
        })
        #expect(VaultClient.failure(404, Data(#"{"error":"Not found"}"#.utf8)) == .vaultOff)
        #expect(VaultClient.failure(410, Data(#"{"reason":"upload-expired"}"#.utf8)) == .uploadExpired)
        #expect(VaultClient.failure(402, Data(#"{"reason":"read-only"}"#.utf8)) == .readOnly)
    }
}
