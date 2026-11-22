import Foundation

/**
 * The last good answer for each GET, kept on disk so the app is not blank when
 * the desktop is out of reach.
 *
 * The companion is used away from the desk — in the back room, at the machines,
 * on the far side of a workshop — which is exactly where Wi-Fi is worst. Until
 * this existed every screen was fed live and nothing was retained, so losing the
 * connection meant losing the queue, the orders and the inventory all at once.
 * A shop that cannot see what is printing is a shop that walks back to the desk.
 *
 * Deliberately READ-ONLY. Writes still require a live connection: they are
 * refused rather than queued, because a queued write is a promise about ordering
 * and conflict resolution that this app is in no position to keep. The desktop
 * owns the data; the phone shows it and asks politely to change it.
 *
 * Stored under Application Support with `.completeFileProtection`, so the file
 * is unreadable while the device is locked. This is a shop's client list —
 * names, phone numbers, what they ordered — and it does not belong in plaintext
 * on a phone that might be left on a workbench.
 */
actor CompanionCache {
    static let shared = CompanionCache()

    private let directory: URL
    private let fileManager = FileManager.default

    /// Envelope so a cached payload always arrives with the time it was true.
    private struct Entry<T: Codable>: Codable {
        let storedAt: Date
        let value: T
    }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true))
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("KhaytCache", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                         attributes: [.protectionKey: FileProtectionType.complete])
    }

    /// A stable, filesystem-safe name for an endpoint path.
    ///
    /// Paths carry `/`, `?` and `=`, none of which can be a filename, and
    /// truncating instead of hashing would collide `/api/orders?limit=40` with
    /// `/api/orders?limit=41` — two different answers in one slot.
    nonisolated func key(for path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV-1a, 64-bit
        for byte in Array(path.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    private func url(for path: String) -> URL {
        directory.appendingPathComponent("\(key(for: path)).json")
    }

    /// Remember the answer to `path`. Failures are swallowed on purpose — a
    /// cache that cannot write must never break a request that already worked.
    func store<T: Codable>(_ value: T, for path: String) {
        let entry = Entry(storedAt: Date(), value: value)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url(for: path), options: [.atomic, .completeFileProtection])
    }

    /// The last good answer for `path`, with the time it was true, or nil.
    func load<T: Codable>(_ type: T.Type, for path: String) -> (value: T, storedAt: Date)? {
        guard let data = try? Data(contentsOf: url(for: path)),
              let entry = try? JSONDecoder().decode(Entry<T>.self, from: data) else { return nil }
        return (entry.value, entry.storedAt)
    }

    /// Forget everything. Used when unpairing — a cached client list must not
    /// outlive the connection to the shop it came from.
    func clear() {
        guard let files = try? fileManager.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: nil) else { return }
        for file in files { try? fileManager.removeItem(at: file) }
    }
}
