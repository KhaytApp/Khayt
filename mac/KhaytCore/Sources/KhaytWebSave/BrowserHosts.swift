import Foundation

/// ── THE BROWSER HOST'S MANIFESTS: WRITTEN ON A CLICK, REMOVED ON A CLICK ──
///
/// Chrome, Chromium, Edge, Brave, Vivaldi and Firefox find a native host by
/// a small JSON file — the HOST MANIFEST — in a `NativeMessagingHosts` folder
/// of their own under `~/Library/Application Support`. It names the program
/// (`Khayt.app/Contents/MacOS/khayt-browser-host`) and the extensions allowed
/// to start it. Nothing else connects the browser to Khayt.
///
/// Khayt writes one only when the shop presses Install for that browser in
/// Settings ▸ Preferences ▸ Browser extension, and never on its own — not at
/// launch, not after an update. Remove deletes the file only when it is the
/// one Khayt wrote (its name and a program inside a `Khayt.app`); a file of
/// the same name that is anything else is reported and left alone.
///
/// Addressed by a HOME folder rather than the user's, so the tests run
/// against a temporary one and never a real browser profile.
public enum BrowserHosts {

    /// The host's name, as the extension calls it (`background.js` `HOST`).
    public static let hostName = "app.khayt.mac"
    /// The program, inside Khayt.app.
    public static let executableName = "khayt-browser-host"
    public static let description = "Save to Khayt — sends a model page you save to the Khayt app on this Mac"
    /// Firefox's id for Save to Khayt (`extension-khayt/pack.mjs` `GECKO_ID`).
    public static let firefoxExtensionId = "save@khaytapp.com"
    /// Chromium ids a developer adds for an unpacked copy (see `BrowserExtensionIds`).
    public static let devIdsKey = "mac.sfw_devExtensionIds"

    public enum Browser: String, CaseIterable, Sendable, Identifiable {
        case chrome, chromium, edge, brave, vivaldi, firefox
        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .chrome: "Google Chrome"
            case .chromium: "Chromium"
            case .edge: "Microsoft Edge"
            case .brave: "Brave"
            case .vivaldi: "Vivaldi"
            case .firefox: "Firefox"
            }
        }

        /// The browser's application bundle id, for "is it installed".
        public var bundleIdentifier: String {
            switch self {
            case .chrome: "com.google.Chrome"
            case .chromium: "org.chromium.Chromium"
            case .edge: "com.microsoft.edgemac"
            case .brave: "com.brave.Browser"
            case .vivaldi: "com.vivaldi.Vivaldi"
            case .firefox: "org.mozilla.firefox"
            }
        }

        /// Its folder under `~/Library/Application Support` (the browser's
        /// own documentation for per-user native messaging hosts on macOS).
        public var supportFolder: String {
            switch self {
            case .chrome: "Google/Chrome"
            case .chromium: "Chromium"
            case .edge: "Microsoft Edge"
            case .brave: "BraveSoftware/Brave-Browser"
            case .vivaldi: "Vivaldi"
            case .firefox: "Mozilla"
            }
        }

        public var isChromium: Bool { self != .firefox }
    }

    /// `<home>/Library/Application Support/<browser>/NativeMessagingHosts`.
    public static func hostsFolder(_ browser: Browser, home: URL) -> URL {
        home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: browser.supportFolder, directoryHint: .isDirectory)
            .appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
    }

    public static func manifestURL(_ browser: Browser, home: URL) -> URL {
        hostsFolder(browser, home: home).appending(path: "\(hostName).json")
    }

    /// The extensions a Chromium manifest lets in: the stores' ids, then any
    /// developer ids, each checked, no repeats.
    public static func chromiumIds(dev: [String]) -> [String] {
        var seen = Set<String>()
        return (BrowserExtensionIds.store + dev).filter { BrowserExtensionIds.isChromiumId($0) && seen.insert($0).inserted }
    }

    /// The manifest for one browser. Nil for a Chromium browser while no
    /// extension id is known — a manifest that lets nobody in is not written.
    public static func manifest(_ browser: Browser, hostPath: String, chromiumIds ids: [String]) -> [String: Any]? {
        var m: [String: Any] = ["name": hostName, "description": description, "path": hostPath, "type": "stdio"]
        if browser.isChromium {
            guard !ids.isEmpty else { return nil }
            m["allowed_origins"] = ids.map { "chrome-extension://\($0)/" }
        } else {
            m["allowed_extensions"] = [firefoxExtensionId]
        }
        return m
    }

    public static func manifestData(_ manifest: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Where a browser stands.
    public enum Status: Equatable, Sendable {
        /// No manifest of ours.
        case off
        /// Ours, pointing at this copy of Khayt, letting in every id it should.
        case on
        /// Ours, but for another copy of Khayt (moved, or a second build), or
        /// written before an id was added: Install writes it again.
        case stale
        /// A file of that name Khayt did not write. Never touched.
        case foreign
    }

    /// Whether the file at `url` is one Khayt wrote: the host's name, and a
    /// program called `khayt-browser-host` inside some `Khayt.app`.
    public static func isOurs(_ data: Data) -> Bool {
        guard data.count < 64 * 1_024,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["name"] as? String == hostName, let path = o["path"] as? String else { return false }
        return path.hasSuffix(".app/Contents/MacOS/\(executableName)")
    }

    public static func status(_ browser: Browser, home: URL, hostPath: String, chromiumIds ids: [String]) -> Status {
        let url = manifestURL(browser, home: home)
        guard let data = try? Data(contentsOf: url) else { return .off }
        guard isOurs(data), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .foreign }
        guard o["path"] as? String == hostPath else { return .stale }
        if browser.isChromium {
            let have = Set((o["allowed_origins"] as? [String]) ?? [])
            let want = Set(ids.map { "chrome-extension://\($0)/" })
            return want.isSubset(of: have) ? .on : .stale
        }
        return (o["allowed_extensions"] as? [String]) == [firefoxExtensionId] ? .on : .stale
    }

    public enum Failure: Error, Equatable {
        /// Not one of ours; left alone.
        case foreign
        /// A Chromium browser with no extension id to let in yet.
        case noExtensionId
        case write(String)
    }

    /// Write the manifest for one browser — the shop's click, never Khayt's own idea.
    public static func install(_ browser: Browser, home: URL, hostPath: String,
                               chromiumIds ids: [String]) throws(Failure) {
        let url = manifestURL(browser, home: home)
        if let existing = try? Data(contentsOf: url), !isOurs(existing) { throw .foreign }
        guard let m = manifest(browser, hostPath: hostPath, chromiumIds: ids),
              let data = manifestData(m) else { throw .noExtensionId }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw .write(error.localizedDescription)
        }
    }

    /// Delete the manifest — only the file Khayt wrote, and nothing else in
    /// the folder (not the folder either: the browser owns it).
    public static func remove(_ browser: Browser, home: URL) throws(Failure) {
        let url = manifestURL(browser, home: home)
        guard let data = try? Data(contentsOf: url) else { return }
        guard isOurs(data) else { throw .foreign }
        do { try FileManager.default.removeItem(at: url) } catch { throw .write(error.localizedDescription) }
    }
}
