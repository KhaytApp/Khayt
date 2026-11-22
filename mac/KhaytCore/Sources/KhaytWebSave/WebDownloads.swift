import Foundation

/// ── A DOWNLOAD THAT BELONGS TO A SAVED PAGE ──────────────────────────────
///
/// After a page is saved, the shop usually downloads the model from it. Two
/// ways that download is noticed, and the app ASKS before either is added
/// (`WebSaveInbox.offers`) — nothing is attached on its own:
///
/// * Chrome, Edge, Brave, Vivaldi and Firefox: the extension's `downloads`
///   permission. For `WebSave.attachWindow` after a save, the background
///   matches each finished download against the saved page (`background.js`
///   `matchDownload`) and sends an `attach` message with the file's path.
/// * Safari has no downloads API, so the APP watches `~/Downloads` instead —
///   only while a Safari save is less than `attachWindow` old, and only for a
///   file that was not there when the save came in (`newModels`).
public enum WebDownloads {

    /// One entry of a folder listing, as the watch sees it.
    public struct Listed: Equatable, Sendable {
        public var name: String
        public var isRegularFile: Bool
        public var size: Int
        public init(name: String, isRegularFile: Bool, size: Int) {
            self.name = name; self.isRegularFile = isRegularFile; self.size = size
        }
    }

    /// The model files in `listing` that have finished arriving: not in
    /// `baseline` (there before the save), not hidden, a plain file (Safari's
    /// download in progress is a `.download` folder, Chrome's a `.crdownload`
    /// and Firefox's a `.part`), not empty, and the same size as at the last
    /// look (`sizes`, which this updates) — a file still growing waits.
    public static func newModels(_ listing: [Listed], baseline: Set<String>, sizes: inout [String: Int],
                                 offered: Set<String>) -> [String] {
        var ready: [String] = []
        var next: [String: Int] = [:]
        for item in listing {
            guard !baseline.contains(item.name), !item.name.hasPrefix("."), item.isRegularFile,
                  item.size > 0, WebSave.isModelFile(item.name), !offered.contains(item.name) else { continue }
            if sizes[item.name] == item.size { ready.append(item.name) }
            next[item.name] = item.size
        }
        sizes = next
        return ready.sorted()
    }

    /// Whether `path` may be offered at all: absolute, inside `home`, a
    /// model kind, and — read from the item itself, not where a link points —
    /// a plain file that is not empty.
    ///
    /// Inside `home` by its REAL path as well: a folder in Downloads that is
    /// a link to somewhere else does not make a file there one of the shop's
    /// downloads (`resolvingSymlinksInPath`, both sides).
    public static func isOfferable(_ path: String, home: URL) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let homePath = home.standardizedFileURL.path
        let realHome = home.standardizedFileURL.resolvingSymlinksInPath().path
        let real = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: url.lastPathComponent).path
        func inside(_ p: String, _ h: String) -> Bool { p.hasPrefix(h.hasSuffix("/") ? h : h + "/") }
        guard path.hasPrefix("/"), inside(url.path, homePath), inside(real, realHome),
              WebSave.isModelFile(url.path),
              let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? 0) > 0 else { return false }
        return true
    }

    /// The archive kinds: a download in one of these is opened and its model
    /// taken out, never filed as itself.
    public static let archiveKinds: Set<String> = ["zip", "7z", "rar"]
}
