import Foundation
import Security
import KhaytCore

/// One file a slicer sent (`LanServer+SlicerUpload`), waiting in the inbox,
/// with what the slicer wrote into it about itself.
struct SlicerUpload: Identifiable, Codable, Equatable, Sendable {
    let id: String
    /// The file's name on disk, made safe — as the slicer named it.
    let name: String
    let arrived: Date
    let bytes: Int
    /// The slicer's own figures (`SlicerFigures`), nil when the file does not
    /// carry them (a binary G-code, a slicer that writes no summary).
    var grams: Double?
    var minutes: Double?
    var material: String?
    var slicer: String?
}

/// ── THE "FROM SLICER" INBOX ──────────────────────────────────────────────
///
/// Beside the book, like the quote form's held files (`QuoteFormFile.heldFolder`):
/// `<book folder>/From slicer/<id>/<name>` plus `info.json`. Not in the
/// library: a file a slicer sent is the shop's own, but which of them become
/// models, jobs or nothing is the shop's call, made in `SlicerInboxSheet`.
/// One folder per upload, so two plates both called `Plate_1.gcode` never
/// meet, and removing one is removing its folder.
enum SlicerInbox {
    static let folderName = "From slicer"
    static let infoName = "info.json"
    /// Files waiting at most. A slicer pointed at the wrong host by mistake
    /// should not fill the shop's disk; past this the upload is refused and
    /// the slicer says so.
    static let maxWaiting = 100

    struct Full: Error, CustomStringConvertible {
        var description: String { "The Khayt slicer inbox is full — clear it in Khayt first" }
    }

    static func root(storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Where an upload's body is spooled while it arrives: inside the inbox's
    /// own folder, so filing it is a rename on the same disk.
    static func incoming(root: URL) -> URL { root.appending(path: ".incoming", directoryHint: .isDirectory) }

    static func file(of item: SlicerUpload, root: URL) -> URL {
        root.appending(path: item.id, directoryHint: .isDirectory).appending(path: item.name)
    }

    /// Everything waiting, newest first. A folder without a readable
    /// `info.json`, or whose file is gone, is not listed.
    static func list(root: URL) -> [SlicerUpload] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [SlicerUpload] = []
        for name in names where !name.hasPrefix(".") {
            let info = root.appending(path: name).appending(path: infoName)
            guard let data = try? Data(contentsOf: info),
                  let item = try? decoder.decode(SlicerUpload.self, from: data),
                  item.id == name,
                  FileManager.default.fileExists(atPath: file(of: item, root: root).path) else { continue }
            out.append(item)
        }
        return out.sorted { $0.arrived > $1.arrived }
    }

    /// Move `upload` into the inbox and write what is known about it.
    static func file(_ upload: URL, name: String, figures: [String: JSONValue]?, root: URL,
                     now: Date = Date()) throws -> SlicerUpload {
        // lock: system — a slicer's upload through the LAN server, which checked its API key; it only fills this Mac's own inbox folder.
        guard list(root: root).count < maxWaiting else { throw Full() }
        let stamp = Int(now.timeIntervalSince1970 * 1000)
        let id = "SU-\(stamp)-\(String(format: "%04x", Int(UInt16.random(in: 0...UInt16.max))))"
        let dir = root.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: name)
        do {
            try FileManager.default.moveItem(at: upload, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: dir) // scratch: the half-made folder of a failed filing
            throw error
        }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        func number(_ key: String) -> Double? {
            if case .number(let n)? = figures?[key], n.isFinite, n > 0 { return n }
            return nil
        }
        func text(_ key: String) -> String? {
            if case .string(let s)? = figures?[key], !s.isEmpty { return s }
            return nil
        }
        let item = SlicerUpload(id: id, name: name, arrived: now, bytes: size,
                                grams: number("filamentGrams"), minutes: number("printTimeMins"),
                                material: text("filamentType"), slicer: text("slicer"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(item).write(to: dir.appending(path: infoName), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: dir) // scratch: the half-made folder of a failed filing
            throw error
        }
        return item
    }

    static func remove(_ item: SlicerUpload, root: URL) {
        // lock: callers — discardSlicerUpload, takeSlicerUpload
        // The inbox's own folder for this one upload — never anything above it.
        guard !item.id.isEmpty, !item.id.contains("/"), !item.id.hasPrefix(".") else { return }
        try? FileManager.default.removeItem(at: root.appending(path: item.id, directoryHint: .isDirectory))
    }
}

/// The key a slicer sends as `X-Api-Key`, and whether this Mac takes uploads
/// at all.
///
/// ── THIS MAC'S, NOT THE BOOK'S ───────────────────────────────────────────
///
/// A slicer is pointed at THIS Mac's address, so its key belongs to this Mac
/// the way its LAN identity does (`LanIdentity`): kept in the login Keychain,
/// not synced, never written into the book — where it would travel to every
/// paired phone in `/api/store` and to every other copy of the book. The
/// switch is a Mac-local preference for the same reason, off by default.
enum SlicerKey {
    static let service = "Khayt Slicer Upload"
    static let account = "octoprint"
    static let acceptKey = "mac.slicerUploadAccept"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    static var accepting: Bool {
        get { UserDefaults.standard.bool(forKey: acceptKey) }
        set { UserDefaults.standard.set(newValue, forKey: acceptKey) }
    }

    /// The key when uploads are switched on — what the server checks.
    static func active() -> String? { accepting ? current() : nil }

    /// OctoPrint's own shape: 32 upper-case hex characters, 128 random bits.
    static func mint() -> String {
        (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// The key, made the first time it is asked for. Nil only when the
    /// Keychain refuses to keep one.
    static func current() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let raw = out as? Data,
           let kept = String(data: raw, encoding: .utf8), !kept.isEmpty {
            cached = kept
            return kept
        }
        return storeLocked(mint())
    }

    /// A new key; every slicer holding the old one is refused from now on.
    @discardableResult
    static func regenerate() -> String? {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(base as CFDictionary)
        cached = nil
        return storeLocked(mint())
    }

    private static func storeLocked(_ key: String) -> String? {
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "Khayt slicer upload key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        cached = key
        return key
    }
}
