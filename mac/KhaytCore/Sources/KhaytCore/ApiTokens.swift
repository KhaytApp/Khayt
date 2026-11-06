import CryptoKit
import Foundation

/// Scoped API tokens for the LAN API — the half of `lib/api-tokens.js` that
/// needs Node's crypto, in Swift: minting, hashing and verifying.
///
/// The FORMAT is the desktop's, byte for byte, so a token minted on either app
/// verifies on the other once the book has travelled: `khayt_` followed by 32
/// random bytes as unpadded base64url, an id `tok_` + 8 random bytes as hex,
/// and a SHA-256 hex digest of the whole token as the only thing stored.
/// `ApiTokensParityTests` pins the hash against a vector computed by the
/// JavaScript. The scope RULES (which scope a route needs, what each scope is
/// called) are not here: they run in JavaScriptCore from the same file the
/// desktop runs (`KhaytEngine.apiTokenScope`).
///
/// ── WHAT IS SECRET ────────────────────────────────────────────────────────
///
/// The plaintext token exists once, in `mint`'s return value, to be shown to
/// the owner and forgotten. Nothing here logs it, and the record holds only
/// the hash. The hash is kept from phones (`lib/store-secret-paths.js`
/// PHONE_PRIVATE) and from exports (`lib/store.js`).
///
/// Portable: CryptoKit and Foundation only, so it builds for the phone too.
public enum ApiTokens {

    public static let prefix = "khayt_"
    /// The desktop's label cap (`String(label).slice(0, 60)`).
    public static let maxLabel = 60

    /// A new token: the plaintext to show once, and the record to store.
    /// `scopes` is filtered to `known` — the JavaScript's `SCOPES` — so a
    /// scope nobody grants cannot be written into a record.
    public static func mint(label: String, scopes: [String], known: [String], now: String,
                            random: (Int) -> [UInt8] = ApiTokens.randomBytes) -> (token: String, record: [String: JSONValue]) {
        let token = prefix + base64url(random(32))
        let id = "tok_" + random(8).map { String(format: "%02x", $0) }.joined()
        let clean = scopes.filter { known.contains($0) }
        let record: [String: JSONValue] = [
            "id": .string(id),
            "label": .string(String(label.prefix(maxLabel))),
            "hash": .string(hash(token)),
            "scopes": .array(clean.map { .string($0) }),
            "createdAt": .string(now),
            "lastUsedAt": .null,
        ]
        return (token, record)
    }

    /// SHA-256 hex of a presented token — the only form ever stored.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The token in an `Authorization: Bearer khayt_…` header, or nil — the
    /// desktop's `bearerFromHeader`: case-insensitive scheme, prefixed only.
    public static func bearer(from header: String?) -> String? {
        let h = (header ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard h.count > 6, h.prefix(6).lowercased() == "bearer",
              let first = h.dropFirst(6).first, first.isWhitespace else { return nil }
        let token = h.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.hasPrefix(prefix) ? token : nil
    }

    /// The record a presented token matches, or nil for an unknown or revoked
    /// one. Every stored hash is compared in full, in constant time, so how
    /// long the answer takes says nothing about how close a guess was.
    public static func verify(_ presented: String?, against records: [JSONValue]) -> [String: JSONValue]? {
        guard let presented, presented.hasPrefix(prefix) else { return nil }
        let want = Array(hash(presented).utf8)
        var found: [String: JSONValue]?
        for case .object(let rec) in records {
            guard case .string(let stored)? = rec["hash"] else { continue }
            let got = Array(stored.utf8)
            guard got.count == want.count else { continue }
            var diff: UInt8 = 0
            for i in 0..<want.count { diff |= got[i] ^ want[i] }
            if diff == 0, found == nil { found = rec }
        }
        return found
    }

    /// Does this record carry the scope? Exact: read never implies write.
    public static func hasScope(_ record: [String: JSONValue], _ scope: String) -> Bool {
        guard case .array(let scopes)? = record["scopes"] else { return false }
        return scopes.contains(.string(scope))
    }

    /// The records stored at `settings.lanApi.apiTokens`.
    public static func records(in settings: [String: JSONValue]?) -> [JSONValue] {
        guard case .object(let lan)? = settings?["lanApi"], case .array(let list)? = lan["apiTokens"] else { return [] }
        return list
    }

    public static func randomBytes(_ n: Int) -> [UInt8] {
        var gen = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &gen) }
    }

    /// Node's `toString('base64url')`: `-` and `_`, no padding.
    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
