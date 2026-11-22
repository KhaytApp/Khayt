import Foundation
import Testing
@testable import KhaytCore

/// Files the DESKTOP wrote (`test/fixtures/`), read here from the repository
/// and opened or reproduced by the Mac's own code, byte for byte. Each
/// fixture's README says how it was made. If one of these fails, the two
/// apps disagree on the wire or on disk: that is the finding, not the test.
struct CrossAppFixtureTests {

    /// `test/fixtures/<name>` at the repository root.
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .deletingLastPathComponent()   // …/mac
            .deletingLastPathComponent()   // the repository root
            .appending(path: "test/fixtures").appending(path: name)
    }

    static func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: - Off-site backup

    @Test("Fixture: a desktop off-site backup opens on the Mac to exactly book.json")
    func offsiteBackupOpens() throws {
        let dir = Self.fixture("offsite-backup")
        let sealed = try Data(contentsOf: dir.appending(path: "khayt-book-2026-11-05.khaytbak"))
        let book = try Data(contentsOf: dir.appending(path: "book.json"))
        let dek = Data((1...32).map { UInt8($0) })
        #expect(try OffsiteBackup.open(sealed, dek: dek) == book)
        #expect(OffsiteBackup.day(of: "khayt-book-2026-11-05.khaytbak") == "2026-11-05", "the Mac lists it as a backup")
        // And a wrong key is refused, not opened to something else.
        #expect(throws: OffsiteBackup.Failure.wrongKey) {
            try OffsiteBackup.open(sealed, dek: Data(repeating: 9, count: 32))
        }
    }

    // MARK: - A pinned vault upload

    /// A cloud for one upload: hands out the fixture's ids, keeps every PUT,
    /// and records the start and complete bodies.
    final class OneUpload: @unchecked Sendable {
        let fileId: String, uploadId: String, version: Int
        let lock = NSLock()
        var startBody: [String: Any]?
        var completeBody: [String: Any]?
        var parts: [Int: Data] = [:]

        init(fileId: String, uploadId: String, version: Int) {
            self.fileId = fileId; self.uploadId = uploadId; self.version = version
        }

        func reply(_ url: URL, _ code: Int, _ o: [String: Any]) -> (Data, URLResponse) {
            (try! JSONSerialization.data(withJSONObject: o),
             HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }

        var fetch: S3.Fetch { { [self] r in lock.withLock { handle(r) } } }

        func handle(_ r: URLRequest) -> (Data, URLResponse) {
            do {
                let url = r.url!, method = r.httpMethod ?? "GET"
                let body = (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
                if url.host == "store.test", method == "PUT" {
                    parts[Int(url.lastPathComponent)!] = r.httpBody ?? Data()
                    return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                if method == "POST", url.path.hasSuffix("/vault/uploads") {
                    startBody = body
                    let sizes = (body["sizes"] as? [Int]) ?? []
                    let list = sizes.enumerated().map {
                        ["index": $0.offset, "size": $0.element, "url": "https://store.test/p/\($0.offset)"] as [String: Any]
                    }
                    return reply(url, 201, ["uploadId": uploadId, "fileId": fileId, "version": version,
                                            "expiresAt": "tomorrow", "parts": list])
                }
                if method == "POST", url.path.hasSuffix("/vault/uploads/\(uploadId)/complete") {
                    completeBody = body
                    return reply(url, 201, ["fileId": fileId, "version": version, "rev": 1, "conflict": false])
                }
                return reply(url, 404, ["error": "unexpected \(method) \(url.path)"])
            }
        }
    }

    @Test("Fixture: a pinned vault upload from the Mac puts the desktop's exact bytes on the wire")
    func vaultUploadMatchesDesktop() async throws {
        let dir = Self.fixture("vault-upload-fixture")
        let input = try Self.json(dir.appending(path: "inputs.json"))
        let want = try Self.json(dir.appending(path: "expected.json"))
        func s(_ o: [String: Any], _ k: String) throws -> String { try #require(o[k] as? String, "\(k)") }
        func i(_ o: [String: Any], _ k: String) throws -> Int { try #require(o[k] as? Int, "\(k)") }

        // The file, by its recipe: byte k = (k * mul + add) mod 256.
        let recipe = try #require(input["plaintext"] as? [String: Any])
        let size = try i(recipe, "size"), mul = try i(recipe, "mul"), add = try i(recipe, "add")
        var bytes = [UInt8](repeating: 0, count: size)
        for k in 0..<size { bytes[k] = UInt8(truncatingIfNeeded: k &* mul &+ add) }
        let plaintext = Data(bytes)
        #expect(VaultCrypto.hex(VaultCrypto.sha256(plaintext)) == (try s(want, "plaintextSha256")))
        #expect(size == (try i(want, "size")))

        let tmp = FileManager.default.temporaryDirectory.appending(path: "vault-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appending(path: "model.3mf")
        try plaintext.write(to: source)

        let nonces = try #require(input["nonces"] as? [String: Any])
        let pins = VaultUpload.Pins(dk: try VaultCrypto.unhex(try s(input, "dataKey")),
                                    wrapNonce: try VaultCrypto.unhex(try s(nonces, "wrap")),
                                    versionMetaNonce: try VaultCrypto.unhex(try s(nonces, "versionMeta")),
                                    metaNonce: try VaultCrypto.unhex(try s(nonces, "meta")))
        let keys = try VaultKeys(shopDek: try VaultCrypto.unhex(try s(input, "shopDek")))
        let cloud = OneUpload(fileId: try s(input, "fileId"), uploadId: try s(input, "uploadId"),
                              version: try i(input, "version"))
        let client = VaultClient(connection: CloudReader.Connection(url: "https://cloud.test", shopId: "shop_fx",
                                                                    storedToken: ""),
                                 token: "tok", fetch: cloud.fetch)
        #expect(input["existingFileId"] is NSNull && input["baseVersion"] is NSNull, "a new file")
        let job = VaultUpload.Job(source: source, spoolKey: "fixture", fileId: nil, baseVersion: nil,
                                  lastSeq: try i(input, "lastSeq"), name: try s(input, "name"),
                                  path: try s(input, "path"), kind: try s(input, "kind"), key: try s(input, "key"),
                                  recordId: try s(input, "recordId"), deviceId: try s(input, "deviceId"))
        let outcome = try await VaultUpload.run(job, client: client, keys: keys, spoolRoot: tmp.appending(path: "spool"),
                                                concurrency: VaultUpload.concurrency, pins: pins, progress: nil)
        guard case .committed(let done, let meta) = outcome else { Issue.record("not committed: \(outcome)"); return }
        #expect(done.fileId == cloud.fileId && done.version == cloud.version)

        // POST /vault/uploads: the whole body, key for key.
        let start = try #require(cloud.startBody)
        let wantStart = try #require(want["startBody"] as? [String: Any])
        #expect(NSDictionary(dictionary: start).isEqual(to: wantStart), "start body: \(start) vs \(wantStart)")
        #expect(start["tag"] as? String == (try s(want, "dedupeTag")))
        #expect(start["sizes"] as? [Int] == want["sizes"] as? [Int])

        // Every chunk's ciphertext, as PUT.
        let chunks = try #require(want["chunks"] as? [[String: Any]])
        #expect(cloud.parts.count == chunks.count)
        for c in chunks {
            let index = try i(c, "index")
            let put = try #require(cloud.parts[index], "chunk \(index) was not PUT")
            #expect(put.count == (try i(c, "size")), "chunk \(index) size")
            #expect(VaultCrypto.chunkHash(put) == (try s(c, "sha256")), "chunk \(index) sha256")
            #expect(VaultCrypto.hex(put.prefix(16)) == (try s(c, "first16")), "chunk \(index) first16")
            #expect(VaultCrypto.hex(put.suffix(16)) == (try s(c, "last16")), "chunk \(index) last16")
            #expect(VaultCrypto.hex(try VaultCrypto.chunkNonce(index)) == (try s(c, "nonce")), "chunk \(index) nonce")
            let from = index * VaultCrypto.chunkBytes
            let piece = plaintext.subdata(in: from..<min(size, from + VaultCrypto.chunkBytes))
            #expect(piece.count == (try i(c, "plaintextBytes")))
            #expect(VaultCrypto.hex(VaultCrypto.sha256(piece)) == (try s(c, "plaintextSha256")))
        }
        let hashes = chunks.indices.map { VaultCrypto.chunkHash(cloud.parts[$0] ?? Data()) }
        #expect(hashes == want["chunkHashes"] as? [String])
        #expect(try VaultCrypto.manifestJSON(size: size, chunkHashes: hashes) == (try s(want, "manifestJson")))
        #expect(try VaultCrypto.manifestHash(size: size, chunkHashes: hashes) == (try s(want, "manifestHash")))
        #expect(meta.seq == (try i(want, "seq")))
        #expect(try VaultCrypto.versionMetaJSON(size: size, chunkHashes: hashes, seq: meta.seq)
                == (try s(want, "versionMetaJson")))

        // POST /complete: the whole body, key for key — wrappedKey, versionMeta
        // and meta are the sealed bytes, so equal base64 is equal ciphertext.
        let complete = try #require(cloud.completeBody)
        let wantComplete = try #require(want["completeBody"] as? [String: Any])
        #expect(NSDictionary(dictionary: complete).isEqual(to: wantComplete), "complete body: \(complete) vs \(wantComplete)")
        #expect(complete["wrappedKey"] as? String == (try s(want, "wrappedKey")))
        #expect(complete["versionMeta"] as? String == (try s(want, "versionMeta")))
        #expect(complete["meta"] as? String == (try s(want, "meta")))
        #expect(complete["manifestHash"] as? String == (try s(want, "manifestHash")))

        // The exact JSON that was sealed into each record.
        let sealedMeta = try #require(Data(base64Encoded: try s(want, "meta")))
        let opened = try VaultCrypto.decryptMeta(vaultKey: keys.vaultKey, fileId: cloud.fileId,
                                                 uploadId: cloud.uploadId, sealed: sealedMeta, lastSeenSeq: nil)
        #expect(opened.json == Data((try s(want, "metaJson")).utf8))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(try enc.encode(meta) == Data((try s(want, "metaJson")).utf8), "the Mac's VaultMeta encodes the same bytes")
        let sealedVm = try #require(Data(base64Encoded: try s(want, "versionMeta")))
        let vm = try VaultCrypto.openWithNonce(keys.vaultKey, sealedVm,
                                               aad: try VaultCrypto.vmetaAad(fileId: cloud.fileId, uploadId: cloud.uploadId))
        #expect(vm == Data((try s(want, "versionMetaJson")).utf8))
        let wrapped = try #require(Data(base64Encoded: try s(want, "wrappedKey")))
        #expect(try VaultCrypto.unwrapDkForShop(vaultKey: keys.vaultKey, wrapped: wrapped, fileId: cloud.fileId,
                                                uploadId: cloud.uploadId) == pins.dk)
    }

    @Test("Vault upload pins are test-only: without them every draw is random")
    func unpinnedUploadsDiffer() throws {
        let keys = try VaultKeys(shopDek: Data(repeating: 1, count: 32))
        let meta = VaultMeta(seq: 1, uploadId: "u1", manifestHash: String(repeating: "a", count: 64), size: 1,
                             sha256: String(repeating: "b", count: 64), name: "n")
        let a = try meta.sealed(vaultKey: keys.vaultKey, fileId: "f1")
        let b = try meta.sealed(vaultKey: keys.vaultKey, fileId: "f1")
        #expect(a.prefix(VaultCrypto.nonceBytes) != b.prefix(VaultCrypto.nonceBytes), "a fresh nonce each time")
        let n = Data(repeating: 7, count: VaultCrypto.nonceBytes)
        #expect(try meta.sealed(vaultKey: keys.vaultKey, fileId: "f1", nonce: n)
                == (try meta.sealed(vaultKey: keys.vaultKey, fileId: "f1", nonce: n)))
        let none = VaultUpload.Pins()
        #expect(none.dk == nil && none.wrapNonce == nil && none.versionMetaNonce == nil && none.metaNonce == nil)
    }
}
