import Foundation
import Testing
@testable import KhaytCore

/// Reading what Khayt Cloud holds.
///
/// The envelope is `lib/sync-crypto.js`'s: AES-256-GCM with a 12-byte nonce and
/// a 16-byte tag, over gzipped JSON, every field base64. None of the fixtures
/// below were produced by Swift — each one came out of Node, and that is the
/// entire point of the file.
///
/// This half READS. Encrypting is the direction that can destroy a shop:
/// `cloud-backend.js` §7 spells out what a blob the server accepts does to
/// every other device, and none of it is here.
struct SyncCryptoTests {

    static func blob(_ json: String) throws -> SyncCrypto.Blob {
        try JSONDecoder().decode(SyncCrypto.Blob.self, from: Data(json.utf8))
    }

    /// The DEK behind every fixture here, from `unlockWithPassphrase`.
    static let dek = Data((0..<32).map { i -> UInt8 in
        let hex = "c3c91958fe7fbe2b29d625096617af546e0b603365c8a598b2ec8f814ecc651f"
        let s = hex.index(hex.startIndex, offsetBy: i * 2)
        let e = hex.index(s, offsetBy: 2)
        return UInt8(hex[s..<e], radix: 16)!
    })

    // MARK: - The store blob

    @Test("a gzipped store blob opens to the object Node put in it")
    func gzippedBlob() throws {
        let out = try SyncCrypto.store(try Self.blob(#"""
        {"v":1,"z":"gzip","iv":"AZ0opCsfnCkmhYhV","ct":"q+RkJVZZjMw3iZyQCAOTEOS15+SF8N06MfHIPTxOYtATSf562yBJw9hhp+pg7Cdwdg==","tag":"DeaykDiNw9zfzzXDS/r2fg=="}
        """#), dek: Self.dek)
        #expect(out["hello"] == .string("world"))
        #expect(out["n"] == .array([.number(1), .number(2), .number(3)]))
    }

    @Test("an uncompressed blob opens too, because the marker is on the outside")
    func uncompressedBlob() throws {
        // `decryptStore` reads both shapes and decides from `z`, which is
        // plaintext metadata — a reader knows how to treat the payload before
        // it has one.
        let out = try SyncCrypto.store(try Self.blob(#"""
        {"v":1,"iv":"EH03WcogAQtcxYpD","ct":"HaA1Zh8M7IJql2D+4JISicY=","tag":"KudXT8nGuzXk46FyILKA1g=="}
        """#), dek: Data(repeating: 7, count: 32))
        #expect(out["hello"] == .string("world"))
    }

    @Test("a store the size of a real one")
    func aRealSizedStore() throws {
        // 43,587 bytes of JSON into 4,782 of ciphertext. A gunzip that only
        // ever saw a two-field object proves nothing about a shop's book, and
        // the inflate buffer is grown from the trailer's own size.
        let out = try SyncCrypto.store(try Self.blob(#"""
        {"v": 1, "z": "gzip", "iv": "IpgR+R4B1avoaDYg", "ct": "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", "tag": "fJowta6fYkWvzUI+2VxJbQ=="}
        """#), dek: Self.dek)
        #expect(out.count == 400)
        guard case .object(let first)? = out["k0"] else { Issue.record("k0 missing"); return }
        #expect(first["id"] == .string("ORD-0"))
        guard case .object(let last)? = out["k399"] else { Issue.record("k399 missing"); return }
        #expect(last["price"] == .number(399 * 13.5))
    }

    // MARK: - The shop's key

    @Test("the data key comes back out of a passphrase-wrapped keyset")
    func unwrapsTheDek() throws {
        // The shape in this shop's own `settings.cloud.keyset`, made by
        // `createKeyset('a shop passphrase')`.
        let wrapped = try Self.blob(#"""
        {"salt":"6gTtdB9Tzx5xhmt9SqX+Xg==","iv":"h7a0JvOlLWqMDNsx","ct":"DxGu58SpE2NQQdU3jM10ql31VdJyXwBjekBL7YzP1Do=","tag":"trwRlTTZ9TupTfDwvIfBUw=="}
        """#)
        let dek = try SyncCrypto.unwrapDek(secret: "a shop passphrase", wrapped: wrapped)
        #expect(dek == Self.dek)
    }

    @Test("a wrong passphrase is refused, not silently different")
    func wrongPassphrase() throws {
        let wrapped = try Self.blob(#"""
        {"salt":"6gTtdB9Tzx5xhmt9SqX+Xg==","iv":"h7a0JvOlLWqMDNsx","ct":"DxGu58SpE2NQQdU3jM10ql31VdJyXwBjekBL7YzP1Do=","tag":"trwRlTTZ9TupTfDwvIfBUw=="}
        """#)
        #expect(throws: SyncCrypto.Failure.self) {
            try SyncCrypto.unwrapDek(secret: "not the passphrase", wrapped: wrapped)
        }
    }

    @Test("a key-wrapped entry says so instead of deriving a key from nothing")
    func keyWrappedEntry() throws {
        // An organisation's entry carries no salt. Without this it would derive
        // a KEK from an empty buffer and fail later with a GCM error that tells
        // a shop the wrong thing.
        let wrapped = try Self.blob(#"""
        {"kek":"direct","iv":"h7a0JvOlLWqMDNsx","ct":"DxGu58SpE2NQQdU3jM10ql31VdJyXwBjekBL7YzP1Do=","tag":"trwRlTTZ9TupTfDwvIfBUw=="}
        """#)
        #expect(throws: SyncCrypto.Failure.self) {
            try SyncCrypto.unwrapDek(secret: "a shop passphrase", wrapped: wrapped)
        }
    }

    // MARK: - What it refuses

    @Test("a tampered tag does not open")
    func tamperedTag() throws {
        let bad = try Self.blob(#"""
        {"v":1,"z":"gzip","iv":"AZ0opCsfnCkmhYhV","ct":"q+RkJVZZjMw3iZyQCAOTEOS15+SF8N06MfHIPTxOYtATSf562yBJw9hhp+pg7Cdwdg==","tag":"AAAykDiNw9zfzzXDS/r2fg=="}
        """#)
        #expect(throws: SyncCrypto.Failure.self) { try SyncCrypto.store(bad, dek: Self.dek) }
    }

    @Test("a wrong-length key is refused before any crypto happens")
    func wrongKeyLength() throws {
        let ok = try Self.blob(#"""
        {"v":1,"iv":"EH03WcogAQtcxYpD","ct":"HaA1Zh8M7IJql2D+4JISicY=","tag":"KudXT8nGuzXk46FyILKA1g=="}
        """#)
        #expect(throws: SyncCrypto.Failure.self) {
            try SyncCrypto.open(ok, key: Data(repeating: 7, count: 16))
        }
    }

    // MARK: - gzip

    @Test("the CRC in the trailer is checked, not skipped")
    func crcIsChecked() throws {
        // A decompressor that ignores its own trailer hands back a truncated
        // store as though it were whole.
        #expect(SyncCrypto.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
        #expect(SyncCrypto.crc32(Data()) == 0)
        #expect(SyncCrypto.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("something that is not gzip is named as such")
    func notGzip() {
        #expect(throws: SyncCrypto.Failure.self) {
            try SyncCrypto.gunzip(Data(repeating: 0x41, count: 40))
        }
    }
}
