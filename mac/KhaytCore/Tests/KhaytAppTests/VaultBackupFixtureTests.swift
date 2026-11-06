import Foundation
import Testing
@testable import KhaytCore
@testable import KhaytApp

/// `test/fixtures/vault-backup-meta/`: what a Windows/Linux backup of ONE
/// library model put in the vault (written by the desktop's real
/// `lib/main/vault-backup.js`), run through this Mac's matching — the feed
/// pulled by `VaultSync`, applied by `VaultApply` against the library the app
/// builds from the book (`Shop.vaultLibrary`), and written by
/// `Shop.applyVaultEdits`. The desktop's record must be found by its folder
/// and given the link on the SAME record: no new record, nothing held.
struct VaultBackupFixtureTests {

    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Tests/KhaytAppTests
        .deletingLastPathComponent()   // …/Tests
        .deletingLastPathComponent()   // …/KhaytCore
        .deletingLastPathComponent()   // …/mac
        .deletingLastPathComponent()   // the repository root
        .appending(path: "test/fixtures/vault-backup-meta")

    static func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: name))) as? [String: Any])
    }

    struct NotBase64: Error { let value: Any? }

    /// A base64 string field, decoded.
    static func b64(_ v: Any?) throws -> Data {
        guard let s = v as? String, let d = Data(base64Encoded: s) else { throw NotBase64(value: v) }
        return d
    }

    /// The row as the cloud's feed sends it. The fixture's fake vault left
    /// out `chunkBytes` on each version, which the real cloud always sends
    /// (khayt-cloud `src/store.js`, the feed's version rows) and the Mac's
    /// `VaultClient.Version` requires; it is put back as the cloud would.
    static func cloudRow(_ fixture: [String: Any]) -> [String: Any] {
        var row = fixture
        row["_sealedChunksB64"] = nil
        if let versions = row["versions"] as? [[String: Any]] {
            row["versions"] = versions.map { v -> [String: Any] in
                var v = v
                if v["chunkBytes"] == nil { v["chunkBytes"] = VaultCrypto.chunkBytes }
                return v
            }
        }
        return row
    }

    @Test("Fixture: the fixture's feed row as written lacks chunkBytes, which the Mac's feed decoder requires")
    func feedRowAsWritten() throws {
        var row = try Self.json("feed-row.json")
        row["_sealedChunksB64"] = nil
        let versions = try #require(row["versions"] as? [[String: Any]])
        #expect(versions.allSatisfy { $0["chunkBytes"] == nil }, "if the generator now writes it, drop cloudRow's patch")
        let raw = try JSONSerialization.data(withJSONObject: row)
        #expect((try? JSONDecoder().decode(VaultClient.FeedFile.self, from: raw)) == nil)
        let real = try JSONSerialization.data(withJSONObject: Self.cloudRow(try Self.json("feed-row.json")))
        #expect((try? JSONDecoder().decode(VaultClient.FeedFile.self, from: real)) != nil)
    }

    @Test("Fixture: a desktop vault backup links the SAME record on the Mac — vaultFileId, hash, size; no new record, no hold")
    func desktopBackupAppliesOnMac() async throws {
        let inputs = try Self.json("inputs.json")
        let expected = try Self.json("expected.json")
        let after = try #require(expected["expectAfterVaultApply"] as? [String: Any])
        let wantNew = try #require(after["newRecords"] as? Int)
        let wantrecordId = try #require(after["recordId"] as? String)
        let wantvaultFileId = try #require(after["vaultFileId"] as? String)
        let wantcontentHash = try #require(after["contentHash"] as? String)
        let wantSize = try #require(after["sourceFileSize"] as? Int)
        let row = Self.cloudRow(try Self.json("feed-row.json"))
        let dek = try VaultCrypto.unhex(try #require(inputs["dekHex"] as? String))
        let keys = try VaultKeys(shopDek: dek)
        let fileId = try #require(row["fileId"] as? String)
        let versions = try #require(row["versions"] as? [[String: Any]])
        let uploadId = try #require(versions.first?["uploadId"] as? String)

        // The meta plaintext is the desktop's, exactly.
        let sealedMeta = try Self.b64(row["meta"])
        let opened = try VaultCrypto.decryptMeta(vaultKey: keys.vaultKey, fileId: fileId, uploadId: uploadId,
                                                 sealed: sealedMeta, lastSeenSeq: nil)
        let plain = try #require(try JSONSerialization.jsonObject(with: opened.json) as? [String: Any])
        let wantMeta = try #require(expected["metaPlain"] as? [String: Any])
        #expect(NSDictionary(dictionary: plain).isEqual(to: wantMeta), "meta: \(plain) vs \(wantMeta)")
        let meta = try JSONDecoder().decode(VaultMeta.self, from: opened.json)
        #expect(meta.recordId == nil, "the desktop's meta names no record: the folder in its key must find it")

        // And the bytes open to the model the desktop backed up.
        let model = try Self.b64(inputs["fileBytesB64"])
        let fixtureRow = try Self.json("feed-row.json")
        let chunk = try #require((fixtureRow["_sealedChunksB64"] as? [String: String])?["0"].flatMap { Data(base64Encoded: $0) })
        let dk = try VaultCrypto.unwrapDkForShop(vaultKey: keys.vaultKey,
                                                 wrapped: try Self.b64(versions[0]["wrappedKey"]),
                                                 fileId: fileId, uploadId: uploadId)
        let vm = try VaultCrypto.decryptVersionMeta(vaultKey: keys.vaultKey, fileId: fileId, uploadId: uploadId,
                                                    sealed: try Self.b64(versions[0]["versionMeta"]),
                                                    lastSeenSeq: nil)
        #expect(try VaultCrypto.decryptFile(dk: dk, fileId: fileId, uploadId: uploadId, sealedChunks: [chunk],
                                            size: vm.size, chunkHashes: vm.chunkHashes,
                                            expectedManifestHash: meta.manifestHash) == model)

        // This Mac: a book holding the desktop's record, a library with no
        // copy of it yet, and a vault whose feed holds the one row.
        let tmp = FileManager.default.temporaryDirectory.appending(path: "vault-backup-fixture-\(UUID().uuidString)")
        let libraryRoot = tmp.appending(path: "Library")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let feed = try JSONSerialization.data(withJSONObject: ["rev": 1, "more": false, "files": [row]] as [String: Any])
        let fetch: S3.Fetch = { r in
            let url = r.url!
            let ok = r.httpMethod == "GET" && url.path.hasSuffix("/vault/files")
            return (ok ? feed : Data(#"{"error":"unexpected"}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: ok ? 200 : 404, httpVersion: nil, headerFields: nil)!)
        }
        let client = VaultClient(connection: CloudReader.Connection(url: "https://cloud.test", shopId: "shop_1",
                                                                    storedToken: ""),
                                 token: "t", fetch: fetch)
        let sync = VaultSync(client: client, keys: keys, stateURL: tmp.appending(path: "vault-sync.json"),
                             deviceId: "mac-fixture")
        try await sync.pull()
        let pending = sync.pendingChanges()
        #expect(pending.count == 1)

        let recordJSON = try #require(inputs["record"] as? [String: Any])
        let record = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: recordJSON))
        var book: [String: JSONValue] = ["printFiles": .array([record])]
        let roots = LibraryLocation.Roots(primary: libraryRoot.path, mirror: nil, isCustom: false,
                                          roots: [libraryRoot.path])
        let library = Shop.vaultLibrary(rows: [record], roots: roots)
        let engine = try KhaytEngine()
        let out = await VaultApply.run(sync, library: library, engine: engine)
        #expect(out.problems.isEmpty, "\(out.problems)")
        #expect(out.held == 0, "held: the record was not found")
        #expect(after["held"] as? Bool == false)
        #expect(out.settled.count == 1)
        Shop.applyVaultEdits(out.edits, replaced: Set(out.replaced), at: "2026-11-06T00:00:00.000Z", to: &book)

        guard case .array(let rows)? = book["printFiles"] else { Issue.record("no printFiles"); return }
        #expect(rows.count == 1 + wantNew, "no new record")
        guard case .object(let r)? = rows.first else { Issue.record("no record"); return }
        #expect(r["id"] == .string(wantrecordId), "the SAME record")
        #expect(r["vaultFileId"] == .string(wantvaultFileId))
        #expect(r["contentHash"] == .string(wantcontentHash))
        guard case .object(let src)? = r["sourceFile"] else { Issue.record("no sourceFile"); return }
        #expect(src["size"] == .number(Double(wantSize)))
        #expect(src["filename"] == .string("Dragon.3MF"))
        // Found by the folder the desktop's key names, the Mac's itemDirName.
        let place = try #require(VaultApply.place(of: meta.key ?? ""))
        #expect(place.folder == LibraryLocation.itemDirName("PF-2026/ab:c d"))
        #expect(FileManager.default.fileExists(atPath: libraryRoot.appending(path: place.folder)
            .appending(path: "Dragon.3MF.cloud").path), "online here: a sidecar for the vault's copy")
    }
}
