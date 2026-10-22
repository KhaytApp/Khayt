import Foundation
import Testing
@testable import KhaytCore

/// `VaultCrypto` against `test/fixtures/vault-crypto-vectors.json`.
///
/// node:crypto writes that file (`scripts/gen-vault-crypto-vectors.js`), not
/// either twin, and `test/vault-crypto.test.js` checks the WebCrypto twin
/// against the same bytes. A pass on both sides means the Mac and the cloud's
/// browser page read and write the same vault.
struct VaultCryptoTests {

    // MARK: - The fixture

    struct Vectors: Decodable {
        struct Inputs: Decodable {
            let shopDek, dk, fileId, uploadId, grantId, linkSecret, password: String
            let shopWrapNonce, grantWrapNonce, metaNonce, metaJson: String
        }
        struct Derived: Decodable {
            let vaultKey, dedupeKey, linkKeyNoPassword, passwordNfcHex, linkPasswordScrypt, linkKeyPassword: String
        }
        struct Chunk: Decodable {
            let index: Int
            let last: Bool
            let plainBytes: Int
            let sha256: String
            let sealed: String?
        }
        struct File: Decodable {
            let name: String
            let size, chunkBytes: Int
            let plaintextSha256: String
            let chunks: [Chunk]
            let manifestJson, manifestHash, dedupeTag: String
        }
        struct Wrap: Decodable { let aad, nonce, wrapped: String }
        struct Wraps: Decodable { let shop, grantNoPassword, grantPassword: Wrap }
        struct Meta: Decodable { let aad, nonce, json, sealed: String }

        let inputs: Inputs
        let derived: Derived
        let files: [File]
        let wraps: Wraps
        let meta: Meta
    }

