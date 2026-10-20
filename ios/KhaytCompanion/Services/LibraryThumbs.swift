import CryptoKit
import Foundation

/// Library thumbnails kept on the phone, so a model looks the same away from
/// the shop as it did on its Wi-Fi.
///
/// The library copy that comes with the cloud sync has no pictures (they
/// live in the Mac's library folder, not in the book), and people find a
/// model by its picture first. Every thumbnail the Mac sends is kept here,
/// up to `budget` bytes, oldest-used dropped first. It is a cache, under
/// Caches, so iOS may also empty it when space runs short; nothing is lost
/// that the Mac cannot send again.
actor LibraryThumbs {
    static let shared = LibraryThumbs()

    private let directory: URL
    private let budget: Int
    private let fileManager = FileManager.default
    /// Bytes on disk, counted once and then kept up to date.
    private var used: Int?

    init(directory: URL? = nil, budget: Int = 80_000_000) {
        self.directory = directory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryThumbs", isDirectory: true)
        self.budget = budget
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                         attributes: [.protectionKey: FileProtectionType.complete])
    }

    /// A model id can hold anything a filename cannot.
    nonisolated func name(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func url(_ id: String) -> URL { directory.appendingPathComponent(name(id)) }

    /// The kept picture and how long ago the Mac sent it.
    func get(_ id: String, now: Date = Date()) -> (data: Data, age: TimeInterval)? {
        let url = url(id)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let sent = date(url, Self.sentKey) ?? .distantPast
        // Seen now: the last to be dropped.
        setDate(url, Self.seenKey, now)
        return (data, now.timeIntervalSince(sent))
    }

    /// Which of these models have a picture here.
    func kept(_ ids: [String]) -> Set<String> {
        Set(ids.filter { fileManager.fileExists(atPath: url($0).path) })
    }

    func put(_ id: String, _ data: Data, now: Date = Date()) {
        let url = url(id)
        // Counted before the write, or the new picture would count twice.
        let onDisk = used ?? total()
        let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else { return }
        setDate(url, Self.sentKey, now)
        setDate(url, Self.seenKey, now)
        used = onDisk - before + data.count
        trim()
    }

    /// The Mac has no picture for it any more.
    func remove(_ id: String) {
        let url = url(id)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard (try? fileManager.removeItem(at: url)) != nil else { return }
        if let u = used { used = u - size }
    }

    /// Forget every picture: unpairing ends this shop on the phone.
    func clear() {
        for file in files() { try? fileManager.removeItem(at: file) }
        used = 0
    }

    // MARK: -

    private func files() -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    }

    private func total() -> Int {
        files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func trim() {
        guard var bytes = used, bytes > budget else { return }
        let byUse = files().map { url -> (URL, Date, Int) in
            (url, date(url, Self.seenKey) ?? .distantPast,
             (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }.sorted { $0.1 < $1.1 }
        // Down to nine tenths, so the next few pictures do not each trim again.
        for (url, _, size) in byUse where bytes > budget * 9 / 10 {
            if (try? fileManager.removeItem(at: url)) != nil { bytes -= size }
        }
        used = bytes
    }

    // When the Mac sent it, and when it was last looked at, on the file
    // itself, so the two cannot drift apart from it.
    private static let sentKey = "com.khaytapp.sent"
    private static let seenKey = "com.khaytapp.seen"

    private func setDate(_ url: URL, _ key: String, _ date: Date) {
        var t = date.timeIntervalSince1970
        _ = withUnsafeBytes(of: &t) { raw in setxattr(url.path, key, raw.baseAddress, raw.count, 0, 0) }
    }

    private func date(_ url: URL, _ key: String) -> Date? {
        var t: TimeInterval = 0
        let n = withUnsafeMutableBytes(of: &t) { raw in getxattr(url.path, key, raw.baseAddress, raw.count, 0, 0) }
        return n == MemoryLayout<TimeInterval>.size ? Date(timeIntervalSince1970: t) : nil
    }
}
