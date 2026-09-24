import Foundation
import KhaytCore
import Security

/// Opens a Khayt store for reading. It has no code that writes.
///
/// That is not an oversight, it is the design of this stage. Khayt's write path
/// serialises through one process, and a shop that ran the Electron app and this
/// one at the same time on the same file would race exactly the way two
/// shop-floor tablets did. Until there is a lock, the native app is a reader.
///
/// A reader can still be wrong in a way that matters: showing yesterday's
/// figures as today's, or a total that disagrees with the app the shop actually
/// bills from. So the money here is not recomputed in Swift — it comes from the
/// same engine, through `KhaytEngine`.
public struct StoreReader: Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case noStore(URL)
        case unreadable(URL, any Error)
        case notJSON(URL)
        case noKeychainItem(service: String, status: OSStatus)

        public var description: String {
            switch self {
            case .noStore(let url):
                return "No store at \(url.path). Khayt has not run under this name on this Mac."
            case .unreadable(let url, let e):
                return "Could not read \(url.path): \(e.localizedDescription)"
            case .notJSON(let url):
                return "\(url.lastPathComponent) is not JSON. Do not write to it — the Electron app "
                     + "keeps a .prev alongside, and that is the copy to recover from."
            case .noKeychainItem(let service, let status):
                if status == errSecUserCanceled {
                    return "Keychain access was declined, so the saved credentials stay hidden. "
                         + "Everything else in the store opened normally."
                }
                return "No Keychain item \"\(service)\" (status \(status)). Secrets will show as locked."
            }
        }
    }

    /// Which Khayt wrote the store.
    ///
    /// `app.getName()` names both the userData folder and the Keychain item, and
    /// it is NOT the same in both builds: a development run is `khayt`
    /// (package.json `name`), the shipped app is `Khayt` (electron-builder
    /// `productName`). Two stores, two keys, two sets of a shop's data. Reading
    /// one and writing the other looks exactly like corruption, so the choice is
    /// explicit here rather than a default buried somewhere.
    public enum Build: String, CaseIterable, Sendable {
        case development = "khayt"
        case shipped = "Khayt"

        public var storeURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/\(rawValue)/khayt-store.json")
        }
        public var keychainService: String { "\(rawValue) Safe Storage" }

        /// The other build, whose Keychain item may hold the key to a field in
        /// THIS book.
        ///
        /// The two stores are one store on a case-insensitive volume — which is
        /// every default macOS install — so a field in it may have been sealed
        /// by either app. The Keychain names differ because service names ARE
        /// case-sensitive, and that is the whole asymmetry.
        public var sibling: Build? {
            switch self {
            case .development: return .shipped
            case .shipped: return .development
            }
        }
        public var keychainAccount: String { "\(rawValue) Key" }
        public var exists: Bool { FileManager.default.fileExists(atPath: storeURL.path) }

        /// When this store was last written. Both builds are often present on a
        /// developer's Mac — one of them a copy nobody has touched in weeks —
        /// and the recently written one is the book someone is actually keeping.
        public var lastWritten: Date? {
            try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date
        }
    }

    public let build: Build
    /// The whole store, as values rather than `Any`. Typed decoding happens per
    /// collection: a store is 33 collections and this app reads two of them, so
    /// decoding all of it into models would mean writing 31 models to ignore.
    public let raw: [String: JSONValue]
    /// Nil when the Keychain declined or had nothing. The store still opens;
    /// the secret fields simply stay sealed, which is the right way round.
    public let secretsKey: Data?

    public init(build: Build, unlockSecrets: Bool = false) throws {
        self.build = build
        let url = build.storeURL
        let prev = url.appendingPathExtension("prev")
        let fm = FileManager.default
        // A BOOK LEFT ONLY AS `.prev` — what an interrupted save by an older
        // build (or by Electron) leaves behind. Put it back rather than showing
        // the sample shop as though the shop had none; Electron's
        // `recoverStoreRaw` heals the same case.
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: prev.path) {
            try? fm.copyItem(at: prev, to: url)
        }
        guard fm.fileExists(atPath: url.path) else { throw Failure.noStore(url) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable(url, error) }
        var parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        // A primary that will not parse, with a rollback that does: open the
        // rollback, as Electron does. Nothing is overwritten here; the next
        // save replaces the damaged file, and the damaged one becomes `.prev`.
        if parsed == nil, let older = try? Data(contentsOf: prev) {
            parsed = try? JSONDecoder().decode([String: JSONValue].self, from: older)
        }
        guard let root = parsed else { throw Failure.notJSON(url) }
        self.raw = root
        self.secretsKey = unlockSecrets ? Self.keychainPassword(for: build).map(SafeStorage.key(fromPassword:)) : nil
    }

    /// Make the Keychain item Electron would have made, when there is none.
    ///
    /// ── THE LAST REASON A FRESH MAC NEEDED THE OTHER APP ──────────────────
    ///
    /// `<name> Safe Storage` is created by Chromium's OSCrypt the first time
    /// Electron runs, and this app only ever READ it. So a Mac that has never
    /// run the other app — a new machine with a restored book, which is exactly
    /// how this was found — could obtain a cloud token and then fail to seal
    /// it, and the only cure was to launch Electron once. That is the failure
    /// this app exists not to have.
    ///
    /// The item is a random 16 bytes, base64'd, stored as a generic password
    /// under the same service and account Electron uses — so a later Electron
    /// run finds the key already there and agrees with it, rather than making a
    /// second one. `SafeStorage` then does what it always did: PBKDF2 over this
    /// password with `saltysalt`, 1003 iterations.
    ///
    /// **It never replaces an existing item.** Overwriting one would make every
    /// already-sealed field in the book permanently unreadable — the old
    /// ciphertext is worthless without the old password, and nothing would say
    /// so. `errSecDuplicateItem` is therefore a SUCCESS here: somebody else got
    /// there first and their key is the right one.
    ///
    /// Returns the password, new or existing, or nil when the Keychain refused.
    @discardableResult
    static func ensureKeychainPassword(for build: Build) -> String? {
        if let existing = keychainPassword(for: build) { return existing }

        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let password = Data(bytes).base64EncodedString()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: build.keychainService,
            kSecAttrAccount as String: build.keychainAccount,
            kSecValueData as String: Data(password.utf8),
            // Available once the Mac has been unlocked after boot, and never
            // synced to iCloud: it is the key to this machine's copy.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return password }
        // Somebody created it between the read and the write. Theirs wins.
        if status == errSecDuplicateItem { return keychainPassword(for: build) }
        return nil
    }

    /// The login Keychain item Electron created. Returns nil rather than
    /// throwing: a shop can look at its orders without granting this.
    static func keychainPassword(for build: Build) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: build.keychainService,
            kSecAttrAccount as String: build.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode one collection into a model. A record that does not fit is
    /// skipped and named, never dropped in silence: a store written by a newer
    /// build will carry fields this app has never heard of, and "the list is
    /// short today" is not something a shop should have to notice.
    public func decode<T: Decodable>(_ key: String, as type: T.Type) throws -> (items: [T], skipped: [String]) {
        guard case .array(let rows)? = raw[key] else { return ([], []) }
        var items: [T] = []
        var skipped: [String] = []
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for row in rows {
            do { items.append(try decoder.decode(T.self, from: try encoder.encode(row))) }
            catch {
                var id = "(no id)"
                if case .object(let o) = row, case .string(let s)? = o["id"] { id = s }
                skipped.append("\(id): \(error)")
            }
        }
        return (items, skipped)
    }

    public var settings: JSONValue { raw["settings"] ?? .object([:]) }
}
