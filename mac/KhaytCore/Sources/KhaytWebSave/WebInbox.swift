import Foundation

/// Where saves from the browser wait for the app, and how each side answers.
///
/// ── ONE FOLDER IN THE APP GROUP'S CONTAINER ───────────────────────────────
///
/// The Safari extension is sandboxed and may write nowhere but its own
/// container and the app group's, so the group is where the inbox has to be —
/// the same group the desktop widgets read their snapshot from
/// (`ShopWidgetSnapshot.groupInfoKey`, `<team>.app.khayt.mac`, named after
/// whoever signed the build and written into every bundle's Info.plist by
/// `make-app.sh`). The Chromium host is not sandboxed and joins the same group
/// so that nothing needs two inboxes.
///
///     <group>/WebInbox/WS-<uuid>.json      a save, waiting for the app
///     <group>/WebInbox/results/WS-<uuid>.json   the app's answer to it
///
/// A save is written to a temporary name and moved into place, so the app
/// never reads half a file. The app answers every file it reads — saved,
/// updated, refused — and removes it; the extension's end waits a few seconds
/// for that answer, and when none comes (Khayt is not open) tells the shop the
/// page will be added when it is. An ad-hoc build has no team and no group: it
/// has no inbox, and the extension is told Khayt cannot be reached.
public enum WebInbox {

    public static let folderName = "WebInbox"
    public static let resultsFolderName = "results"
    /// Saves older than this are not answered any more; a reply that late is
    /// for a popup that closed long ago.
    public static let resultLifetime: TimeInterval = 60

    /// The inbox inside a group container (made when missing).
    public static func directory(inGroupContainer container: URL) -> URL {
        container.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// The group container this bundle's Info.plist names, or nil — no key
    /// (an ad-hoc build) or no container.
    public static func groupContainer(bundle: Bundle = .main) -> URL? {
        guard let group = bundle.object(forInfoDictionaryKey: "KhaytAppGroup") as? String,
              !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    public static func directory(bundle: Bundle = .main) -> URL? {
        groupContainer(bundle: bundle).map { directory(inGroupContainer: $0) }
    }

    // MARK: - Writing a save (the extension's end)

    /// Put one checked entry in the inbox: written whole under a dot-name,
    /// then moved to its own name in one step.
    public static func write(_ entry: WebSave.Entry, into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let temp = dir.appending(path: ".\(entry.id).part")
        try data.write(to: temp, options: .atomic)
        let final = dir.appending(path: "\(entry.id).json")
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: temp, to: final)
    }

    // MARK: - Answers

    /// What happened to one save. The raw values are what the popup shows by.
    public enum State: String, Codable, Sendable {
        /// A new record in the library.
        case saved
        /// The same page saved before: its record was brought up to date.
        case updated
        /// A download attached to a saved record.
        case attached
        /// A download that belongs to a saved record, put to the shop: the
        /// app asks before it adds anything (`WebSaveInbox.offers`).
        case offered
        /// Written, and no answer yet — Khayt is not open, or busy.
        case queued
        /// The app would not take it: saving from the browser is switched off
        /// on this Mac, the person signed in may not change the library, or
        /// the book cannot be written (the sample).
        case refused
        /// The message did not pass `WebSave`'s checks.
        case invalid
    }

    public struct Result: Codable, Equatable, Sendable {
        public var id: String
        public var state: State
        /// Why, for `refused` and `invalid`: `off`, `not-allowed`, `sample`,
        /// `no-record`, or a `WebSave.Refusal` raw value.
        public var reason: String?
        public var title: String?

        public init(id: String, state: State, reason: String? = nil, title: String? = nil) {
            self.id = id; self.state = state; self.reason = reason; self.title = title
        }

        /// As the extension receives it.
        public var message: [String: Any] {
            var o: [String: Any] = ["ok": state == .saved || state == .updated || state == .attached
                                        || state == .offered || state == .queued,
                                    "state": state.rawValue, "id": id]
            if let reason { o["reason"] = reason }
            if let title { o["title"] = title }
            return o
        }
    }

    public static func resultsDirectory(_ inbox: URL) -> URL {
        inbox.appending(path: resultsFolderName, directoryHint: .isDirectory)
    }

    /// The app's answer to one save.
    public static func answer(_ result: Result, inbox: URL) throws {
        guard WebSave.isEntryId(result.id) else { return }
        let dir = resultsDirectory(inbox)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(result)
        try data.write(to: dir.appending(path: "\(result.id).json"), options: .atomic)
    }

    /// Wait up to `timeout` for the app's answer to `id`, taking it out of the
    /// folder when it comes. Nil when none came.
    public static func awaitAnswer(_ id: String, inbox: URL, timeout: TimeInterval,
                                   poll: TimeInterval = 0.15) -> Result? {
        guard WebSave.isEntryId(id) else { return nil }
        let file = resultsDirectory(inbox).appending(path: "\(id).json")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let data = try? Data(contentsOf: file), data.count < 16_384,
               let result = try? JSONDecoder().decode(Result.self, from: data), result.id == id {
                try? FileManager.default.removeItem(at: file)
                return result
            }
            Thread.sleep(forTimeInterval: poll)
        } while Date() < deadline
        return nil
    }

    /// The saves waiting, oldest first. Only files named the way `write`
    /// names them; anything else in the folder is left alone.
    public static func pending(in inbox: URL) -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let names = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        let saves = names.filter {
            $0.pathExtension == "json" && WebSave.isEntryId($0.deletingPathExtension().lastPathComponent)
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        func made(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return saves.sorted { made($0) < made($1) }
    }

    /// Take one waiting save for this process: moved to a hidden name first,
    /// so a second copy of the app reading the same inbox (an installed build
    /// and a dev build, both open) cannot file it twice. Nil when another got
    /// there first. The bytes are read with a cap — a file this size is no
    /// save of ours.
    public static func claim(_ file: URL) -> Data? {
        let mine = file.deletingLastPathComponent()
            .appending(path: ".claimed-\(ProcessInfo.processInfo.processIdentifier)-\(file.lastPathComponent)")
        guard (try? FileManager.default.moveItem(at: file, to: mine)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: mine) }
        guard let size = try? mine.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= WebSave.maxMessageBytes * 2 else { return Data() }
        return try? Data(contentsOf: mine)
    }

    /// Answers nobody collected — the popup closed — taken out once stale.
    public static func sweepAnswers(inbox: URL, now: Date = Date()) {
        let dir = resultsDirectory(inbox)
        guard let names = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in names {
            let at = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(at) > resultLifetime { try? FileManager.default.removeItem(at: u) }
        }
    }
}
