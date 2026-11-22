import Foundation
import Security

/// Where a connector's keys live on this Mac: the login Keychain, one item per
/// key, named `plugin.<id>.<secret>` — the same name the phone gives its own
/// copy (`ConnectorRules.keychainName`), so the two read alike.
///
/// Never in the book. A key is the shop's credential at someone else's
/// service, and the book goes to every synced device, every paired phone and
/// every backup; each device is given the key it needs, by hand. Never synced
/// to iCloud Keychain, readable only while the Mac is unlocked, never logged.
protocol ConnectorSecretStore: Sendable {
    func value(pluginId: String, name: String) async -> String?
    func set(_ value: String, pluginId: String, name: String) async
    func remove(pluginId: String, name: String) async
}

extension ConnectorSecretStore {
    /// Each of `names` this device holds a non-empty value for.
    func held(pluginId: String, names: [String]) async -> Set<String> {
        var out = Set<String>()
        for n in names { if let v = await value(pluginId: pluginId, name: n), !v.isEmpty { out.insert(n) } }
        return out
    }

    /// Every key a connector declared, gone — what removing it means.
    func removeAll(pluginId: String, names: [String]) async {
        for n in names { await remove(pluginId: pluginId, name: n) }
    }
}

struct ConnectorKeychain: ConnectorSecretStore {
    static let service = "Khayt connector secrets"

    static func account(pluginId: String, name: String) -> String { "plugin.\(pluginId).\(name)" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    // Keychain calls can block on securityd: never on the Swift pool.
    private static let queue = DispatchQueue(label: "khayt.connector.keychain", qos: .userInitiated)

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in Self.queue.async { done.resume(returning: work()) } }
    }

    func value(pluginId: String, name: String) async -> String? {
        let account = Self.account(pluginId: pluginId, name: name)
        return await onQueue {
            var read = Self.query(account)
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func set(_ value: String, pluginId: String, name: String) async {
        let account = Self.account(pluginId: pluginId, name: name)
        let data = Data(value.utf8)
        await onQueue {
            let q = Self.query(account)
            if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
                var add = q
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = Self.service
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                _ = SecItemAdd(add as CFDictionary, nil)
            }
        }
    }

    func remove(pluginId: String, name: String) async {
        let account = Self.account(pluginId: pluginId, name: name)
        await onQueue { _ = SecItemDelete(Self.query(account) as CFDictionary) }
    }
}

/// The keys in memory only — the tests' store, and the sample shop's, never a
/// real shop's.
actor ConnectorMemorySecrets: ConnectorSecretStore {
    private var values: [String: String] = [:]
    func value(pluginId: String, name: String) async -> String? {
        values[ConnectorKeychain.account(pluginId: pluginId, name: name)]
    }
    func set(_ value: String, pluginId: String, name: String) async {
        values[ConnectorKeychain.account(pluginId: pluginId, name: name)] = value
    }
    func remove(pluginId: String, name: String) async {
        values[ConnectorKeychain.account(pluginId: pluginId, name: name)] = nil
    }
}
