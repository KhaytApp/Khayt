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
            let shopWrapNonce, grantWrapNonce, metaNonce, metaJson, linkMetaNonce: String
        }
        struct Derived: Decodable {
            let vaultKey, chunkKey, dedupeKey, linkKeyNoPassword, passwordNfcHex, linkPasswordScrypt,
                linkKeyPassword: String
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
        struct LinkMetaVec: Decodable { let aad, nonce, json, sealedNoPassword, sealedPassword: String }

        let inputs: Inputs
        let derived: Derived
        let files: [File]
        let wraps: Wraps
        let meta: Meta
        let linkMeta: LinkMetaVec
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
    var dek: Data { Self.h(v.inputs.shopDek) }
    var vaultKey: Data { Self.h(v.derived.vaultKey) }

    // MARK: - Vectors

    @Test("vault key, dedupe key (both from the DEK) and the per-upload chunk key")
    func keys() throws {
        #expect(Self.hex(try VaultCrypto.vaultKey(shopDek: dek)) == v.derived.vaultKey)
        #expect(Self.hex(try VaultCrypto.dedupeKey(shopDek: dek)) == v.derived.dedupeKey)
        #expect(v.derived.dedupeKey != v.derived.vaultKey)
        #expect(Self.hex(try VaultCrypto.chunkKey(dk: dk, uploadId: v.inputs.uploadId)) == v.derived.chunkKey)
        #expect(Self.hex(try VaultCrypto.chunkKey(dk: dk, uploadId: "u_other")) != v.derived.chunkKey)
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
            #expect(try VaultCrypto.dedupeTag(shopDek: dek, plaintext: pt) == f.dedupeTag, "\(f.name)")

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

    @Test("linkPasswordOk: at least 10 Unicode scalars after NFC, the JS twin's count")
    func linkPasswordOk() {
        #expect(!VaultCrypto.linkPasswordOk("123456789"))
        #expect(VaultCrypto.linkPasswordOk("1234567890"))
        #expect(VaultCrypto.linkPasswordOk("abcdefghie\u{301}"))   // 10 after NFC
        #expect(!VaultCrypto.linkPasswordOk("abcdefghe\u{301}"))   // 9 after NFC
        #expect(VaultCrypto.linkPasswordOk(String(repeating: "\u{1F600}", count: 10)))
        #expect(!VaultCrypto.linkPasswordOk(nil))
    }

    @Test("shop meta record: byte for byte, seq, and back")
    func meta() throws {
        let fid = v.inputs.fileId, uid = v.inputs.uploadId
        let sealed = try VaultCrypto.encryptMeta(vaultKey: vaultKey, fileId: fid, uploadId: uid,
                                                 json: Data(v.meta.json.utf8), nonce: Self.h(v.meta.nonce))
        #expect(Self.hex(sealed) == v.meta.sealed)
        let back = try VaultCrypto.decryptMeta(vaultKey: vaultKey, fileId: fid, uploadId: uid, sealed: sealed,
                                               lastSeenSeq: 7)
        #expect(String(decoding: back.json, as: UTF8.self) == v.meta.json)
        #expect(back.seq == 7)
        #expect(throws: VaultCrypto.Failure.rollback(seq: 7, lastSeen: 8)) {
            try VaultCrypto.decryptMeta(vaultKey: vaultKey, fileId: fid, uploadId: uid, sealed: sealed, lastSeenSeq: 8)
        }
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.decryptMeta(vaultKey: vaultKey, fileId: "f_other", uploadId: uid, sealed: sealed, lastSeenSeq: nil)
        }
        #expect(throws: VaultCrypto.Failure.authentication) {
            try VaultCrypto.decryptMeta(vaultKey: vaultKey, fileId: fid, uploadId: "u_other", sealed: sealed, lastSeenSeq: nil)
        }
        for bad in [#"{"name":"x"}"#, #"{"seq":1.5}"#, #"{"seq":true}"#, #"{"seq":"1"}"#, #"{"seq":-1}"#, "[1]"] {
            #expect(throws: VaultCrypto.Failure.self, "\(bad)") {
                try VaultCrypto.encryptMeta(vaultKey: vaultKey, fileId: fid, uploadId: uid, json: Data(bad.utf8))
            }
        }
    }

    @Test("checkMetaSeq: equal is fine, lower is a rollback, nothing remembered accepts")
    func seq() throws {
        #expect(try VaultCrypto.checkMetaSeq(5, lastSeen: nil) == 5)
        #expect(try VaultCrypto.checkMetaSeq(5, lastSeen: 5) == 5)
        #expect(try VaultCrypto.checkMetaSeq(6, lastSeen: 5) == 6)
        #expect(throws: VaultCrypto.Failure.rollback(seq: 4, lastSeen: 5)) { try VaultCrypto.checkMetaSeq(4, lastSeen: 5) }
        #expect(throws: VaultCrypto.Failure.self) { try VaultCrypto.checkMetaSeq(-1, lastSeen: nil) }
    }

    @Test("link meta record: byte for byte under both link keys, validated, and the share-page path")
    func linkMeta() throws {
        let want = try JSONDecoder().decode(VaultCrypto.LinkMeta.self, from: Data(v.linkMeta.json.utf8))
        #expect(String(decoding: try want.canonicalJSON(), as: UTF8.self) == v.linkMeta.json)
        let gid = v.inputs.grantId, fid = v.inputs.fileId
        for (key, sealedHex) in [(v.derived.linkKeyNoPassword, v.linkMeta.sealedNoPassword),
                                 (v.derived.linkKeyPassword, v.linkMeta.sealedPassword)] {
            let lk = Self.h(key)
            let sealed = try VaultCrypto.encryptLinkMeta(linkKey: lk, grantId: gid, fileId: fid, meta: want,
                                                         nonce: Self.h(v.linkMeta.nonce))
            #expect(Self.hex(sealed) == sealedHex)
            #expect(try VaultCrypto.decryptLinkMeta(linkKey: lk, grantId: gid, fileId: fid, sealed: sealed) == want)
            #expect(throws: VaultCrypto.Failure.authentication) {
                try VaultCrypto.decryptLinkMeta(linkKey: lk, grantId: "g_other", fileId: fid, sealed: sealed)
            }
            #expect(throws: VaultCrypto.Failure.authentication) {
                try VaultCrypto.decryptLinkMeta(linkKey: lk, grantId: gid, fileId: "f_other", sealed: sealed)
            }
        }
        // link meta → pinned manifestHash → file
        let lk = Self.h(v.derived.linkKeyNoPassword)
        let lm = try VaultCrypto.decryptLinkMeta(linkKey: lk, grantId: gid, fileId: fid,
                                                 sealed: Self.h(v.linkMeta.sealedNoPassword))
        let gdk = try VaultCrypto.unwrapDkForGrant(linkKey: lk, wrapped: Self.h(v.wraps.grantNoPassword.wrapped),
                                                   grantId: gid, fileId: fid)
        let pt = try VaultCrypto.decryptFile(dk: gdk, fileId: fid, uploadId: lm.uploadId,
                                             sealedChunks: f25.chunks.map { Self.h($0.sealed!) }, size: lm.size,
                                             chunkHashes: f25.chunks.map(\.sha256),
                                             expectedManifestHash: lm.manifestHash, chunkBytes: 16)
        #expect(pt == Self.plaintext(40))
        let bad = VaultCrypto.LinkMeta(uploadId: "a|b", manifestHash: want.manifestHash, name: "", size: 1, kind: "")
        #expect(throws: VaultCrypto.Failure.self) {
            try VaultCrypto.encryptLinkMeta(linkKey: lk, grantId: gid, fileId: fid, meta: bad)
        }
    }

    @Test("jsonString writes what JSON.stringify writes")
    func jsonEscapes() {
        #expect(VaultCrypto.jsonString("a\"b\\c\n\t\u{01}\u{1F}/é") == #""a\"b\\c\n\t\u0001\u001f/é""#)
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
        let forged = try VaultCrypto.manifestHash(size: f25.size, chunkHashes: swapped, chunkBytes: 16)
        #expect(throws: VaultCrypto.Failure.authentication) {
            try open(reordered, size: f25.size, swapped, pinned: forged)
        }
        let short = Array(hashes.prefix(2))
        let shortPin = try VaultCrypto.manifestHash(size: 32, chunkHashes: short, chunkBytes: 16)
        #expect(throws: VaultCrypto.Failure.authentication) {
            try open(Array(chunks.prefix(2)), size: 32, short, pinned: shortPin)
        }
        #expect(throws: VaultCrypto.Failure.badInput("chunk count does not match size")) {
            try open(Array(chunks.prefix(2)), size: f25.size, short, pinned: f25.manifestHash)
        }
    }

    @Test("streaming reader: succeeds only after the last chunk; refuses early end and extra chunks")
    func reader() throws {
        let hashes = f25.chunks.map(\.sha256)
        func make() throws -> VaultCrypto.ChunkReader {
            try VaultCrypto.ChunkReader(dk: dk, fileId: v.inputs.fileId, uploadId: v.inputs.uploadId,
                                        size: f25.size, chunkHashes: hashes,
                                        expectedManifestHash: f25.manifestHash, chunkBytes: 16)
        }
        var r = try make()
        _ = try r.push(sealed(0))
        _ = try r.push(sealed(1))
        #expect(!r.done)
        #expect(throws: VaultCrypto.Failure.stream("stream ended before the last chunk")) { try r.finish() }
        _ = try r.push(sealed(2))
        #expect(r.done)
        #expect(try r.finish() == (40, 3))
        #expect(throws: VaultCrypto.Failure.stream("chunk after the last chunk")) { try r.push(sealed(2)) }
        #expect(throws: VaultCrypto.Failure.stream("reader failed")) { try r.finish() }

        var r2 = try make()
        #expect(throws: VaultCrypto.Failure.self) { try r2.push(sealed(1)) }
        #expect(throws: VaultCrypto.Failure.stream("reader already failed")) { try r2.push(sealed(0)) }

        let e = try #require(v.files.first { $0.name == "empty" })
        var r3 = try VaultCrypto.ChunkReader(dk: dk, fileId: v.inputs.fileId, uploadId: v.inputs.uploadId, size: 0,
                                             chunkHashes: [e.chunks[0].sha256], expectedManifestHash: e.manifestHash,
                                             chunkBytes: 16)
        #expect(throws: VaultCrypto.Failure.stream("stream ended before the last chunk")) { try r3.finish() }
        #expect(try r3.push(Self.h(e.chunks[0].sealed!)).isEmpty)
        #expect(try r3.finish() == (0, 1))
    }

    @Test("sizes above 2^53 are refused before anything else, and chunkCount cannot overflow")
    func hugeSizes() throws {
        let tooBig = [Int.max, Int.max - 1, (1 << 53) + 1, 1 << 60]
        for size in tooBig {
            #expect(throws: VaultCrypto.Failure.self) { try VaultCrypto.chunkCount(size: size) }
            #expect(throws: VaultCrypto.Failure.badInput("size must be an integer from 0 to 2^53")) {
                try VaultCrypto.manifestJSON(size: size, chunkHashes: ["junk"])
            }
            #expect(throws: VaultCrypto.Failure.badInput("size must be an integer from 0 to 2^53")) {
                try VaultCrypto.ChunkReader(dk: dk, fileId: "f", uploadId: "u", size: size,
                                            chunkHashes: ["junk"], expectedManifestHash: "x")
            }
        }
        #expect(throws: VaultCrypto.Failure.self) { try VaultCrypto.chunkCount(size: -1) }
        #expect(try VaultCrypto.chunkCount(size: 1 << 53) == (1 << 53) / VaultCrypto.chunkBytes)
        #expect(try VaultCrypto.chunkCount(size: (1 << 53) - 1, chunkBytes: 3) == ((1 << 53) - 1) / 3 + 1)
        #expect(try VaultCrypto.chunkCount(size: 1 << 53, chunkBytes: 1) == 1 << 53)
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

    @Test("ids: only [A-Za-z0-9_-]{1,64}, judged on bytes")
    func ids() throws {
        // "|" + a combining mark is ONE grapheme, so String.contains("|") is false for it.
        let pipeCombining = "a|\u{301}b"
        #expect(!pipeCombining.contains("|"))
        // A lone surrogate cannot live in a Swift String; decoding one yields U+FFFD.
        let loneSurrogate = String(decoding: [0xED, 0xA0, 0x80] as [UInt8], as: UTF8.self)
        let bad = ["a|b", pipeCombining, loneSurrogate, "", String(repeating: "x", count: 65), "caf\u{E9}",
                   "a b", "a.b", "a/b", "\u{661}", "a\u{0}"]
        for b in bad {
            #expect(throws: VaultCrypto.Failure.self, "\(b.unicodeScalars.map { $0.value })") {
                try VaultCrypto.encryptChunk(dk: dk, fileId: b, uploadId: "u", index: 0, last: true, plaintext: Data())
            }
            #expect(throws: VaultCrypto.Failure.self) {
                try VaultCrypto.encryptChunk(dk: dk, fileId: "f", uploadId: b, index: 0, last: true, plaintext: Data())
            }
            #expect(throws: VaultCrypto.Failure.self) {
                try VaultCrypto.wrapDkForGrant(linkKey: vaultKey, dk: dk, grantId: b, fileId: "f")
            }
        }
        _ = try VaultCrypto.encryptChunk(dk: dk, fileId: String(repeating: "x", count: 64), uploadId: "A-z_0",
                                         index: 0, last: true, plaintext: Data())
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
