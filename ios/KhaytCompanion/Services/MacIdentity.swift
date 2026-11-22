import CryptoKit
import Foundation

/// Telling the shop's Mac from something that only uses its name.
///
/// ── WHY A SIGNATURE, NOT THE PIN ─────────────────────────────────────────
///
/// When the Mac's address changes, the phone finds it again by its Bonjour
/// name — and any device on the network can advertise that name while the
/// Mac sleeps. Sending the PIN to find out would hand it over. A proof built
/// from the PIN (an HMAC of a nonce) would be no better: one answer lets
/// anyone on the Wi-Fi try all 10⁸ eight-digit PINs offline in seconds.
///
/// So the Mac holds an Ed25519 key of its own (made once, kept in its
/// Keychain). The phone pins the public half while it is talking to the Mac
/// at the address it already trusts, with the PIN (`GET /api/identity`).
/// At a new address it sends only a random nonce (`GET /api/proof`) and
/// checks the signature against the pinned key. That says nothing about the
/// PIN, and only the Mac can produce it.
///
/// Anything short of a valid signature — no key pinned yet, a desktop that
/// does not have the routes, a 503 because the Mac's key could not be opened,
/// a different key — is "cannot prove", and the phone asks the person
/// instead of moving (`ConnectionHealth.followTheMac`).
enum MacIdentity {
    static let algorithm = "ed25519"

    /// 16 random bytes as 32 lowercase hex digits.
    static func nonce() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &g)) }.joined()
    }

    /// What the Mac signs. Both the Mac and the desktop lowercase the nonce.
    static func message(nonce: String) -> Data {
        Data(("khayt-proof:" + nonce.lowercased()).utf8)
    }

    /// A public key the Mac sent, if it is one: base64 of the raw 32 bytes.
    static func publicKey(_ base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// Whether `signature` (base64) is the pinned key's signature over `nonce`.
    static func verify(signature: String, alg: String?, nonce: String, key: String) -> Bool {
        guard alg == algorithm, let pub = publicKey(key),
              let sig = Data(base64Encoded: signature) else { return false }
        return pub.isValidSignature(sig, for: message(nonce: nonce))
    }
}
