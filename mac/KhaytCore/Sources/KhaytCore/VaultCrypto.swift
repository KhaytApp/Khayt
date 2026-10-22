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
/// store with and `CloudKeyMemory` keeps. HKDF with the vault's own salt and
/// label separates the vault key from it, so the DEK is never used as a vault
/// cipher key.
///
/// Every function that draws randomness takes a `nonce:` override. It exists
/// ONLY so the shared vectors can be deterministic, and production never
/// passes it.
public enum VaultCrypto {

    public static let version = 1
    public static let chunkBytes = 4_194_304
    public static let keyBytes = 32
    public static let nonceBytes = 12
    public static let tagBytes = 16
    /// scrypt cost for a link password. Fixed by the format, not by a keyset.
    public static let linkScrypt = (n: 32768, r: 8, p: 1, length: 32)

    public enum Label {
        public static let vaultSalt = "khayt-vault-v1"
        public static let vaultInfo = "vault"
        public static let dedupeInfo = "khayt-vault-dedupe-v1"
        public static let chunkAad = "khayt-vault-v1"
        public static let dkAad = "khayt-vault-dk"
        public static let metaAad = "khayt-vault-meta"
        public static let linkInfo = "khayt-link-v1"
        public static let linkPwSalt = "khayt-link-pw"
        public static let linkDkAad = "khayt-link-dk"
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case badInput(String)
        case authentication
        case manifestMismatch(String)

