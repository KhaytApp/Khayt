import AppKit
import Foundation
import KhaytCore

/// Help ▸ Send Feedback…: a tester's report, with enough attached to reproduce
/// what they saw.
///
/// ── WHAT GOES, AND WHAT NEVER DOES ─────────────────────────────────────────
///
/// A report is an EMAIL the person sends themselves, from their own mail app.
/// Nothing leaves this Mac on its own: `compose` opens a draft and stops, and
/// there is no server endpoint behind this at all.
///
///   diagnostics.txt  versions, the Mac, the language, the window size, and the
///                    book as COUNTS — how many jobs, customers, machines,
///                    spools and library files — plus three on/off switches
///                    (cloud sync, Google Drive, the LAN server) and the rules
///                    that failed lately, by name. Never a name, a number from
///                    the books, or a setting's value. `diagnostics(_:)` is
///                    handed `Facts`, which has nowhere to put one.
///   window.png       the window, drawn by the app itself — no Screen
///                    Recording permission, and nothing else on the screen.
///   book.json        only when ticked. The book as it is stored, through the
///                    SAME mask the cloud push uses (`storeForCloud`): every
///                    path in `lib/store-secret-paths.js`, the device-private
///                    ones, and anything sealed on disk — and THEN through the
///                    export redaction (`redactedExport`, `lib/store.js`),
///                    which the cloud mask does not do: it deletes every
///                    order's `trackingToken` and `quoteApprovalToken` (live
///                    capabilities — the portal link, and approving a quote)
///                    and masks the LAN API token hashes. A second, Swift-side
///                    list of what is secret is how two lists drift, so the
///                    only Swift-side additions are the few in `forFeedback`
///                    that neither lib rule covers yet.
enum Feedback {

    static let address = "support@khaytapp.com"

    /// The subject line. Version AND build: two alpha builds can carry the
    /// same marketing version, and "which one" is the first question asked.
    static func subject(version: String, build: String) -> String {
        "Khayt for Mac feedback — \(version) (\(build))"
    }

    /// This app's version and build, as the bundle says them.
    static func appVersion(_ bundle: Bundle = .main) -> (version: String, build: String) {
        let info = bundle.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "development build"
        let build = (info["CFBundleVersion"] as? String) ?? "0"
        return (version, build)
    }

    // MARK: - The window, as the app draws it

    /// A picture of the window, and how big it was.
    struct Capture {
        let png: Data?
        let size: CGSize
    }

    /// Draw the window into a bitmap through its own views.
    ///
    /// `cacheDisplay(in:to:)` asks the views to draw themselves, so it needs
    /// no Screen Recording grant and cannot catch another app's window or a
    /// notification sliding over it. The frame view (the content view's
    /// superview) rather than the content view, so the toolbar is in it.
    @MainActor static func capture(_ window: NSWindow?) -> Capture? {
        guard let window else { return nil }
        let size = window.frame.size
        guard let view = window.contentView?.superview ?? window.contentView,
              view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return Capture(png: nil, size: size)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return Capture(png: rep.representation(using: .png, properties: [:]), size: size)
    }

