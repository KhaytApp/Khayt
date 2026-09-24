import Foundation
import CryptoKit
import Compression

/// Reading what Khayt Cloud holds.
///
/// The envelope is `lib/sync-crypto.js`'s and nothing here decides any of it:
/// AES-256-GCM with a 12-byte nonce and a 16-byte tag, over gzipped JSON, with
/// every field base64 — `{ v, z?, iv, ct, tag }`. The `z` marker is plaintext
/// metadata on the OUTSIDE of the encryption, so a reader knows how to treat
/// the payload before it has one.
///
/// **This half reads. It does not write.** Encrypting is the direction that can
/// destroy a shop: `cloud-backend.js` §7 spells out what a blob the server
/// accepts does to every other device. Reading can be wrong and merely fail.
///
/// The key comes from `Scrypt`, which macOS does not provide and which is
/// pinned against RFC 7914 and Node — see `ScryptTests`, and read the note
/// there about what a KEK one byte out looks like to a shop.
public enum SyncCrypto {

    public enum Failure: Error, CustomStringConvertible {
        case malformed(String)
        case wrongKey
        case notGzip
        case corruptGzip(String)
        case notJSON

        public var description: String {
            switch self {
            case .malformed(let what): return "the encrypted blob is missing or malformed: \(what)"
            case .wrongKey:
                return "the data would not open with this key — a wrong passphrase, or the blob was altered"
            case .notGzip: return "the payload is marked gzip and does not begin like it"
            case .corruptGzip(let why): return "the payload would not decompress: \(why)"
            case .notJSON: return "the payload decrypted but is not JSON"
            }
        }
    }

    /// One encrypted blob, as the wire and the keyset both carry it.
    /// Encodable as well as Decodable: the same shape goes back up when this app
    /// sends a change, and inventing a second struct for the outbound half is
    /// how the two drift.
    public struct Blob: Codable, Sendable {
        public let v: Int?
        public let z: String?
        public let iv: String
        public let ct: String
        public let tag: String
        /// Present on a passphrase-wrapped key and absent on a key-wrapped one.
        public let salt: String?

        public init(v: Int?, z: String?, iv: String, ct: String, tag: String, salt: String?) {
            self.v = v; self.z = z; self.iv = iv; self.ct = ct; self.tag = tag; self.salt = salt
        }
    }

    public static let storeBlobVersion = 1
    public static let compression = "gzip"

    // MARK: - AES-256-GCM

