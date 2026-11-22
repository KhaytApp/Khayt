import Foundation
import CommonCrypto

/// scrypt, because macOS does not have one.
///
/// Khayt wraps a shop's data key under a passphrase with
/// `crypto.scryptSync(secret, salt, 32, { N: 32768, r: 8, p: 1 })`, and there is
/// no scrypt in CryptoKit, CommonCrypto or any other system framework — only
/// PBKDF2. So it is written out here, from RFC 7914, and pinned against both
/// the RFC's own published vectors and Node's actual output.
///
/// **The only thing that matters about this file is that it agrees with Node.**
/// A KEK that is one byte different does not fail loudly: it produces a GCM
/// authentication error at the far end of the unwrap, which reads as "wrong
/// passphrase" — so a shop would be told its own password is wrong, for ever.
/// That is why the vectors are the point and the implementation is not.
public enum Scrypt {

    public enum Failure: Error, CustomStringConvertible {
        case badParameters(String)

        public var description: String {
            switch self {
            case .badParameters(let why): return "scrypt cannot run with these parameters: \(why)"
            }
        }
    }

    /// RFC 7914 §6. `n` must be a power of two greater than one.
    public static func key(password: Data, salt: Data, n: Int, r: Int, p: Int,
                           length: Int) throws -> Data {
        guard n > 1, (n & (n - 1)) == 0 else { throw Failure.badParameters("N must be a power of two") }
        guard r > 0, p > 0, length > 0 else { throw Failure.badParameters("r, p and the length must be positive") }
        // The bound RFC 7914 states, and the one Node enforces as `maxmem`.
        guard r * p < (1 << 30) else { throw Failure.badParameters("r * p is too large") }

        let blockBytes = 128 * r
        var b = try pbkdf2(password: password, salt: salt, length: p * blockBytes)

        // Each of the p blocks is mixed independently — sequentially here,
        // because p is 1 in every keyset Khayt writes and a thread pool for one
        // block is machinery with nothing to do.
        b.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt32.self).baseAddress!
            let words = blockBytes / 4
            for i in 0..<p {
                roMix(base.advanced(by: i * words), r: r, n: n)
            }
        }

        return try pbkdf2(password: password, salt: b, length: length)
    }

    /// The convenience Khayt's own default asks for.
    public static func kek(secret: String, salt: Data,
                           n: Int = 32768, r: Int = 8, p: Int = 1, length: Int = 32) throws -> Data {
        try key(password: Data(secret.utf8), salt: salt, n: n, r: r, p: p, length: length)
    }

    // MARK: - The pieces

    /// PBKDF2-HMAC-SHA256, one iteration — which is all scrypt asks of it.
    private static func pbkdf2(password: Data, salt: Data, length: Int) throws -> Data {
        var out = Data(count: length)
        // An empty salt is legal (RFC 7914's first vector uses one) and
        // CCKeyDerivationPBKDF wants a non-null pointer regardless.
        let saltBytes = salt.isEmpty ? Data([0]) : salt
        let status: Int32 = out.withUnsafeMutableBytes { dst in
            password.withUnsafeBytes { pw in
                saltBytes.withUnsafeBytes { st in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        st.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1,
                        dst.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.badParameters("PBKDF2 refused: \(status)") }
        return out
    }

    /// RFC 7914 §5 — the sequentially memory-hard part.
    private static func roMix(_ block: UnsafeMutablePointer<UInt32>, r: Int, n: Int) {
        let words = 32 * r
        var v = [UInt32](repeating: 0, count: words * n)
        var x = [UInt32](repeating: 0, count: words)
        var y = [UInt32](repeating: 0, count: words)

        for i in 0..<words { x[i] = block[i] }

        for i in 0..<n {
            for j in 0..<words { v[i * words + j] = x[j] }
            blockMix(&x, &y, r: r)
        }
        for _ in 0..<n {
            // `j` is the LAST 64-byte block of X read as a little-endian
            // integer, modulo N — which is why N must be a power of two.
            let j = Int(x[words - 16]) & (n - 1)
            for k in 0..<words { x[k] ^= v[j * words + k] }
            blockMix(&x, &y, r: r)
        }

        for i in 0..<words { block[i] = x[i] }
    }

    /// RFC 7914 §4. `y` is scratch the caller owns, so this allocates nothing.
    private static func blockMix(_ x: inout [UInt32], _ y: inout [UInt32], r: Int) {
        var t = [UInt32](repeating: 0, count: 16)
        // X starts as the LAST 64-byte block.
        for i in 0..<16 { t[i] = x[(2 * r - 1) * 16 + i] }
        for i in 0..<(2 * r) {
            for j in 0..<16 { t[j] ^= x[i * 16 + j] }
            salsa20_8(&t)
            // Even blocks to the front half, odd to the back — the shuffle that
            // makes the output of one round the input of the next.
            let to = (i % 2 == 0 ? i / 2 : r + i / 2) * 16
            for j in 0..<16 { y[to + j] = t[j] }
        }
        swap(&x, &y)
    }

    /// Salsa20/8 core, in place on sixteen little-endian words.
    private static func salsa20_8(_ b: inout [UInt32]) {
        var x = b
        func rotate(_ a: UInt32, _ n: UInt32) -> UInt32 { (a << n) | (a >> (32 - n)) }
        for _ in 0..<4 {                      // eight rounds, two per iteration
            x[4] ^= rotate(x[0] &+ x[12], 7);   x[8] ^= rotate(x[4] &+ x[0], 9)
            x[12] ^= rotate(x[8] &+ x[4], 13);  x[0] ^= rotate(x[12] &+ x[8], 18)
            x[9] ^= rotate(x[5] &+ x[1], 7);    x[13] ^= rotate(x[9] &+ x[5], 9)
            x[1] ^= rotate(x[13] &+ x[9], 13);  x[5] ^= rotate(x[1] &+ x[13], 18)
            x[14] ^= rotate(x[10] &+ x[6], 7);  x[2] ^= rotate(x[14] &+ x[10], 9)
            x[6] ^= rotate(x[2] &+ x[14], 13);  x[10] ^= rotate(x[6] &+ x[2], 18)
            x[3] ^= rotate(x[15] &+ x[11], 7);  x[7] ^= rotate(x[3] &+ x[15], 9)
            x[11] ^= rotate(x[7] &+ x[3], 13);  x[15] ^= rotate(x[11] &+ x[7], 18)

            x[1] ^= rotate(x[0] &+ x[3], 7);    x[2] ^= rotate(x[1] &+ x[0], 9)
            x[3] ^= rotate(x[2] &+ x[1], 13);   x[0] ^= rotate(x[3] &+ x[2], 18)
            x[6] ^= rotate(x[5] &+ x[4], 7);    x[7] ^= rotate(x[6] &+ x[5], 9)
            x[4] ^= rotate(x[7] &+ x[6], 13);   x[5] ^= rotate(x[4] &+ x[7], 18)
            x[11] ^= rotate(x[10] &+ x[9], 7);  x[8] ^= rotate(x[11] &+ x[10], 9)
            x[9] ^= rotate(x[8] &+ x[11], 13);  x[10] ^= rotate(x[9] &+ x[8], 18)
            x[12] ^= rotate(x[15] &+ x[14], 7); x[13] ^= rotate(x[12] &+ x[15], 9)
            x[14] ^= rotate(x[13] &+ x[12], 13); x[15] ^= rotate(x[14] &+ x[13], 18)
        }
        for i in 0..<16 { b[i] = b[i] &+ x[i] }
    }
}