    /// The window a report is about: the one in front that is not itself a
    /// sheet or a panel.
    @MainActor static func frontWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            + NSApp.orderedWindows
        return candidates.first { window in
            window.isVisible && window.sheetParent == nil && !(window is NSPanel)
        }
    }

    // MARK: - Diagnostics

    /// Everything diagnostics.txt may say. Counts and switches — there is no
    /// field here a customer's name or a price could be put in.
    struct Facts {
        var version: String
        var build: String
        var macOS: String
        var model: String
        var language: String
        var locale: String
        var region: String
        var windowSize: CGSize?
        var sample: Bool
        var jobs: Int
        var clients: Int
        var machines: Int
        var spools: Int
        var libraryFiles: Int
        var cloudSync: Bool
        var drive: Bool
        var lanServer: Bool
        var faults: [EngineFaults.Fault]
    }

    @MainActor static func facts(for shop: Shop, windowSize: CGSize?) -> Facts {
        let (version, build) = appVersion()
        return Facts(
            version: version, build: build,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            model: macModel(),
            language: shop.words.language,
            locale: Locale.current.identifier,
            region: Locale.current.region?.identifier ?? "",
            windowSize: windowSize,
            sample: shop.source.build == nil,
            jobs: shop.orders.count, clients: shop.clients.count,
            machines: shop.machines.count, spools: shop.spools.count,
            libraryFiles: shop.files.count,
            cloudSync: shop.cloudConnected,
            drive: CloudLibrary.driveConnected(shop.settingsDict),
            lanServer: shop.lanServer?.running == true,
            faults: EngineFaults.recent())
    }

    /// `hw.model` — "Mac15,3" and the like.
    static func macModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The file. English on purpose: it is read by whoever answers the email,
    /// not shown on a screen.
    static func diagnostics(_ facts: Facts, now: Date = Date()) -> String {
        let clock = ISO8601DateFormatter()
        let yes = { (on: Bool) in on ? "on" : "off" }
        var lines = [
            "Khayt for Mac — diagnostics",
            "written: \(clock.string(from: now))",
            "",
            "version: \(facts.version)",
            "build: \(facts.build)",
            "macOS: \(facts.macOS)",
            "Mac model: \(facts.model)",
            "language: \(facts.language)",
            "locale: \(facts.locale)",
            "region: \(facts.region)",
            "window: " + (facts.windowSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "(none)"),
            "",
            "book: " + (facts.sample ? "sample" : "own"),
            "jobs: \(facts.jobs)",
            "customers: \(facts.clients)",
            "machines: \(facts.machines)",
            "spools: \(facts.spools)",
            "library files: \(facts.libraryFiles)",
            "",
            "cloud sync: \(yes(facts.cloudSync))",
            "Google Drive: \(yes(facts.drive))",
            "LAN server: \(yes(facts.lanServer))",
            "",
            "rules that failed lately (oldest first):",
        ]
        if facts.faults.isEmpty {
            lines.append("(none)")
        } else {
            for fault in facts.faults {
                lines.append("\(clock.string(from: fault.at))  \(fault.call)  —  \(scrubbed(fault.problem))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A fault's message reduced to its KIND — "TypeError", "RangeError" —
    /// and nothing of what followed.
    ///
    /// `EngineFaults` already strips a call's arguments, and the rule that
    /// failed is named by `fault.call` beside this. The message is the
    /// problem: JavaScriptCore's own can quote the expression it was
    /// evaluating, and an engine script carries its data INLINE; and a lib
    /// rule's `throw new Error(`no price for ${name}`)` puts a customer in it
    /// with no quotes at all. Taking quotes out (the first version of this)
    /// caught the first and not the second. So only the text before the first
    /// ':' is kept, and only when it looks like an error's name — anything
    /// else, including a message with no ':' at all, is withheld whole.
    static func scrubbed(_ problem: String) -> String {
        guard let colon = problem.firstIndex(of: ":") else { return withheld }
        let kind = problem[..<colon].trimmingCharacters(in: .whitespaces)
        let nameish = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.$")
        guard !kind.isEmpty, kind.count <= 60,
              kind.unicodeScalars.allSatisfy(nameish.contains) else { return withheld }
        return kind
    }

    static let withheld = "(message withheld)"

    // MARK: - The book, masked

    /// The book exactly as this app stores it, with every secret masked the
    /// way the cloud push masks it AND redacted the way an export is. Nil when
    /// there is no engine to mask with, or either rule fails: an unmasked book
    /// is never the fallback.
    ///
    /// Both, because neither is a superset of the other. The cloud mask
    /// (`lib/cloud-outbox.js forCloud`) keeps every order's tokens — the cloud
    /// copy needs them, it is the shop's own — and the export redaction
    /// (`lib/store.js buildExportPayload`) knows nothing of device-private
    /// values or of anything sealed but unlisted. A feedback report is a file
    /// emailed to a stranger, so it gets the union.
    static func maskedBook(_ root: [String: JSONValue], engine: KhaytEngine?) async -> Data? {
        guard let engine,
              let masked = try? await engine.storeForCloud(root),
              let exported = try? await engine.redactedExport(masked) else { return nil }
        return try? JSONEncoder().encode(forFeedback(exported))
    }

    /// What NEITHER lib rule takes out yet, taken out of the feedback copy
    /// only. Kept short on purpose (see the note at the top) and reported to
    /// the shared lib — once `lib/store.js` covers these, this goes.
    ///
    ///   printLog[].surveyToken     the key a customer's survey answer is
    ///                              accepted with (LanServer); deleted, not
    ///                              masked, for the reason `redactOrdersForExport`
    ///                              gives — a mask would be adopted as a token
    ///   settings.cloud.keyset      the shop's wrapped data key: sealed with the
    ///                              passphrase, so offline-crackable, and a
    ///                              report has no use for it
    static func forFeedback(_ root: [String: JSONValue]) -> [String: JSONValue] {
        var out = root
        if case .array(let jobs)? = out["printLog"] {
            out["printLog"] = .array(jobs.map { job in
                guard case .object(var o) = job, o["surveyToken"] != nil else { return job }
                o.removeValue(forKey: "surveyToken")
                return .object(o)
            })
        }
        if case .object(var settings)? = out["settings"] {
            if case .object(var cloud)? = settings["cloud"], cloud["keyset"] != nil {
                cloud.removeValue(forKey: "keyset")
                settings["cloud"] = .object(cloud)
            }
            out["settings"] = .object(settings)
        }
        return out
    }

    /// The book as it is on disk, secrets still sealed — or the sample.
    @MainActor static func storedBook(_ shop: Shop) throws -> [String: JSONValue] {
        switch shop.source {
        case .store(let build):
            return try StoreReader(build: build).raw
        case .sample:
            guard let url = AppResources.bundle.url(forResource: "sample-shop", withExtension: "json") else {
                return [:]
            }
            let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
            return SampleBook.rebased(root, to: Date())
        }
    }

    // MARK: - Sending

    /// The attachments, by file name.
    struct Parts {
        var message: String
        var diagnostics: String
        var screenshot: Data?
        var book: Data?

        var files: [(name: String, data: Data)] {
            var out: [(String, Data)] = [("diagnostics.txt", Data(diagnostics.utf8))]
            if let screenshot { out.append(("window.png", screenshot)) }
            if let book { out.append(("book.json", book)) }
            return out
        }
    }

    /// What happened when it was handed over.
    enum Outcome: Equatable {
        /// A draft is open in the mail app. Nothing has been sent.
        case composed
        /// No mail app: a zip is in Downloads, shown in Finder, and the address
        /// is on the clipboard.
        case saved(URL)
        case failed(String)
    }

    /// Kept alive while the mail app has the draft — a sharing service's
    /// delegate is weak.
    @MainActor private static var watcher: Watcher?

    /// Open a draft in the mail app, or — when there is none — leave a zip.
    @MainActor static func compose(_ parts: Parts, subject: String,
                                   fellBack: @escaping @MainActor (Outcome) -> Void) -> Outcome {
        sweepOldDrafts()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Khayt-feedback-\(stamp())", directoryHint: .isDirectory)
        var urls: [URL] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in parts.files {
                let url = folder.appending(path: file.name)
                try file.data.write(to: url)
                urls.append(url)
            }
        } catch {
            return .failed(String(describing: error))
        }

        let items: [Any] = [parts.message as NSString] + urls.map { $0 as NSURL }
        guard let service = NSSharingService(named: .composeEmail),
              service.canPerform(withItems: items) else {
            return saveInstead(parts)
        }
        service.recipients = [address]
        service.subject = subject
        let watcher = Watcher { fellBack(saveInstead(parts)) }
        Self.watcher = watcher
        service.delegate = watcher
        service.perform(withItems: items)
        return .composed
    }

    /// No mail app: the same files and the message in a zip in Downloads,
    /// shown in Finder, with the address on the clipboard.
    @MainActor static func saveInstead(_ parts: Parts) -> Outcome {
        do {
            let url = try writeZip(parts, into: downloads())
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .saved(url)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Remove the folders earlier reports left in the temporary directory.
    ///
    /// Each holds a masked book and a picture of the window, and cannot be
    /// removed right after `compose`: the mail app reads the attachments from
    /// there, possibly minutes later. So they are swept the next time — at
    /// launch and before a new report — once they are a day old, which no
    /// draft still needs. Only this app's own `Khayt-feedback-*` folders, and
    /// only folders.
    static func sweepOldDrafts(in folder: URL = FileManager.default.temporaryDirectory,
                               olderThan age: TimeInterval = 24 * 60 * 60, now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                        options: [.skipsSubdirectoryDescendants]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("Khayt-feedback-") {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// The zip itself, where it is asked for. Separate so a test can open one.
    static func writeZip(_ parts: Parts, into folder: URL) throws -> URL {
        var members = [ZipWrite.Member("what-happened.txt", Data(parts.message.utf8))]
        members += parts.files.map { ZipWrite.Member($0.name, $0.data) }
        let url = folder.appending(path: "Khayt-feedback-\(stamp()).zip")
        try ZipWrite.archive(members).write(to: url, options: .atomic)
        return url
    }

    static func downloads() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        return format.string(from: Date())
    }

    /// Hears the mail app refuse the draft, and falls back.
    private final class Watcher: NSObject, NSSharingServiceDelegate {
        let failed: @MainActor () -> Void
        init(_ failed: @escaping @MainActor () -> Void) { self.failed = failed }

        func sharingService(_ sharingService: NSSharingService,
                            didFailToShareItems items: [Any], error: any Error) {
            // Cancelling the draft is reported as a failure too; that is the
            // person deciding not to send, not a missing mail app.
            if (error as NSError).code == NSUserCancelledError { return }
            MainActor.assumeIsolated { failed() }
        }
    }
}

extension Shop {
    /// Help ▸ Send Feedback…, and the right-click on a fault notice.
    ///
    /// The picture is taken HERE, before the sheet opens, so it shows the
    /// screen the problem was on rather than the sheet asking about it.
    func askForFeedback() {
        feedbackCapture = Feedback.capture(Feedback.frontWindow())
        sendingFeedback = true
    }
}
