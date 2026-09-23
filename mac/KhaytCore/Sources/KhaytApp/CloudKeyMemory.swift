import Foundation
import Security
import CryptoKit
import KhaytCore

/// The cloud's unlocked data key, kept in THIS Mac's login Keychain so the
/// shop does not type its passphrase at every launch.
///
/// ── WHY THIS EXISTS ─────────────────────────────────────────────────────
///
/// The key used to live only in memory, re-earned with the passphrase every
/// time the app opened. Turki, Sep 2026: "its ridiculous that I need to relog
/// into the cloud every time I launch the app". The cloud session token has
/// always been kept on this Mac, sealed with the login Keychain; this is the
/// same promise for the other half. The PASSPHRASE is still never stored. What
/// is kept is the unwrapped key, on this Mac, in the Keychain:
///
/// * a generic password in the login Keychain, never synchronised to iCloud,
///   readable by this app's signature, like the `Safe Storage` item;
/// * gone when the shop locks the cloud from the menu bar, and replaced on
///   every unlock;
/// * kept WITH A FINGERPRINT of the keyset it was unwrapped from, and used at
///   launch only while the book's keyset still carries that fingerprint. The
///   keyset has no check value of its own, and a key that no longer fits would
///   push a book the other devices cannot open. So a keyset changed anywhere
///   (new passphrase, rotated key) means one passphrase prompt, never a stale
///   key.
///
/// Reads go OFF the main actor. `SecItemCopyMatching` blocks, and a Keychain
/// dialog in front of it would freeze the window (see `Secrets.key`).
enum CloudKeyMemory {
    static let service = "Khayt Cloud Key"

    private static func query(_ shopId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: shopId,
         kSecAttrSynchronizable as String: false]
    }

    /// Keep this shop's key. Replaces any earlier one. Best effort: a Mac that
    /// cannot keep it asks for the passphrase next launch, as before.
    static func remember(_ dek: Data, fingerprint: String, shopId: String) async {
        guard !shopId.isEmpty, !dek.isEmpty, !fingerprint.isEmpty else { return }
        let value = Data((fingerprint + ":" + dek.base64EncodedString()).utf8)
        await Task.detached(priority: .utility) {
            let base = query(shopId)
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = value
            add[kSecAttrLabel as String] = "Khayt Cloud Key (\(shopId))"
            _ = SecItemAdd(add as CFDictionary, nil)
        }.value
    }

    /// This shop's key, when this Mac kept one AND it was unwrapped from the
    /// keyset the book holds now. A kept key for another keyset is forgotten.
    static func recall(shopId: String, fingerprint: String) async -> Data? {
        guard !shopId.isEmpty, !fingerprint.isEmpty else { return nil }
        let kept = await Task.detached(priority: .userInitiated) { () -> Data? in
            var q = query(shopId)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }.value
        guard let kept, let text = String(data: kept, encoding: .utf8),
              let colon = text.firstIndex(of: ":") else { return nil }
        guard String(text[..<colon]) == fingerprint,
              let dek = Data(base64Encoded: String(text[text.index(after: colon)...])),
              !dek.isEmpty else {
            await forget(shopId: shopId)
            return nil
        }
        return dek
    }

    /// What identifies a keyset: the passphrase-wrapped key it carries, which
    /// changes whenever the passphrase or the key does.
    static func fingerprint(of keyset: JSONValue?) -> String? {
        guard case .object(let fields)? = keyset,
              let wrapped = fields["wrappedByPassphrase"] else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let bytes = try? encoder.encode(wrapped) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Forget it: the shop locked the cloud, or the kept key stopped fitting.
    static func forget(shopId: String) async {
        guard !shopId.isEmpty else { return }
        await Task.detached(priority: .utility) {
            _ = SecItemDelete(query(shopId) as CFDictionary)
        }.value
    }
}
