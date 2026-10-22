import Foundation
import CryptoKit

/// Khayt Vault, the encryption for files a shop keeps in the cloud and shares
/// by link. The format is `docs/vault-format.md`. This file and
/// `lib/vault-crypto.js` are its two twins, and both are pinned to
/// `test/fixtures/vault-crypto-vectors.json`, which node:crypto writes
/// (`VaultCryptoTests`).
///
/// **Why a Swift twin and not the JS.** The Mac runs some of `lib/` in
/// JavaScriptCore, and JSC has no WebCrypto, so the browser module cannot run
/// here. CryptoKit has every primitive this needs (AES-GCM, HKDF, HMAC,
/// SHA-256). The one it lacks is scrypt, and `Scrypt` already provides it,
/// pinned against RFC 7914 and Node.
///
/// **The root key is the shop's DEK**, the same 32 bytes `SyncCrypto` opens the
/// store with and `CloudKeyMemory` keeps. `vaultKey` and `dedupeKey` are both
/// derived from it directly under separate labels, and the DEK itself is never
/// a vault cipher key.
///
/// Every function that draws randomness takes a `nonce:` override. It exists
/// ONLY so the shared vectors can be deterministic, and production never
/// passes it.
public enum VaultCrypto {

    public static let version = 1
    public static let chunkBytes = 4_194_304
    /// The largest file size either twin accepts: 2^53, where a JS number
    /// stops counting every integer.
    public static let maxSize = 1 << 53
    public static let keyBytes = 32
    public static let nonceBytes = 12
    public static let tagBytes = 16
    /// scrypt cost for a link password. Fixed by the format, not by a keyset.
    public static let linkScrypt = (n: 32768, r: 8, p: 1, length: 32)
    /// Unicode scalars, after NFC.
    public static let linkPasswordMinimum = 10

    public enum Label {
        public static let vaultSalt = "khayt-vault-v1"
        public static let vaultInfo = "vault"
        public static let dedupeInfo = "dedupe"
        public static let chunkInfo = "khayt-vault-chunk-v1"
        public static let chunkAad = "khayt-vault-v1"
        public static let dkAad = "khayt-vault-dk"
        public static let metaAad = "khayt-vault-meta"
        public static let linkInfo = "khayt-link-v1"
        public static let linkPwSalt = "khayt-link-pw"
        public static let linkDkAad = "khayt-link-dk"
        public static let linkMetaAad = "khayt-link-meta"
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case badInput(String)
        case authentication
        case manifestMismatch(String)
        case rollback(seq: Int, lastSeen: Int)
        case stream(String)

        public var description: String {
            switch self {
            case .badInput(let why): return "vault: \(why)"
            case .authentication:
                return "vault: authentication failed (wrong key, wrong position/ids, or tampered)"
            case .manifestMismatch(let why): return "vault: \(why)"
            case .rollback(let seq, let lastSeen):
                return "vault: meta seq \(seq) is older than the last seen \(lastSeen) (rollback)"
            case .stream(let why): return "vault: \(why)"
            }
        }
    }

    // MARK: - Bytes

    static func utf8(_ s: String) -> Data { Data(s.utf8) }

