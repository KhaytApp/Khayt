import Foundation
import Security

/// Validates desktop LAN host strings before building HTTP URLs (blocks userinfo / path injection).
enum LANHostValidator {
    private static let maxHostLength = 253

    /// Parses host field; if user pasted `192.168.1.5:3219`, updates `effectivePort` when valid.
    static func normalizeHost(_ raw: String, effectivePort: inout Int) -> String? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, h.count <= maxHostLength else { return nil }

        if h.hasPrefix("http://") { h = String(h.dropFirst(7)) }
        if h.hasPrefix("https://") { h = String(h.dropFirst(8)) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if let q = h.firstIndex(of: "?") { h = String(h[..<q]) }
        if let hash = h.firstIndex(of: "#") { h = String(h[..<hash]) }

        if h.contains("@") || h.contains("\\") || h.contains(" ") || h.contains("\t") { return nil }

        // Allow `192.168.1.42:3219` or `hostname.local:3219` in the host field.
        if !h.hasPrefix("["), let colon = h.lastIndex(of: ":") {
            let portPart = h[h.index(after: colon)...]
            if let parsed = Int(portPart), (1024...65535).contains(parsed) {
                effectivePort = parsed
                h = String(h[..<colon])
            }
        }

        // An IPv6 literal, bracketed — and possibly SCOPED. A Mac found by
        // Bonjour often resolves to a link-local address, which only means
        // something with the interface it was found on: `fe80::1%en0`, written
        // in a URL as `[fe80::1%25en0]`. The zone used to be refused here, so
        // the address the phone had just found was "not configured" and
        // pairing could not continue. It comes back BRACKETED, zone encoded,
        // for `baseURL` to set as an already-encoded host.
        if h.hasPrefix("[") {
            guard h.hasSuffix("]"), h.count > 2 else { return nil }
            let inner = String(h.dropFirst().dropLast())
            return scopedIPv6(inner).map { "[\($0)]" }
        }

        // `Turkis-MacBook-Air.local.` — a resolver's fully-qualified name ends
        // in a dot, and it names the same host without one.
        if h.hasSuffix("."), !h.hasSuffix("..") { h.removeLast() }

        guard isValidIPv4(h) || isValidHostname(h) else { return nil }
        return h
    }

    /// `fe80::1`, `fe80::1%25en0` or `fe80::1%en0` → the literal with its zone
    /// percent-encoded, or nil. A zone is an interface name: letters and digits.
    private static func scopedIPv6(_ inner: String) -> String? {
        var address = inner
        var zone: String?
        if let range = inner.range(of: "%25") ?? inner.range(of: "%") {
            address = String(inner[..<range.lowerBound])
            zone = String(inner[range.upperBound...])
        }
        guard isValidIPv6Literal(address) else { return nil }
        guard let zone else { return address }
        guard !zone.isEmpty, zone.count <= 16,
              zone.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else { return nil }
        return address + "%25" + zone
    }

