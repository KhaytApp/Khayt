import Foundation
import Security
import KhaytCore

/// Where this Mac keeps its MakerRun link: the login Keychain, one item.
///
/// The desktop keeps the same tokens in `bedready-account.json` in its own
/// app data, sealed with the OS keystore (`lib/makerrun-account.js`). The link
/// is this MAC's, not the shop's — a second Mac signs in for itself — so it is
/// not in the book, where every synced device and paired phone would get it.
///
/// Never logged, never synchronised to iCloud Keychain, readable only when the
/// Mac is unlocked. Every call runs on a dispatch queue: Keychain calls can
/// block on securityd, and the Swift pool is not the place to wait for it.
struct MakerRunKeychain: MakerRunTokenStore {
    static let service = "Khayt MakerRun Link"
    let account: String

    init(account: String = "makerrun.com") { self.account = account }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private static let queue = DispatchQueue(label: "khayt.makerrun.keychain", qos: .userInitiated)

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in Self.queue.async { done.resume(returning: work()) } }
    }

    func load() async -> MakerRunTokens? {
        let account = self.account
        let data: Data? = await onQueue {
            var read = Self.query(account)
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(MakerRunTokens.self, from: data)
    }

    func save(_ tokens: MakerRunTokens) async {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let account = self.account
        await onQueue {
            let q = Self.query(account)
            let update: [String: Any] = [kSecValueData as String: data]
            if SecItemUpdate(q as CFDictionary, update as CFDictionary) == errSecItemNotFound {
                var add = q
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = Self.service
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                _ = SecItemAdd(add as CFDictionary, nil)
            }
        }
    }

    func clear(onlyIf refresh: String?) async {
        if let refresh, let current = await load(), current.refresh != refresh { return }
        let account = self.account
        await onQueue { _ = SecItemDelete(Self.query(account) as CFDictionary) }
    }
}

/// The tokens in memory only — the tests' store, and never the app's.
actor MakerRunMemoryStore: MakerRunTokenStore {
    var tokens: MakerRunTokens?
    init(_ tokens: MakerRunTokens? = nil) { self.tokens = tokens }
    func load() async -> MakerRunTokens? { tokens }
    func save(_ tokens: MakerRunTokens) async { self.tokens = tokens }
    func clear(onlyIf refresh: String?) async {
        if let refresh, let t = tokens, t.refresh != refresh { return }
        tokens = nil
    }
}