    public static func hex(_ d: some DataProtocol) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    public static func unhex(_ s: String) throws -> Data {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { throw Failure.badInput("bad hex") }
        var out = Data(capacity: chars.count / 2)
        func nib(_ c: UInt8) throws -> UInt8 {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: throw Failure.badInput("bad hex")
            }
        }
        var i = 0
        while i < chars.count {
            out.append(try nib(chars[i]) << 4 | nib(chars[i + 1]))
            i += 2
        }
        return out
    }

    public static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func unbase64url(_ s: String) throws -> Data {
        guard s.utf8.allSatisfy(isIdByte) else { throw Failure.badInput("bad base64url") }
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if t.count % 4 != 0 { t += String(repeating: "=", count: 4 - t.count % 4) }
        guard let d = Data(base64Encoded: t) else { throw Failure.badInput("bad base64url") }
        return d
    }

    static func random(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    static func key32(_ k: Data, _ what: String) throws -> Data {
        guard k.count == keyBytes else { throw Failure.badInput("\(what) must be \(keyBytes) bytes") }
        return Data(k) // a fresh, zero-based copy: slices of a Data keep their parent's indices
    }

    static func isIdByte(_ b: UInt8) -> Bool {
        (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 45 || b == 95
    }

    /// IDs go into `|`-joined AADs and an HKDF salt. Only `[A-Za-z0-9_-]{1,64}`
    /// is accepted, judged on the UTF-8 BYTES: an allow-list, because Swift's
    /// `String.contains("|")` compares by grapheme and misses "|" followed by a
    /// combining mark.
    static func id(_ v: String, _ what: String) throws -> String {
        let bytes = v.utf8
        guard (1...64).contains(bytes.count), bytes.allSatisfy(isIdByte) else {
            throw Failure.badInput("\(what) must be 1-64 of [A-Za-z0-9_-]")
        }
        return v
    }

    static func checkSize(_ size: Int) throws {
        guard size >= 0, size <= maxSize else { throw Failure.badInput("size must be an integer from 0 to 2^53") }
    }

    // MARK: - Primitives

    public static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    /// HKDF-SHA256 (RFC 5869). An empty salt means HashLen zero bytes, the
    /// same as WebCrypto and node:crypto.
    static func hkdf(_ ikm: Data, salt: Data, info: String, length: Int = keyBytes) -> Data {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                       info: utf8(info), outputByteCount: length)
        return k.withUnsafeBytes { Data($0) }
    }

    /// AES-256-GCM. Returns ct || tag(16).
    static func seal(_ key: Data, nonce: Data, _ plaintext: Data, aad: Data) throws -> Data {
        let k = SymmetricKey(data: try key32(key, "key"))
        let box = try AES.GCM.seal(plaintext, using: k, nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }

    /// Opens ct || tag(16). A wrong key, a wrong AAD and tampering all throw
    /// `.authentication`; GCM cannot tell them apart, and neither do we.
    static func open(_ key: Data, nonce: Data, _ sealed: Data, aad: Data) throws -> Data {
        let k = SymmetricKey(data: try key32(key, "key"))
        let s = Data(sealed)
        guard s.count >= tagBytes else { throw Failure.badInput("sealed data is shorter than its tag") }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: s.prefix(s.count - tagBytes),
                                            tag: s.suffix(tagBytes))
            return try AES.GCM.open(box, using: k, authenticating: aad)
        } catch {
            throw Failure.authentication
        }
    }

    /// nonce(12) || GCM(key, nonce, pt, aad) || tag(16).
    static func sealWithNonce(_ key: Data, _ plaintext: Data, aad: Data, nonce: Data?) throws -> Data {
        let n = nonce.map { Data($0) } ?? random(nonceBytes)
        guard n.count == nonceBytes else { throw Failure.badInput("nonce must be 12 bytes") }
        return n + (try seal(key, nonce: n, plaintext, aad: aad))
    }

    static func openWithNonce(_ key: Data, _ sealed: Data, aad: Data) throws -> Data {
        let s = Data(sealed)
        guard s.count >= nonceBytes + tagBytes else { throw Failure.badInput("sealed record too short") }
        return try open(key, nonce: s.prefix(nonceBytes), Data(s.dropFirst(nonceBytes)), aad: aad)
    }

    // MARK: - Keys

    /// vaultKey = HKDF(shop DEK, salt "khayt-vault-v1", info "vault").
    public static func vaultKey(shopDek: Data) throws -> Data {
        hkdf(try key32(shopDek, "shop DEK"), salt: utf8(Label.vaultSalt), info: Label.vaultInfo)
    }

    /// dedupeKey = HKDF(shop DEK, salt "khayt-vault-v1", info "dedupe"): a
    /// sibling of `vaultKey`, not derived from it.
    public static func dedupeKey(shopDek: Data) throws -> Data {
        hkdf(try key32(shopDek, "shop DEK"), salt: utf8(Label.vaultSalt), info: Label.dedupeInfo)
    }

    /// chunkKey = HKDF(DK, salt utf8(uploadId), info "khayt-vault-chunk-v1").
    public static func chunkKey(dk: Data, uploadId: String) throws -> Data {
        hkdf(try key32(dk, "data key"), salt: utf8(try id(uploadId, "uploadId")), info: Label.chunkInfo)
    }

    /// A fresh data key, once per UPLOAD ATTEMPT. Chunk nonces are counters,
    /// so they are unique only because this key is.
    public static func newDataKey() -> Data { random(keyBytes) }
    public static func newLinkSecret() -> Data { random(keyBytes) }

    /// Whether the UI should accept a link password: at least 10 Unicode
    /// scalars after NFC (the same count the JS twin makes). A leaked link
    /// with a short password falls to an offline guess at scrypt 2^15.
    public static func linkPasswordOk(_ password: String?) -> Bool {
        guard let password else { return false }
        return password.precomposedStringWithCanonicalMapping.unicodeScalars.count >= linkPasswordMinimum
    }

    /// linkKey for a grant. `password` has no default: `nil` must be written
    /// out for a link without one. An empty password is refused.
    public static func linkKey(linkSecret: Data, grantId: String, password: String?) throws -> Data {
        try linkKey(linkSecret: linkSecret, grantId: grantId, password: password, scryptN: linkScrypt.n)
    }

    /// Test-only cost override; `internal`, so only `@testable` code reaches it.
    static func linkKey(linkSecret: Data, grantId: String, password: String?, scryptN: Int) throws -> Data {
        let secret = try key32(linkSecret, "link secret")
        let salt = utf8(try id(grantId, "grantId"))
        guard let password else { return hkdf(secret, salt: salt, info: Label.linkInfo) }
        guard !password.isEmpty else {
            throw Failure.badInput("a link password must be non-empty (pass nil for none)")
        }
        let nfc = password.precomposedStringWithCanonicalMapping
        let p = try Scrypt.key(password: utf8(nfc), salt: utf8(Label.linkPwSalt + "|" + grantId),
                               n: scryptN, r: linkScrypt.r, p: linkScrypt.p, length: linkScrypt.length)
        return hkdf(secret + p, salt: salt, info: Label.linkInfo)
    }

    // MARK: - Dedupe

    /// hex(HMAC-SHA256(dedupeKey, sha256(plaintext))), from a digest the caller
    /// computed while streaming the file.
    public static func dedupeTag(shopDek: Data, plaintextSha256: Data) throws -> String {
        guard plaintextSha256.count == 32 else { throw Failure.badInput("digest must be 32 bytes") }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plaintextSha256),
                                                  using: SymmetricKey(data: try dedupeKey(shopDek: shopDek)))
        return hex(Data(mac))
    }

    public static func dedupeTag(shopDek: Data, plaintext: Data) throws -> String {
        try dedupeTag(shopDek: shopDek, plaintextSha256: sha256(plaintext))
    }

    // MARK: - Chunks

    /// 4 zero bytes, then the index as a big-endian u64.
    public static func chunkNonce(_ index: Int) throws -> Data {
        guard index >= 0 else { throw Failure.badInput("chunk index must be non-negative") }
        var n = Data(count: 4)
        withUnsafeBytes(of: UInt64(index).bigEndian) { n.append(contentsOf: $0) }
        return n
    }

    static func chunkAad(fileId: String, uploadId: String, index: Int, last: Bool) throws -> Data {
        utf8(Label.chunkAad + "|" + (try id(fileId, "fileId")) + "|" + (try id(uploadId, "uploadId"))
             + "|" + String(index) + "|" + (last ? "1" : "0"))
    }

    /// How many chunks a file of `size` bytes has. An empty file has one.
    /// Written without `size + chunkBytes - 1`, which overflows near Int.max.
    public static func chunkCount(size: Int, chunkBytes: Int = chunkBytes) throws -> Int {
        try checkSize(size)
        guard chunkBytes > 0 else { throw Failure.badInput("chunkBytes must be positive") }
        if size == 0 { return 1 }
        return size / chunkBytes + (size % chunkBytes == 0 ? 0 : 1)
    }

    /// Seal chunk `index` under the upload's chunk key. `last` is what makes a
    /// truncated file fail instead of reading as a shorter one.
    public static func encryptChunk(dk: Data, fileId: String, uploadId: String,
                                    index: Int, last: Bool, plaintext: Data) throws -> Data {
        let aad = try chunkAad(fileId: fileId, uploadId: uploadId, index: index, last: last)
        return try seal(try chunkKey(dk: dk, uploadId: uploadId), nonce: try chunkNonce(index), plaintext, aad: aad)
    }

    /// Open chunk `index` at the position the caller expects. A chunk from any
    /// other position, file or upload fails authentication.
    public static func decryptChunk(dk: Data, fileId: String, uploadId: String,
                                    index: Int, last: Bool, sealed: Data) throws -> Data {
        let aad = try chunkAad(fileId: fileId, uploadId: uploadId, index: index, last: last)
        return try open(try chunkKey(dk: dk, uploadId: uploadId), nonce: try chunkNonce(index), sealed, aad: aad)
    }

    /// hex sha256 of one sealed chunk (ct || tag), as the manifest lists it.
    public static func chunkHash(_ sealed: Data) -> String { hex(sha256(sealed)) }

    // MARK: - Manifest

    static func isHex64(_ h: String) -> Bool {
        h.utf8.count == 64 && h.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The exact manifest bytes: no spaces, keys in this order. Built by hand,
    /// because `JSONEncoder` promises neither. The size is checked first.
    public static func manifestJSON(size: Int, chunkHashes: [String], chunkBytes: Int = chunkBytes) throws -> String {
        let n = try chunkCount(size: size, chunkBytes: chunkBytes)
        guard chunkHashes.count == n else { throw Failure.badInput("chunk count does not match size") }
        guard chunkHashes.allSatisfy(isHex64) else { throw Failure.badInput("chunk hash must be 64 lowercase hex") }
        return "{\"v\":\(version),\"chunkBytes\":\(chunkBytes),\"size\":\(size),\"chunks\":["
            + chunkHashes.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
    }

    public static func manifestHash(size: Int, chunkHashes: [String], chunkBytes: Int = chunkBytes) throws -> String {
        hex(sha256(utf8(try manifestJSON(size: size, chunkHashes: chunkHashes, chunkBytes: chunkBytes))))
    }

    // MARK: - Streaming reader

    /// Opens a download chunk by chunk. The manifest is checked against a
    /// hash from an authenticated meta record when the reader is made; each
    /// `push` checks a chunk's hash, opens it at its position and returns its
    /// plaintext. `finish()` succeeds only once the chunk sealed with last=1
    /// has opened and the total equals `size`. A stream that ends early fails
    /// there, a chunk after the last is refused, and any failure is final.
    public struct ChunkReader {
        let dk: Data, fileId: String, uploadId: String
        let size: Int, chunkHashes: [String], chunkBytes: Int
        public private(set) var next = 0
        public private(set) var total = 0
        private var sawLast = false
        private var failed = false

        public var done: Bool { sawLast && !failed }

        public init(dk: Data, fileId: String, uploadId: String, size: Int, chunkHashes: [String],
                    expectedManifestHash: String, chunkBytes: Int = VaultCrypto.chunkBytes) throws {
            try VaultCrypto.checkSize(size)
            guard try VaultCrypto.manifestHash(size: size, chunkHashes: chunkHashes,
                                               chunkBytes: chunkBytes) == expectedManifestHash else {
                throw Failure.manifestMismatch("manifest does not match its hash")
            }
            self.dk = try VaultCrypto.key32(dk, "data key")
            self.fileId = try VaultCrypto.id(fileId, "fileId")
            self.uploadId = try VaultCrypto.id(uploadId, "uploadId")
            self.size = size; self.chunkHashes = chunkHashes; self.chunkBytes = chunkBytes
        }

        public mutating func push(_ sealed: Data) throws -> Data {
            guard !failed else { throw Failure.stream("reader already failed") }
            guard !sawLast else { failed = true; throw Failure.stream("chunk after the last chunk") }
            do {
                let i = next
                guard VaultCrypto.chunkHash(sealed) == chunkHashes[i] else {
                    throw Failure.manifestMismatch("chunk \(i) does not match the manifest")
                }
                let last = i == chunkHashes.count - 1
                let pt = try VaultCrypto.decryptChunk(dk: dk, fileId: fileId, uploadId: uploadId,
                                                      index: i, last: last, sealed: sealed)
                if !last, pt.count != chunkBytes { throw Failure.manifestMismatch("chunk \(i) is not full") }
                total += pt.count
                if last, total != size { throw Failure.manifestMismatch("size mismatch") }
                next = i + 1
                sawLast = last
                return pt
            } catch {
                failed = true
                throw error
            }
        }

        public func finish() throws -> (size: Int, chunks: Int) {
            guard !failed else { throw Failure.stream("reader failed") }
            guard sawLast else { throw Failure.stream("stream ended before the last chunk") }
            return (total, next)
        }
    }

    // MARK: - Whole-file conveniences (the same calls, in order)

    public struct SealedFile: Sendable {
        public let chunks: [Data]
        public let chunkHashes: [String]
        public let size: Int
        public let manifestHash: String
    }

    public static func encryptFile(dk: Data, fileId: String, uploadId: String, plaintext: Data,
                                   chunkBytes: Int = chunkBytes) throws -> SealedFile {
        let pt = Data(plaintext)
        let n = try chunkCount(size: pt.count, chunkBytes: chunkBytes)
        var chunks: [Data] = []
        var hashes: [String] = []
        for i in 0..<n {
            let part = pt.subdata(in: (i * chunkBytes)..<min(pt.count, (i + 1) * chunkBytes))
            let sealed = try encryptChunk(dk: dk, fileId: fileId, uploadId: uploadId,
                                          index: i, last: i == n - 1, plaintext: part)
            chunks.append(sealed)
            hashes.append(chunkHash(sealed))
        }
        return SealedFile(chunks: chunks, chunkHashes: hashes, size: pt.count,
                          manifestHash: try manifestHash(size: pt.count, chunkHashes: hashes, chunkBytes: chunkBytes))
    }

    /// Open a whole file through `ChunkReader`.
    public static func decryptFile(dk: Data, fileId: String, uploadId: String, sealedChunks: [Data],
                                   size: Int, chunkHashes: [String], expectedManifestHash: String,
                                   chunkBytes: Int = chunkBytes) throws -> Data {
        var r = try ChunkReader(dk: dk, fileId: fileId, uploadId: uploadId, size: size, chunkHashes: chunkHashes,
                                expectedManifestHash: expectedManifestHash, chunkBytes: chunkBytes)
        guard sealedChunks.count == chunkHashes.count else { throw Failure.manifestMismatch("chunk count mismatch") }
        var out = Data()
        for c in sealedChunks { out.append(try r.push(c)) }
        _ = try r.finish()
        return out
    }

    // MARK: - Key wraps

    /// nonce(12) || AES-GCM(kek, nonce, key, aad) || tag(16): 60 bytes.
    public static func wrapKey(kek: Data, key: Data, aad: Data, nonce: Data? = nil) throws -> Data {
        try sealWithNonce(kek, try key32(key, "wrapped key"), aad: aad, nonce: nonce)
    }

    public static func unwrapKey(kek: Data, wrapped: Data, aad: Data) throws -> Data {
        guard wrapped.count == nonceBytes + keyBytes + tagBytes else {
            throw Failure.badInput("wrapped key has the wrong length")
        }
        return try openWithNonce(kek, wrapped, aad: aad)
    }

    static func shopDkAad(fileId: String, uploadId: String) throws -> Data {
        utf8(Label.dkAad + "|" + (try id(fileId, "fileId")) + "|" + (try id(uploadId, "uploadId")))
    }

    static func grantDkAad(grantId: String, fileId: String) throws -> Data {
        utf8(Label.linkDkAad + "|" + (try id(grantId, "grantId")) + "|" + (try id(fileId, "fileId")))
    }

    public static func wrapDkForShop(vaultKey: Data, dk: Data, fileId: String, uploadId: String,
                                     nonce: Data? = nil) throws -> Data {
        try wrapKey(kek: vaultKey, key: dk, aad: try shopDkAad(fileId: fileId, uploadId: uploadId), nonce: nonce)
    }

    public static func unwrapDkForShop(vaultKey: Data, wrapped: Data, fileId: String, uploadId: String) throws -> Data {
        try unwrapKey(kek: vaultKey, wrapped: wrapped, aad: try shopDkAad(fileId: fileId, uploadId: uploadId))
    }

    public static func wrapDkForGrant(linkKey: Data, dk: Data, grantId: String, fileId: String,
                                      nonce: Data? = nil) throws -> Data {
        try wrapKey(kek: linkKey, key: dk, aad: try grantDkAad(grantId: grantId, fileId: fileId), nonce: nonce)
    }

    public static func unwrapDkForGrant(linkKey: Data, wrapped: Data, grantId: String, fileId: String) throws -> Data {
        try unwrapKey(kek: linkKey, wrapped: wrapped, aad: try grantDkAad(grantId: grantId, fileId: fileId))
    }

    // MARK: - Shop metadata record

    static func metaAad(fileId: String, uploadId: String) throws -> Data {
        utf8(Label.metaAad + "|" + (try id(fileId, "fileId")) + "|" + (try id(uploadId, "uploadId")))
    }

    /// 0 ≤ seq ≤ 2^53−1, the JS twin's `Number.isSafeInteger`: a JS reader
    /// cannot tell 2^53 from 2^53+1, so neither twin accepts either.
    public static let maxSeq = (1 << 53) - 1

    static func checkSeqValue(_ seq: Int) throws {
        guard seq >= 0, seq <= maxSeq else { throw Failure.badInput("meta seq must be an integer from 0 to 2^53-1") }
    }

    /// Refuse a meta record older than one this reader has already seen.
    /// Rollback (the server serving an earlier, validly sealed head) is caught
    /// ONLY by a reader that remembers its last-seen seq. `lastSeen: nil`
    /// means nothing is remembered. Returns the seq to remember.
    public static func checkMetaSeq(_ seq: Int, lastSeen: Int?) throws -> Int {
        try checkSeqValue(seq)
        if let lastSeen {
            try checkSeqValue(lastSeen)
            if seq < lastSeen { throw Failure.rollback(seq: seq, lastSeen: lastSeen) }
        }
        return seq
    }

    /// The integer `seq` of a meta record's JSON object. A boolean, a
    /// fraction, a string or a missing field is refused.
    public static func metaSeq(_ json: Data) throws -> Int {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Failure.badInput("meta record must be a JSON object")
        }
        guard let n = obj["seq"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            throw Failure.badInput("meta seq must be an integer from 0 to 2^53-1")
        }
        // Any Int64 above 2^53−1 converts to a double ≥ 2^53, so the bound
        // below refuses it rather than rounding it into range.
        let d = n.doubleValue
        guard d.rounded() == d, d >= 0, d <= Double(maxSeq) else {
            throw Failure.badInput("meta seq must be an integer from 0 to 2^53-1")
        }
        let seq = Int(d)
        try checkSeqValue(seq)
        return seq
    }

    /// nonce(12) || ct || tag(16) over the JSON bytes as given, aad
    /// "khayt-vault-meta|" + fileId + "|" + uploadId. The JSON must carry `seq`.
    public static func encryptMeta(vaultKey: Data, fileId: String, uploadId: String, json: Data,
                                   nonce: Data? = nil) throws -> Data {
        _ = try metaSeq(json)
        return try sealWithNonce(vaultKey, json, aad: try metaAad(fileId: fileId, uploadId: uploadId), nonce: nonce)
    }

    /// The record's JSON bytes, authenticated, with its seq checked against
    /// what this reader last saw.
    public static func decryptMeta(vaultKey: Data, fileId: String, uploadId: String, sealed: Data,
                                   lastSeenSeq: Int?) throws -> (json: Data, seq: Int) {
        let json = try openWithNonce(vaultKey, sealed, aad: try metaAad(fileId: fileId, uploadId: uploadId))
        let seq = try checkMetaSeq(try metaSeq(json), lastSeen: lastSeenSeq)
        return (json, seq)
    }

    // MARK: - Link metadata record

    /// What a share page opens with the linkKey: which upload to fetch and the
    /// authenticated manifestHash to pin it with.
    public struct LinkMeta: Codable, Equatable, Sendable {
        public let uploadId: String
        public let manifestHash: String
        public let name: String
        public let size: Int
        public let kind: String

        public init(uploadId: String, manifestHash: String, name: String, size: Int, kind: String) {
            self.uploadId = uploadId; self.manifestHash = manifestHash
            self.name = name; self.size = size; self.kind = kind
        }

        func validated() throws -> LinkMeta {
            _ = try VaultCrypto.id(uploadId, "uploadId")
            guard VaultCrypto.isHex64(manifestHash) else { throw Failure.badInput("link meta manifestHash") }
            try VaultCrypto.checkSize(size)
            return self
        }

        /// The bytes `JSON.stringify` writes for this object in the fixed key
        /// order {uploadId, manifestHash, name, size, kind}.
        public func canonicalJSON() throws -> Data {
            _ = try validated()
            let q = VaultCrypto.jsonString
            return VaultCrypto.utf8("{\"uploadId\":\(q(uploadId)),\"manifestHash\":\(q(manifestHash)),"
                                    + "\"name\":\(q(name)),\"size\":\(size),\"kind\":\(q(kind))}")
        }
    }

    /// A JSON string literal exactly as `JSON.stringify` writes one for
    /// well-formed Unicode: `"` and `\` escaped, the five short escapes, other
    /// controls as lowercase `\u00xx`, everything else verbatim.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    static func linkMetaAad(grantId: String, fileId: String) throws -> Data {
        utf8(Label.linkMetaAad + "|" + (try id(grantId, "grantId")) + "|" + (try id(fileId, "fileId")))
    }

    public static func encryptLinkMeta(linkKey: Data, grantId: String, fileId: String, meta: LinkMeta,
                                       nonce: Data? = nil) throws -> Data {
        try sealWithNonce(linkKey, try meta.canonicalJSON(), aad: try linkMetaAad(grantId: grantId, fileId: fileId),
                          nonce: nonce)
    }

    public static func decryptLinkMeta(linkKey: Data, grantId: String, fileId: String, sealed: Data) throws -> LinkMeta {
        let json = try openWithNonce(linkKey, sealed, aad: try linkMetaAad(grantId: grantId, fileId: fileId))
        guard let m = try? JSONDecoder().decode(LinkMeta.self, from: json) else {
            throw Failure.badInput("link meta must be a JSON object with uploadId, manifestHash, name, size, kind")
        }
        return try m.validated()
    }
}