    /// Open one blob with a 32-byte key.
    public static func open(_ blob: Blob, key: Data) throws -> Data {
        guard key.count == 32 else { throw Failure.malformed("the key is \(key.count) bytes, not 32") }
        guard let iv = Data(base64Encoded: blob.iv), iv.count == 12 else {
            throw Failure.malformed("iv")
        }
        guard let ct = Data(base64Encoded: blob.ct) else { throw Failure.malformed("ct") }
        guard let tag = Data(base64Encoded: blob.tag), tag.count == 16 else {
            throw Failure.malformed("tag")
        }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            // CryptoKit says only "authenticationFailure", and it means the same
            // thing for a wrong key and for tampering. Saying both is honest.
            throw Failure.wrongKey
        }
    }

    // MARK: - The shop's keys

    /// Unwrap the data key from a passphrase-wrapped keyset entry.
    ///
    /// `settings.cloud.keyset.wrappedByPassphrase` — the shape this shop's own
    /// book carries. A key-wrapped entry (an organisation's) has no salt and is
    /// refused by name rather than by deriving a KEK from nothing, which is a
    /// GCM error that tells a shop the wrong thing.
    public static func unwrapDek(secret: String, wrapped: Blob, kdf: Kdf = Kdf(),
                                 n: Int? = nil, r: Int? = nil, p: Int? = nil) throws -> Data {
        guard let salt64 = wrapped.salt, let salt = Data(base64Encoded: salt64) else {
            throw Failure.malformed("this entry is key-wrapped and needs the organisation's key, not a passphrase")
        }
        let kek = try Scrypt.key(password: Data(secret.utf8), salt: salt,
                                 n: n ?? kdf.n, r: r ?? kdf.r, p: p ?? kdf.p,
                                 length: kdf.keyLength)
        return try open(wrapped, key: kek)
    }

    /// ── THE KEYSET SAYS HOW ITS KEY WAS STRETCHED ────────────────────────
    ///
    /// `createKeyset` in `lib/sync-crypto.js` takes `opts.kdf` and writes what
    /// it used into `keyset.kdf`. `unlockWithPassphrase` reads it back, and so
    /// does the web client. This app had the defaults built in and ignored the
    /// field — so a keyset made with anything else would have been refused on
    /// this Mac with a decryption error, which says nothing about why.
    ///
    /// Every keyset in existence uses the defaults today. That is exactly when
    /// to fix it: the cost is a struct, and the alternative is discovering it
    /// on the day somebody turns the cost up and every Mac in the shop stops
    /// unlocking.
    ///
    /// Only scrypt exists. An algorithm this app does not know is refused BY
    /// NAME rather than quietly stretched with scrypt anyway, which would hand
    /// back a wrong key and report it as a wrong passphrase.
    public struct Kdf: Sendable, Equatable {
        public let algorithm: String
        public let n: Int
        public let r: Int
        public let p: Int
        public let keyLength: Int

        public init(algorithm: String = "scrypt", n: Int = 32768, r: Int = 8,
                    p: Int = 1, keyLength: Int = 32) {
            self.algorithm = algorithm
            self.n = n
            self.r = r
            self.p = p
            self.keyLength = keyLength
        }

        /// Read it off `settings.cloud.keyset.kdf`. A missing field is the
        /// default, which is what every keyset written so far carries.
        public static func from(_ value: JSONValue?) throws -> Kdf {
            guard case .object(let fields)? = value else { return Kdf() }
            // Bounded: these come from a book that syncs and restores, and an
            // infinite or enormous N either trapped in `Int(v)` or asked scrypt
            // for more memory than the Mac has, at unlock.
            let int = { (key: String, fallback: Int) -> Int in
                guard case .number(let v)? = fields[key], v.isFinite, v >= 1 else { return fallback }
                let ceiling: Double = switch key { case "N": 1_048_576; case "r": 32; case "p": 16; default: 64 }
                return Int(min(v, ceiling))
            }
            var algorithm = "scrypt"
            if case .string(let a)? = fields["algo"], !a.isEmpty { algorithm = a }
            guard algorithm == "scrypt" else {
                throw Failure.malformed("this book's key uses \(algorithm), which this app cannot read")
            }
            let fallback = Kdf()
            return Kdf(algorithm: algorithm,
                       n: int("N", fallback.n), r: int("r", fallback.r),
                       p: int("p", fallback.p), keyLength: int("keyLen", fallback.keyLength))
        }
    }

    // MARK: - The store

    /// A store blob, decrypted and decompressed, as JSON bytes.
    public static func openStore(_ blob: Blob, dek: Data) throws -> Data {
        let plain = try open(blob, key: dek)
        guard blob.z == compression else { return plain }
        return try gunzip(plain)
    }

    /// The same, decoded.
    public static func store(_ blob: Blob, dek: Data) throws -> [String: JSONValue] {
        let json = try openStore(blob, dek: dek)
        guard let out = try? JSONDecoder().decode([String: JSONValue].self, from: json) else {
            throw Failure.notJSON
        }
        return out
    }

    /// The other direction: an object, sealed with the DEK, in exactly the shape
    /// `decryptStore` in `lib/sync-crypto.js` reads back.
    ///
    /// Compressed, because that is what every current writer emits and matching
    /// them keeps one shape on the wire — but the `z` marker is written from the
    /// same fact that does the compressing, so the two can never disagree.
    ///
    /// The nonce comes from `AES.GCM.seal`'s own generator and is never reused:
    /// a repeated nonce under one key is the failure that hands an attacker the
    /// keystream, and it is not a thing to economise on.
    public static func seal(_ object: [String: JSONValue], dek: Data) throws -> Blob {
        guard dek.count == 32 else { throw Failure.malformed("the key is \(dek.count) bytes, not 32") }
        let json = try JSONEncoder().encode(object)
        let packed = try gzip(json)
        let box = try AES.GCM.seal(packed, using: SymmetricKey(data: dek))
        return Blob(v: storeBlobVersion, z: compression,
                    iv: Data(box.nonce).base64EncodedString(),
                    ct: box.ciphertext.base64EncodedString(),
                    tag: box.tag.base64EncodedString(),
                    salt: nil)
    }

    // MARK: - gzip

    /// `zlib.gzipSync`, from the same pieces `gunzip` takes apart.
    ///
    /// The ten-byte header carries no name, no time and no extra fields, so the
    /// reader's optional-field handling is never exercised by our own output —
    /// deliberately, because a writer should emit the plainest thing its readers
    /// accept. The trailer is the CRC-32 of the ORIGINAL bytes and their length
    /// mod 2^32, little-endian, and both are what `gunzip` checks.
    public static func gzip(_ data: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00,   // magic, DEFLATE, no flags
                        0x00, 0x00, 0x00, 0x00,   // mtime 0 — a timestamp would leak and buys nothing
                        0x00, 0xff])              // no extra flags, OS unknown
        out.append(try deflate(data))
        var trailer = crc32(data).littleEndian
        withUnsafeBytes(of: &trailer) { out.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    /// Raw DEFLATE, with room for the case where compressing makes it bigger.
    ///
    /// `compression_encode_buffer` returns 0 for "it did not fit" and gives no
    /// way to ask how much it needed, exactly as its decoding twin does. Random
    /// or already-compressed bytes come out LARGER than they went in — stored
    /// blocks add about five bytes per 64 KB — so a destination sized at the
    /// input length is not merely tight, it is wrong.
    private static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            // `compression_encode_buffer` writes nothing for no input, which is
            // indistinguishable from failure. An empty DEFLATE stream is one
            // final empty stored block, and every inflater reads it.
            return Data([0x03, 0x00])
        }
        var capacity = data.count + (data.count / 100) + 1024
        for _ in 0..<6 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    compression_encode_buffer(
                        dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                        src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return out.prefix(written) }
            capacity *= 4
        }
        throw Failure.corruptGzip("the payload did not compress into any reasonable size")
    }

    /// `zlib.gunzipSync`, from the pieces macOS gives.
    ///
    /// `Compression` does raw DEFLATE and nothing else, so the container is
    /// this function's job: the ten-byte header (and whatever optional fields
    /// its flags announce), then the stream, then a CRC-32 and the length —
    /// both of which are CHECKED. A decompressor that ignores its own trailer
    /// will hand back a truncated store as though it were whole.
    public static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18 else { throw Failure.corruptGzip("only \(data.count) bytes") }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else { throw Failure.notGzip }
        guard bytes[2] == 8 else { throw Failure.corruptGzip("compression method \(bytes[2]), not deflate") }

        let flags = bytes[3]
        var at = 10
        func need(_ n: Int) throws {
            guard at + n <= bytes.count else { throw Failure.corruptGzip("header runs past the end") }
        }
        if flags & 0x04 != 0 {                       // FEXTRA
            try need(2)
            let extra = Int(bytes[at]) | (Int(bytes[at + 1]) << 8)
            at += 2
            try need(extra)
            at += extra
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {   // FNAME, FCOMMENT
            while at < bytes.count, bytes[at] != 0 { at += 1 }
            guard at < bytes.count else { throw Failure.corruptGzip("an unterminated header string") }
            at += 1
        }
        if flags & 0x02 != 0 { try need(2); at += 2 }                      // FHCRC

        let trailer = bytes.count - 8
        guard at < trailer else { throw Failure.corruptGzip("nothing between the header and the trailer") }
        let deflated = Data(bytes[at..<trailer])

        let expectedCRC = UInt32(bytes[trailer]) | UInt32(bytes[trailer + 1]) << 8
            | UInt32(bytes[trailer + 2]) << 16 | UInt32(bytes[trailer + 3]) << 24
        let expectedSize = UInt32(bytes[trailer + 4]) | UInt32(bytes[trailer + 5]) << 8
            | UInt32(bytes[trailer + 6]) << 16 | UInt32(bytes[trailer + 7]) << 24

        let out = try inflate(deflated, hint: Int(expectedSize))
        guard out.count == Int(expectedSize) else {
            throw Failure.corruptGzip("\(out.count) bytes where the trailer says \(expectedSize)")
        }
        guard crc32(out) == expectedCRC else { throw Failure.corruptGzip("the checksum does not match") }
        return out
    }

    /// Raw DEFLATE, grown until it fits.
    ///
    /// `compression_decode_buffer` gives no way to ask how much it needs and
    /// returns 0 both for "empty" and for "your buffer was too small", so the
    /// trailer's size is the hint and the loop is the insurance when it lies.
    private static func inflate(_ deflated: Data, hint: Int) throws -> Data {
        var capacity = max(hint, deflated.count * 4, 1024)
        for _ in 0..<8 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                deflated.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(
                        dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                        src.baseAddress!.assumingMemoryBound(to: UInt8.self), deflated.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity { return out.prefix(written) }
            if written > 0 && written == capacity && written == hint { return out }
            capacity *= 4
        }
        throw Failure.corruptGzip("the payload did not decompress into any reasonable size")
    }

    /// CRC-32 as gzip writes it. Table built once.
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
