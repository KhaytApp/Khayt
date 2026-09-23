import Foundation

/**
 * This phone's own sign-in to Khayt Cloud, for when the Mac is out of reach.
 *
 * ── ITS OWN, NOT THE MAC'S ────────────────────────────────────────────────
 *
 * The phone signs in with the shop's email and password (`POST /v1/login`) and
 * gets a DEVICE token of its own: it carries the account's role, it can be
 * revoked on its own, and a password reset signs it out with every other
 * device. Borrowing the Mac's token over the LAN would put a shop-wide
 * credential on plain HTTP, and would make the phone's cloud access last as
 * long as the Mac's rather than as long as the person's.
 *
 * ── WHERE EACH PART LIVES ─────────────────────────────────────────────────
 *
 * The token and the data key (DEK) are secrets: Keychain, this device only,
 * after first unlock — the same class the LAN PIN uses, so neither goes into a
 * backup and neither is readable before the phone has been unlocked once.
 * The address, shop id, role and the revision last seen are not secrets and
 * live in the shared defaults, where the widget could read them too.
 *
 * The passphrase itself is never kept. It opens the keyset once, at sign-in;
 * what is kept is the key it opened.
 */
struct CloudSession: Equatable, Sendable {
    var url: String
    var shopId: String
    var token: String
    /// The shop's data key, opened from the keyset with the passphrase.
    var dek: Data
    /// `owner`, `manager`, `operator` or `viewer`. A viewer reads and never sends.
    var role: String
    /// The cloud's head revision as of this phone's last pull; `?since=` asks
    /// for the changes after it. Nil means the next pull is a cold one.
    var seenRev: Int?

    static let defaultURL = "https://cloud.khaytapp.com"

    var canWrite: Bool { role != "viewer" }

    // MARK: - Storage

    private enum Keys {
        static let token = "khayt.cloud.token"
        static let dek = "khayt.cloud.dek"
        static let url = "khayt.cloud.url"
        static let shopId = "khayt.cloud.shopId"
        static let role = "khayt.cloud.role"
        static let seenRev = "khayt.cloud.seenRev"
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.com.khaytapp.companion") ?? .standard
    }

    /// The saved session, or nil when this phone is not signed in to the cloud.
    static func load(defaults: UserDefaults = Self.defaults) -> CloudSession? {
        guard let url = defaults.string(forKey: Keys.url), !url.isEmpty,
              let shopId = defaults.string(forKey: Keys.shopId), !shopId.isEmpty,
              let token = KeychainHelper.get(Keys.token), !token.isEmpty,
              let dekText = KeychainHelper.get(Keys.dek), let dek = Data(base64Encoded: dekText),
              !dek.isEmpty else { return nil }
        let seen = defaults.object(forKey: Keys.seenRev) as? Int
        return CloudSession(url: url, shopId: shopId, token: token, dek: dek,
                            role: defaults.string(forKey: Keys.role) ?? "owner", seenRev: seen)
    }

    func save(defaults: UserDefaults = Self.defaults) {
        KeychainHelper.set(token, for: Keys.token)
        KeychainHelper.set(dek.base64EncodedString(), for: Keys.dek)
        defaults.set(url, forKey: Keys.url)
        defaults.set(shopId, forKey: Keys.shopId)
        defaults.set(role, forKey: Keys.role)
        if let seenRev { defaults.set(seenRev, forKey: Keys.seenRev) } else { defaults.removeObject(forKey: Keys.seenRev) }
    }

    /// Sign this phone out of the cloud: the token, the key and the cursor go.
    /// Called by `ConnectionSettings.unpair()` as well — a phone that forgets
    /// the shop must not keep a key to the shop's cloud copy.
    static func forget(defaults: UserDefaults = Self.defaults) {
        KeychainHelper.delete(Keys.token)
        KeychainHelper.delete(Keys.dek)
        for key in [Keys.url, Keys.shopId, Keys.role, Keys.seenRev] { defaults.removeObject(forKey: key) }
    }
}