    static let v: Vectors = {
        let url = URL(fileURLWithPath: #filePath)   // …/mac/KhaytCore/Tests/KhaytCoreTests/x.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test/fixtures/vault-crypto-vectors.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    static func h(_ s: String) -> Data { try! VaultCrypto.unhex(s) }  // swiftlint:disable:this force_try
    static func hex(_ d: Data) -> String { VaultCrypto.hex(d) }
    static func plaintext(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    var v: Vectors { Self.v }
    var dk: Data { Self.h(v.inputs.dk) }
    var vaultKey: Data { Self.h(v.derived.vaultKey) }

    // MARK: - Vectors

    @Test("vault key and dedupe key from the shop DEK")
    func keys() throws {
        let vk = try VaultCrypto.vaultKey(shopDek: Self.h(v.inputs.shopDek))
        #expect(Self.hex(vk) == v.derived.vaultKey)
        #expect(Self.hex(try VaultCrypto.dedupeKey(vaultKey: vk)) == v.derived.dedupeKey)
    }

    @Test("every file case: chunks, hashes, manifest, dedupe tag, round trip")
    func files() throws {
        for f in v.files {
            let pt = Self.plaintext(f.size)
            #expect(Self.hex(VaultCrypto.sha256(pt)) == f.plaintextSha256, "\(f.name)")
            #expect(try VaultCrypto.chunkCount(size: f.size, chunkBytes: f.chunkBytes) == f.chunks.count, "\(f.name)")
            let out = try VaultCrypto.encryptFile(dk: dk, fileId: v.inputs.fileId, uploadId: v.inputs.uploadId,
                                                  plaintext: pt, chunkBytes: f.chunkBytes)
            #expect(out.chunks.count == f.chunks.count, "\(f.name)")
            for (i, c) in f.chunks.enumerated() {
                #expect(out.chunks[i].count == c.plainBytes + 16, "\(f.name) chunk \(i)")
                if let sealed = c.sealed { #expect(Self.hex(out.chunks[i]) == sealed, "\(f.name) chunk \(i)") }
                #expect(out.chunkHashes[i] == c.sha256, "\(f.name) chunk \(i) hash")
            }
            #expect(try VaultCrypto.manifestJSON(size: f.size, chunkHashes: out.chunkHashes,
                                                 chunkBytes: f.chunkBytes) == f.manifestJson, "\(f.name)")
            #expect(out.manifestHash == f.manifestHash, "\(f.name)")
            #expect(try VaultCrypto.dedupeTag(vaultKey: vaultKey, plaintext: pt) == f.dedupeTag, "\(f.name)")

            let back = try VaultCrypto.decryptFile(dk: dk, fileId: v.inputs.fileId, uploadId: v.inputs.uploadId,
                                                   sealedChunks: out.chunks, size: f.size,
                                                   chunkHashes: out.chunkHashes,
                                                   expectedManifestHash: f.manifestHash, chunkBytes: f.chunkBytes)
            #expect(back == pt, "\(f.name) round trip")
        }
    }

    @Test("the real 4 MiB case is cut at 4194304 by default")
    func realChunkSize() throws {
        let f = try #require(v.files.first { $0.name == "real-4mib-plus-one" })
        #expect(f.chunkBytes == VaultCrypto.chunkBytes)
        let out = try VaultCrypto.encryptFile(dk: dk, fileId: v.inputs.fileId, uploadId: v.inputs.uploadId,
                                              plaintext: Self.plaintext(f.size))
        #expect(out.manifestHash == f.manifestHash)
    }

    @Test("key wraps: shop and both grants, byte for byte, and back")
    func wraps() throws {
        let w = try VaultCrypto.wrapDkForShop(vaultKey: vaultKey, dk: dk, fileId: v.inputs.fileId,
                                              uploadId: v.inputs.uploadId, nonce: Self.h(v.wraps.shop.nonce))
        #expect(Self.hex(w) == v.wraps.shop.wrapped)
        #expect(w.count == 60)
        #expect(try VaultCrypto.unwrapDkForShop(vaultKey: vaultKey, wrapped: w, fileId: v.inputs.fileId,
                                                uploadId: v.inputs.uploadId) == dk)
        for (wrap, key) in [(v.wraps.grantNoPassword, v.derived.linkKeyNoPassword),
                            (v.wraps.grantPassword, v.derived.linkKeyPassword)] {
            let g = try VaultCrypto.wrapDkForGrant(linkKey: Self.h(key), dk: dk, grantId: v.inputs.grantId,
                                                   fileId: v.inputs.fileId, nonce: Self.h(wrap.nonce))
            #expect(Self.hex(g) == wrap.wrapped)
            #expect(try VaultCrypto.unwrapDkForGrant(linkKey: Self.h(key), wrapped: g, grantId: v.inputs.grantId,
                                                     fileId: v.inputs.fileId) == dk)
        }
    }

    /// The password path runs the Mac's existing `Scrypt` (pinned in `ScryptTests`)
    /// at the real N = 2^15; the fixture also carries the bare scrypt output
    /// (`linkPasswordScrypt`) for telling a scrypt fault from an HKDF one.
    @Test("link keys: no password, and a non-NFC password at the real scrypt cost")
    func linkKeys() throws {
        let s = Self.h(v.inputs.linkSecret)
        #expect(Self.hex(try VaultCrypto.linkKey(linkSecret: s, grantId: v.inputs.grantId, password: nil))
                == v.derived.linkKeyNoPassword)
        // The vector password is decomposed on purpose (String == compares canonically, so compare bytes).
        #expect(Array(v.inputs.password.utf8) != Array(v.inputs.password.precomposedStringWithCanonicalMapping.utf8))
        #expect(Self.hex(Data(v.inputs.password.precomposedStringWithCanonicalMapping.utf8)) == v.derived.passwordNfcHex)
        #expect(Self.hex(try VaultCrypto.linkKey(linkSecret: s, grantId: v.inputs.grantId, password: v.inputs.password))
                == v.derived.linkKeyPassword)
        #expect(throws: VaultCrypto.Failure.self) {
            try VaultCrypto.linkKey(linkSecret: s, grantId: v.inputs.grantId, password: "")
        }
    }

    @Test("meta record: byte for byte, and back")
    func meta() throws {
        let sealed = try VaultCrypto.encryptMeta(vaultKey: vaultKey, fileId: v.inputs.fileId,
                                                 json: Data(v.meta.json.utf8), nonce: Self.h(v.meta.nonce))
        #expect(Self.hex(sealed) == v.meta.sealed)
        let back = try VaultCrypto.decryptMeta(vaultKey: vaultKey, fileId: v.inputs.fileId, sealed: sealed)
        #expect(String(decoding: back, as: UTF8.self) == v.meta.json)
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.decryptMeta(vaultKey: vaultKey, fileId: "f_other", sealed: sealed)
        }
    }

    // MARK: - Tamper rejection

    var f25: Vectors.File { v.files.first { $0.name == "two-and-a-half-chunks" }! }
    func sealed(_ i: Int) -> Data { Self.h(f25.chunks[i].sealed!) }

    func refuses(_ index: Int, last: Bool, _ data: Data, fileId: String? = nil, uploadId: String? = nil,
                 key: Data? = nil) {
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.decryptChunk(dk: key ?? dk, fileId: fileId ?? v.inputs.fileId,
                                         uploadId: uploadId ?? v.inputs.uploadId,
                                         index: index, last: last, sealed: data)
        }
    }

    @Test("each chunk opens at its own position")
    func ownPosition() throws {
        let pt = Self.plaintext(f25.size)
        for c in f25.chunks {
            let got = try VaultCrypto.decryptChunk(dk: dk, fileId: v.inputs.fileId, uploadId: v.inputs.uploadId,
                                                   index: c.index, last: c.last, sealed: Self.h(c.sealed!))
            #expect(got == pt.subdata(in: (c.index * 16)..<(c.index * 16 + c.plainBytes)))
        }
    }

    @Test("rejects a wrong index")
    func wrongIndex() {
        refuses(1, last: false, sealed(0))
        refuses(0, last: false, sealed(1))
    }

    @Test("rejects truncation and extension: the last flag is authenticated")
    func lastFlag() {
        refuses(1, last: true, sealed(1))
        refuses(2, last: false, sealed(2))
    }

    @Test("rejects a wrong file id, upload id, key, or a flipped bit")
    func wrongContext() {
        refuses(0, last: false, sealed(0), fileId: "f_other")
        refuses(0, last: false, sealed(0), uploadId: "u_other")
        refuses(0, last: false, sealed(0), key: VaultCrypto.newDataKey())
        var bad = sealed(0); bad[3] ^= 1
        refuses(0, last: false, bad)
        var badTag = sealed(0); badTag[badTag.count - 1] ^= 0x80
        refuses(0, last: false, badTag)
    }

    @Test("decryptFile rejects reordering, a dropped last chunk and a forged manifest")
    func wholeFile() throws {
        let chunks = f25.chunks.map { Self.h($0.sealed!) }
        let hashes = f25.chunks.map(\.sha256)
        let swapped = [hashes[1], hashes[0], hashes[2]]
        let reordered = [chunks[1], chunks[0], chunks[2]]
        func open(_ c: [Data], size: Int, _ h: [String], pinned: String) throws -> Data {
            try VaultCrypto.decryptFile(dk: dk, fileId: v.inputs.fileId, uploadId: v.inputs.uploadId,
                                        sealedChunks: c, size: size, chunkHashes: h,
                                        expectedManifestHash: pinned, chunkBytes: 16)
        }
        #expect(throws: VaultCrypto.Failure.manifestMismatch("chunk 0 does not match the manifest")) {
            try open(reordered, size: f25.size, hashes, pinned: f25.manifestHash)
        }
        #expect(throws: VaultCrypto.Failure.manifestMismatch("manifest does not match its hash")) {
            try open(reordered, size: f25.size, swapped, pinned: f25.manifestHash)
        }
        // Even a forged manifest that is somehow pinned cannot reorder: the AAD carries the index.
        let forged = try VaultCrypto.manifestHash(size: f25.size, chunkHashes: swapped, chunkBytes: 16)
        #expect(throws: VaultCrypto.Failure.authentication) {
            try open(reordered, size: f25.size, swapped, pinned: forged)
        }
        // A consistently shortened manifest cannot truncate: chunk 1 was sealed as not-last.
        let short = Array(hashes.prefix(2))
        let shortPin = try VaultCrypto.manifestHash(size: 32, chunkHashes: short, chunkBytes: 16)
        #expect(throws: VaultCrypto.Failure.authentication) {
            try open(Array(chunks.prefix(2)), size: 32, short, pinned: shortPin)
        }
        #expect(throws: VaultCrypto.Failure.badInput("chunk count does not match size")) {
            try open(Array(chunks.prefix(2)), size: f25.size, short, pinned: f25.manifestHash)
        }
    }

    @Test("wraps refuse a wrong aad, a wrong kek and a tampered nonce")
    func wrapTamper() {
        let w = Self.h(v.wraps.shop.wrapped)
        let fid = v.inputs.fileId, uid = v.inputs.uploadId
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.unwrapDkForShop(vaultKey: vaultKey, wrapped: w, fileId: fid, uploadId: "u_other")
        }
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.unwrapDkForShop(vaultKey: vaultKey, wrapped: w, fileId: "f_other", uploadId: uid)
        }
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.unwrapDkForShop(vaultKey: Self.h(v.derived.dedupeKey), wrapped: w, fileId: fid, uploadId: uid)
        }
        var t = w; t[0] ^= 1
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.unwrapDkForShop(vaultKey: vaultKey, wrapped: t, fileId: fid, uploadId: uid)
        }
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.unwrapDkForGrant(linkKey: vaultKey, wrapped: w, grantId: v.inputs.grantId, fileId: fid)
        }
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.unwrapDkForGrant(linkKey: Self.h(v.derived.linkKeyNoPassword),
                                             wrapped: Self.h(v.wraps.grantPassword.wrapped),
                                             grantId: v.inputs.grantId, fileId: fid)
        }
    }

    @Test("ids containing \"|\" are refused")
    func pipeInIds() {
        #expect(throws: VaultCrypto.Failure.self) {
            try VaultCrypto.encryptChunk(dk: dk, fileId: "a|b", uploadId: "c", index: 0, last: true, plaintext: Data())
        }
        #expect(throws: VaultCrypto.Failure.self) {
            try VaultCrypto.wrapDkForShop(vaultKey: dk, dk: dk, fileId: "a", uploadId: "b|c")
        }
    }

    @Test("random paths differ and round-trip; base64url has no + / =")
    func randomPaths() throws {
        let a = VaultCrypto.newDataKey(), b = VaultCrypto.newDataKey()
        #expect(a.count == 32 && a != b)
        let w1 = try VaultCrypto.wrapDkForShop(vaultKey: vaultKey, dk: a, fileId: "f", uploadId: "u")
        let w2 = try VaultCrypto.wrapDkForShop(vaultKey: vaultKey, dk: a, fileId: "f", uploadId: "u")
        #expect(w1.prefix(12) != w2.prefix(12))
        #expect(try VaultCrypto.unwrapDkForShop(vaultKey: vaultKey, wrapped: w1, fileId: "f", uploadId: "u") == a)
        let s = VaultCrypto.newLinkSecret()
        let enc = VaultCrypto.base64url(s)
        #expect(!enc.contains("+") && !enc.contains("/") && !enc.contains("="))
        #expect(try VaultCrypto.unbase64url(enc) == s)
    }
}
