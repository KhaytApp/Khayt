import Foundation
import CommonCrypto

/// Reads and writes the encrypted fields in Khayt's store.
///
/// The store file itself is plain JSON. Three fields inside it are not: the AI
/// key, the cloud token and the S3 secret are written as `__enc__` + base64 of
/// whatever Electron's `safeStorage` produced. On macOS that is Chromium's
/// OSCrypt, and its shape is not a guess — it was measured from this machine's
/// own store:
///
///     ai.apiKey            total 115  prefix "v10"  body 112  body % 16 == 0
///     cloud.token          total  83  prefix "v10"  body  80  body % 16 == 0
///     s3.secretAccessKey   total  35  prefix "v10"  body  32  body % 16 == 0
///
/// A `v10` tag over an AES-CBC body, in every case. The parameters below are
/// OSCrypt's: PBKDF2-SHA1 over a Keychain-held password with the salt
/// `saltysalt` and 1003 iterations, a 128-bit key, and an IV of sixteen spaces.
///
/// WHY THIS MATTERS MORE THAN IT LOOKS: the native app has to leave these fields
/// exactly as Electron would. Get the algorithm wrong and it cannot read a
/// shop's cloud token — annoying, recoverable. Get it wrong in the writing
/// direction and it overwrites a good secret with bytes Electron will never
/// decrypt, on a machine that may still be running Electron. So `seal` is
/// verified by opening its own output before it is allowed to return.
public enum SafeStorage {

    public enum Failure: Error, CustomStringConvertible {
        case notEncrypted
        case unknownVersion(String)
        case truncated(Int)
        case cryptoFailed(Int32)
        case notUTF8
        case roundTripMismatch

        public var description: String {
            switch self {
            case .notEncrypted: return "the value has no __enc__ marker; it is stored in the clear"
            case .unknownVersion(let v):
                return "the ciphertext is tagged \(v), not v10 — Electron's format changed and this code has not"
            case .truncated(let n): return "the ciphertext body is \(n) bytes, not a whole number of AES blocks"
            case .cryptoFailed(let s): return "CommonCrypto refused: status \(s) (usually a wrong key: the padding did not check out)"
            case .notUTF8: return "decrypted, but the result is not text — wrong key, or not a string field"
            case .roundTripMismatch:
                return "sealed a value this code could not itself open; refusing to write it"
            }
        }
    }

    public static let marker = "__enc__"
    static let version = "v10"
    static let salt = "saltysalt"
    static let iterations: UInt32 = 1003
    static let keyLength = 16          // AES-128
    /// Not zeros. OSCrypt uses sixteen 0x20 bytes, and this is the single
    /// likeliest detail to get wrong by writing the obvious thing.
    static let iv = Data(repeating: 0x20, count: 16)

    /// The password Electron keeps in the login Keychain, run through PBKDF2.
    ///
    /// The Keychain item belongs to whatever `app.getName()` returned, which is
    /// NOT constant: a dev run is `khayt` (package.json `name`) and a packaged
    /// build is `Khayt` (electron-builder `productName`). Those are two
    /// different Keychain items holding two different keys over two different
    /// store files, and confusing them looks exactly like a corrupt store.
    public static func key(fromPassword password: String) -> Data {
        var out = Data(count: keyLength)
        let pw = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        let status: Int32 = out.withUnsafeMutableBytes { dst in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw, pw.count,
                                 saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                 iterations,
                                 dst.bindMemory(to: UInt8.self).baseAddress!, keyLength)
        }
        precondition(status == kCCSuccess, "PBKDF2 cannot fail on valid inputs; got \(status)")
        return out
    }

    /// `__enc__…` → plaintext.
    public static func open(_ field: String, key: Data) throws -> String {
        guard field.hasPrefix(marker) else { throw Failure.notEncrypted }
        guard let raw = Data(base64Encoded: String(field.dropFirst(marker.count))), raw.count > 3 else {
            throw Failure.truncated(0)
        }
        let tag = String(decoding: raw.prefix(3), as: UTF8.self)
        guard tag == version else { throw Failure.unknownVersion(tag) }
        let body = raw.dropFirst(3)
        guard body.count % kCCBlockSizeAES128 == 0 else { throw Failure.truncated(body.count) }
        let plain = try crypt(Data(body), key: key, operation: CCOperation(kCCDecrypt))
        guard let text = String(data: plain, encoding: .utf8) else { throw Failure.notUTF8 }
        return text
    }

    /// plaintext → `__enc__…`, in the bytes Electron writes.
    public static func seal(_ text: String, key: Data) throws -> String {
        try seal(text, key: key, verify: open)
    }

    /// Never hand back a field this code cannot read.
    ///
    /// The failure being guarded is silent and destructive — overwriting a
    /// working secret with bytes nothing can decrypt, on a machine that may
    /// still be running Electron. No input can trip it today: CBC with a fixed
    /// IV and PKCS7 always round-trips. It guards against a future edit to the
    /// algorithm, which is exactly the kind of guard that quietly stops working,
    /// so `verify` is a seam and a test drives a broken one through it.
    static func seal(_ text: String, key: Data,
                     verify: (String, Data) throws -> String) throws -> String {
        let body = try crypt(Data(text.utf8), key: key, operation: CCOperation(kCCEncrypt))
        let field = marker + (Data(version.utf8) + body).base64EncodedString()
        guard (try? verify(field, key)) == text else { throw Failure.roundTripMismatch }
        return field
    }

    private static func crypt(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             Array(key), key.count, Array(iv),
                             Array(input), input.count,
                             &out, out.count, &moved)
        guard status == kCCSuccess else { throw Failure.cryptoFailed(status) }
        return Data(out.prefix(moved))
    }
}