    private static func isValidIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let n = Int(part), n >= 0, n <= 255, part.count <= 3 else { return false }
            if part.count > 1 && part.hasPrefix("0") { return false }
        }
        return true
    }

    private static func isValidIPv6Literal(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 45 else { return false }
        return host.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF:").contains($0)
        }
    }

    private static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= maxHostLength else { return false }
        if host.hasPrefix(".") || host.hasSuffix(".") || host.contains("..") { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

enum InputLimits {
    static let maxTextField = 200
    static let maxMaterial = 120

    static func clamp(_ value: String, max: Int = maxTextField) -> String {
        String(value.prefix(max))
    }
}

@MainActor
final class ConnectionSettings: ObservableObject {
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Keys.host) }
    }
    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
    }
    @Published var pin: String {
        didSet { KeychainHelper.set(pin, for: Keys.pinKeychain) }
    }
    @Published var isPaired: Bool {
        didSet { UserDefaults.standard.set(isPaired, forKey: Keys.paired) }
    }
    @Published var shopLabel: String {
        didSet { UserDefaults.standard.set(shopLabel, forKey: Keys.shopLabel) }
    }
    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: Keys.language)
            L10n.setLanguage(appLanguage)
        }
    }
    @Published var notifyQueueChanges: Bool {
        didSet { UserDefaults.standard.set(notifyQueueChanges, forKey: Keys.notifyQueue) }
    }
    @Published var notifyConnection: Bool {
        didSet { UserDefaults.standard.set(notifyConnection, forKey: Keys.notifyConnection) }
    }
    @Published var notifyOverdue: Bool {
        didSet { UserDefaults.standard.set(notifyOverdue, forKey: Keys.notifyOverdue) }
    }
    @Published var notifyLowStock: Bool {
        didSet { UserDefaults.standard.set(notifyLowStock, forKey: Keys.notifyLowStock) }
    }

    enum Keys {
        static let host = "khayt.host"
        static let port = "khayt.port"
        static let shopLabel = "khayt.shopLabel"
        static let pinKeychain = "khayt.lanPin"
        static let paired = "khayt.paired"
        static let language = "khayt.language"
        static let notifyQueue = "khayt.notify.queue"
        static let notifyConnection = "khayt.notify.connection"
        static let notifyOverdue = "khayt.notify.overdue"
        static let notifyLowStock = "khayt.notify.lowstock"
    }

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: Keys.host) ?? ""
        port = defaults.object(forKey: Keys.port) as? Int ?? 3219
        shopLabel = defaults.string(forKey: Keys.shopLabel) ?? "My Shop"
        isPaired = defaults.bool(forKey: Keys.paired)
        pin = KeychainHelper.get(Keys.pinKeychain) ?? ""
        let langRaw = defaults.string(forKey: Keys.language) ?? AppLanguage.system.rawValue
        appLanguage = AppLanguage(rawValue: langRaw) ?? .system
        notifyQueueChanges = defaults.object(forKey: Keys.notifyQueue) as? Bool ?? true
        notifyConnection = defaults.object(forKey: Keys.notifyConnection) as? Bool ?? true
        notifyOverdue = defaults.object(forKey: Keys.notifyOverdue) as? Bool ?? true
        notifyLowStock = defaults.object(forKey: Keys.notifyLowStock) as? Bool ?? true
        L10n.setLanguage(appLanguage)
    }

    /// Human-readable endpoint for errors (e.g. `http://192.168.1.42:3219`).
    var displayURL: String {
        guard let base = baseURL else { return host.isEmpty ? "—" : host }
        return base.absoluteString
    }

    var hostValidationError: String? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.tr("settings.host_required")
        }
        if baseURL == nil { return L10n.tr("settings.host_invalid") }
        return nil
    }

    /// HTTP base URL built with `URLComponents` (no relative URL resolution).
    var baseURL: URL? { Self.baseURL(host: host, port: port) }

    /// The desktop's address as a URL, or nil when the host is not one this app
    /// will connect to. Static so the resolver's output can be tested against
    /// it directly — the two halves once disagreed about a scoped IPv6 address
    /// and nothing noticed, because each was tested on its own.
    nonisolated static func baseURL(host: String, port: Int) -> URL? {
        var effectivePort = port
        guard let hostPart = LANHostValidator.normalizeHost(host, effectivePort: &effectivePort) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        if hostPart.hasPrefix("[") {
            // Already bracketed and encoded — see `normalizeHost`.
            components.percentEncodedHost = hostPart
        } else {
            components.host = hostPart
        }
        components.port = effectivePort
        return components.url
    }

    var isConfigured: Bool { baseURL != nil }

    func unpair() {
        isPaired = false
        pin = ""
        KeychainHelper.delete(Keys.pinKeychain)
        // The offline cache holds the shop's client list, orders and inventory.
        // Dropping the PIN while leaving that on disk would mean "unpaired" only
        // stops new reads, and everything already fetched stays readable.
        Task { await CompanionCache.shared.clear() }
        // And the book, which is the same argument with more in it: the cache
        // holds the answers this phone happened to ask for, the book holds the
        // shop. `forget` takes the `.prev` rollback copy too — it is the same
        // client list, one write behind.
        try? CompanionBook.inSharedContainer().forget()
        // And the cloud sign-in: a device token and the shop's data key are a
        // way back into everything the book held.
        CloudSession.forget()
    }
}

enum KeychainHelper {
    private static let service = Bundle.main.bundleIdentifier ?? "com.khaytapp.companion"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // Best-effort; UI still holds PIN until next launch.
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
