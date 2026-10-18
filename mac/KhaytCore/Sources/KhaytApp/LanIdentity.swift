import Foundation
import Security
import CryptoKit

/// Who this Mac is, to a phone that has paired with it.
///
/// ── WHY A KEY, NOT THE PIN ─────────────────────────────────────────────────
///
/// A phone finds the Mac by its Bonjour name, and a name is only a claim:
/// while the Mac sleeps, anything on the shop's Wi-Fi can advertise the same
/// one, and a phone that followed it would hand that device the owner PIN —
/// which opens the whole book on the real Mac. So the phone asks first, at a
/// new address, for proof: a nonce it chose, signed with this Mac's Ed25519
/// key, checked against the public key it pinned while it still knew where
/// the Mac was.
///
/// Proof by the PIN itself (an HMAC keyed with it) was considered and turned
/// down: an unauthenticated route that answers HMAC(PIN, nonce) lets anyone
/// who asks once try all hundred million 8-digit PINs offline in seconds. A
/// signature says nothing about the PIN at all.
///
/// The key is made once, kept in this Mac's login Keychain (not synced), and
/// never leaves it. `GET /api/identity` (PIN-gated) hands out the public half;
/// `GET /api/proof?nonce=` (open) signs. See `LanServer`.
enum LanIdentity {
    static let service = "Khayt LAN Identity"
    static let account = "mac"
    /// What is signed: the prefix keeps a proof from ever being a signature
    /// over anything else this key might one day sign.
    static let prefix = "khayt-proof:"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Curve25519.Signing.PrivateKey?

    /// For tests: a key held in memory, so no test writes this Mac's Keychain.
    static func use(_ key: Curve25519.Signing.PrivateKey) {
        lock.lock(); cached = key; lock.unlock()
    }

    /// This Mac's key, made the first time it is asked for.
    static func key() -> Curve25519.Signing.PrivateKey? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecAttrSynchronizable as String: false]
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let raw = out as? Data,
           let kept = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            cached = kept
            return kept
        }
        let made = Curve25519.Signing.PrivateKey()
        var add = base
        add[kSecValueData as String] = made.rawRepresentation
        add[kSecAttrLabel as String] = "Khayt LAN identity"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Not kept, not used: a key a restart would replace is a phone told
        // its Mac is an impostor.
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        cached = made
        return made
    }

    /// The public half, base64 of the raw 32 bytes, for `/api/identity`.
    static func publicKey(_ key: Curve25519.Signing.PrivateKey? = key()) -> String? {
        key?.publicKey.rawRepresentation.base64EncodedString()
    }

    /// A nonce the phone chose: 32 to 128 hex digits, so the signed message
    /// is always short, always ours, and never anything a caller composed.
    static func plausibleNonce(_ nonce: String) -> Bool {
        (32...128).contains(nonce.count) && nonce.allSatisfy(\.isHexDigit)
    }

    /// base64 of the Ed25519 signature over `prefix + nonce`, or nil for a
    /// nonce that is not one.
    static func proof(nonce: String, key: Curve25519.Signing.PrivateKey? = key()) -> String? {
        guard plausibleNonce(nonce), let key,
              let sig = try? key.signature(for: Data((prefix + nonce.lowercased()).utf8)) else { return nil }
        return sig.base64EncodedString()
    }
}