        public var description: String {
            switch self {
            case .badInput(let why): return "vault: \(why)"
            case .authentication:
                return "vault: authentication failed (wrong key, wrong position/ids, or tampered)"
            case .manifestMismatch(let why): return "vault: \(why)"
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
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw Failure.badInput("bad base64url")
        }
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

    /// IDs go into `|`-joined AAD strings. One containing `|` would let two
    /// different (fileId, uploadId) pairs share an AAD, so it is refused.
    static func id(_ v: String, _ what: String) throws -> String {
        guard !v.isEmpty else { throw Failure.badInput("\(what) must be a non-empty string") }
        guard !v.contains("|") else { throw Failure.badInput("\(what) must not contain \"|\"") }
        return v
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

    // MARK: - Keys

    /// vaultKey = HKDF(shop DEK, salt "khayt-vault-v1", info "vault").
    public static func vaultKey(shopDek: Data) throws -> Data {
        hkdf(try key32(shopDek, "shop DEK"), salt: utf8(Label.vaultSalt), info: Label.vaultInfo)
    }

    /// A fresh data key, once per UPLOAD ATTEMPT. Chunk nonces are counters,
    /// so they are unique only because this key is.
    public static func newDataKey() -> Data { random(keyBytes) }
    public static func newLinkSecret() -> Data { random(keyBytes) }

    /// linkKey for a grant. `password: nil` is a link without one; an empty
    /// password is refused rather than read as "none".
    public static func linkKey(linkSecret: Data, grantId: String, password: String?,
                               scryptN: Int = linkScrypt.n) throws -> Data {
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

    public static func dedupeKey(vaultKey: Data) throws -> Data {
        hkdf(try key32(vaultKey, "vault key"), salt: Data(), info: Label.dedupeInfo)
    }

    /// hex(HMAC-SHA256(dedupeKey, sha256(plaintext))), from a digest the caller
    /// computed while streaming the file.
    public static func dedupeTag(vaultKey: Data, plaintextSha256: Data) throws -> String {
        guard plaintextSha256.count == 32 else { throw Failure.badInput("digest must be 32 bytes") }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plaintextSha256),
                                                  using: SymmetricKey(data: try dedupeKey(vaultKey: vaultKey)))
        return hex(Data(mac))
    }

    public static func dedupeTag(vaultKey: Data, plaintext: Data) throws -> String {
        try dedupeTag(vaultKey: vaultKey, plaintextSha256: sha256(plaintext))
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
    public static func chunkCount(size: Int, chunkBytes: Int = chunkBytes) throws -> Int {
        guard size >= 0, chunkBytes > 0 else { throw Failure.badInput("size and chunkBytes must be valid") }
        return size == 0 ? 1 : (size + chunkBytes - 1) / chunkBytes
    }

    /// Seal chunk `index`. `last` is what makes a truncated file fail instead
    /// of reading as a shorter one.
    public static func encryptChunk(dk: Data, fileId: String, uploadId: String,
                                    index: Int, last: Bool, plaintext: Data) throws -> Data {
        try seal(dk, nonce: try chunkNonce(index), plaintext,
                 aad: try chunkAad(fileId: fileId, uploadId: uploadId, index: index, last: last))
    }

    /// Open chunk `index` at the position the caller expects. A chunk from any
    /// other position, file or upload fails authentication.
    public static func decryptChunk(dk: Data, fileId: String, uploadId: String,
                                    index: Int, last: Bool, sealed: Data) throws -> Data {
        try open(dk, nonce: try chunkNonce(index), sealed,
                 aad: try chunkAad(fileId: fileId, uploadId: uploadId, index: index, last: last))
    }

    /// hex sha256 of one sealed chunk (ct || tag), as the manifest lists it.
    public static func chunkHash(_ sealed: Data) -> String { hex(sha256(sealed)) }

    // MARK: - Manifest

    /// The exact manifest bytes: no spaces, keys in this order. Built by hand,
    /// because `JSONEncoder` promises neither.
    public static func manifestJSON(size: Int, chunkHashes: [String], chunkBytes: Int = chunkBytes) throws -> String {
        guard chunkHashes.count == (try chunkCount(size: size, chunkBytes: chunkBytes)) else {
            throw Failure.badInput("chunk count does not match size")
        }
        for h in chunkHashes {
            guard h.utf8.count == 64, h.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.badInput("chunk hash must be 64 lowercase hex")
            }
        }
        return "{\"v\":\(version),\"chunkBytes\":\(chunkBytes),\"size\":\(size),\"chunks\":["
            + chunkHashes.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
    }

    public static func manifestHash(size: Int, chunkHashes: [String], chunkBytes: Int = chunkBytes) throws -> String {
        hex(sha256(utf8(try manifestJSON(size: size, chunkHashes: chunkHashes, chunkBytes: chunkBytes))))
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

    /// Open a whole file against a manifest pinned by `expectedManifestHash`,
    /// which must come from somewhere authenticated (the meta record). Every
    /// check is made before a byte is returned.
    public static func decryptFile(dk: Data, fileId: String, uploadId: String, sealedChunks: [Data],
                                   size: Int, chunkHashes: [String], expectedManifestHash: String,
                                   chunkBytes: Int = chunkBytes) throws -> Data {
        guard try manifestHash(size: size, chunkHashes: chunkHashes, chunkBytes: chunkBytes) == expectedManifestHash else {
            throw Failure.manifestMismatch("manifest does not match its hash")
        }
        let n = chunkHashes.count
        guard sealedChunks.count == n else { throw Failure.manifestMismatch("chunk count mismatch") }
        var out = Data()
        for i in 0..<n {
            guard chunkHash(sealedChunks[i]) == chunkHashes[i] else {
                throw Failure.manifestMismatch("chunk \(i) does not match the manifest")
            }
            let pt = try decryptChunk(dk: dk, fileId: fileId, uploadId: uploadId,
                                      index: i, last: i == n - 1, sealed: sealedChunks[i])
            if i < n - 1, pt.count != chunkBytes { throw Failure.manifestMismatch("chunk \(i) is not full") }
            out.append(pt)
        }
        guard out.count == size else { throw Failure.manifestMismatch("size mismatch") }
        return out
    }

    // MARK: - Key wraps

    /// nonce(12) || AES-GCM(kek, nonce, key, aad) || tag(16): 60 bytes.
    public static func wrapKey(kek: Data, key: Data, aad: Data, nonce: Data? = nil) throws -> Data {
        let n = nonce.map { Data($0) } ?? random(nonceBytes)
        guard n.count == nonceBytes else { throw Failure.badInput("nonce must be 12 bytes") }
        return n + (try seal(kek, nonce: n, try key32(key, "wrapped key"), aad: aad))
    }

    public static func unwrapKey(kek: Data, wrapped: Data, aad: Data) throws -> Data {
        let w = Data(wrapped)
        guard w.count == nonceBytes + keyBytes + tagBytes else { throw Failure.badInput("wrapped key has the wrong length") }
        return try open(kek, nonce: w.prefix(nonceBytes), Data(w.dropFirst(nonceBytes)), aad: aad)
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

    // MARK: - Metadata record

    /// nonce(12) || ct || tag(16) over the JSON bytes as given, aad
    /// "khayt-vault-meta|" + fileId.
    public static func encryptMeta(vaultKey: Data, fileId: String, json: Data, nonce: Data? = nil) throws -> Data {
        let n = nonce.map { Data($0) } ?? random(nonceBytes)
        guard n.count == nonceBytes else { throw Failure.badInput("nonce must be 12 bytes") }
        let aad = utf8(Label.metaAad + "|" + (try id(fileId, "fileId")))
        return n + (try seal(vaultKey, nonce: n, json, aad: aad))
    }

    public static func decryptMeta(vaultKey: Data, fileId: String, sealed: Data) throws -> Data {
        let s = Data(sealed)
        guard s.count >= nonceBytes + tagBytes else { throw Failure.badInput("meta record too short") }
        let aad = utf8(Label.metaAad + "|" + (try id(fileId, "fileId")))
        return try open(vaultKey, nonce: s.prefix(nonceBytes), Data(s.dropFirst(nonceBytes)), aad: aad)
    }
}
