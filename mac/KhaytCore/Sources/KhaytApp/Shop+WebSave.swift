import AppKit
import Foundation
import ImageIO
import KhaytCore
import KhaytWebSave

/// ── SAVE TO KHAYT: THE APP'S END ─────────────────────────────────────────
///
/// The browser extension's saves arrive as files in the app group's inbox
/// (`WebInbox`, written by `KhaytSafari.appex` or the browser host). This
/// watches that folder while the app is open, and files each save into the
/// book as a library record (`WebSaveRecord`) — one write on the write chain,
/// asked of the staff lock like any change to the library — then answers it,
/// so the popup can say what happened.
///
/// EVERY FILE IS UNTRUSTED. It is read with a size cap and checked again by
/// `WebSave` — the same rules the extension's end applied — before a field of
/// it is used. Nothing in it is opened or run. The one thing fetched is the
/// cover picture: over https only, redirects included, at most 8 MB, kept only
/// if it decodes as a picture, and stored the way a shop's own photo is
/// (`LibraryPhoto`, a 480 px JPEG in the record).
@MainActor @Observable
final class WebSaveInbox {
    static let shared = WebSaveInbox()

    /// Whether this Mac takes saves from the browser at all. On by default —
    /// the extension does nothing until the shop installs it and presses its
    /// button — and a switch in Settings, Mac-local like the menu bar's.
    static let acceptKey = "mac.webSaveAccept"
    var accepting: Bool {
        get { access(keyPath: \.accepting); return UserDefaults.standard.object(forKey: Self.acceptKey) as? Bool ?? true }
        set { withMutation(keyPath: \.accepting) { UserDefaults.standard.set(newValue, forKey: Self.acceptKey) } }
    }

    /// The inbox, or nil for a build with no app group (ad hoc).
    var directory: () -> URL? = { WebInbox.directory() }
    var available: Bool { directory() != nil }

    /// The last page filed, for the Settings row.
    private(set) var lastSaved: (title: String, at: Date)?
    /// Saves filed while this app has been open.
    private(set) var savedCount = 0

    func setLastSaved(_ value: (title: String, at: Date)?) { lastSaved = value }

    @ObservationIgnored private weak var shop: Shop?
    @ObservationIgnored private var watch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var again = false

    /// Start reading the inbox for this shop. Called once the book is open.
    func start(shop: Shop) {
        self.shop = shop
        guard let dir = directory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if watch == nil {
            let fd = open(dir.path, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename],
                                                                       queue: .main)
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.drainSoon() }
                }
                source.setCancelHandler { close(fd) }
                source.resume()
                watch = source
            }
            // A folder event can be missed (the app asleep, the folder made
            // after the watch); coming to the front looks again.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.drainSoon() }
            }
        }
        drainSoon()
    }

    func drainSoon() {
        guard !draining else { again = true; return }
        draining = true
        Task { @MainActor in
            repeat {
                again = false
                await drain()
            } while again
            draining = false
        }
    }

    /// Every waiting save, filed and answered in the order they came.
    func drain() async {
        guard let shop, let dir = directory() else { return }
        WebInbox.sweepAnswers(inbox: dir)
        for file in WebInbox.pending(in: dir) {
            guard let data = WebInbox.claim(file) else { continue }
            let fallbackId = file.deletingPathExtension().lastPathComponent
            let result: WebInbox.Result
            do {
                let entry = try WebSave.entry(fromInboxFile: data)
                result = await shop.fileWebSave(entry, accepting: accepting)
            } catch {
                result = WebInbox.Result(id: fallbackId, state: .invalid, reason: error.rawValue)
            }
            try? WebInbox.answer(result, inbox: dir)
            if result.state == .saved || result.state == .updated {
                lastSaved = (result.title ?? "", Date())
                savedCount += 1
            }
        }
    }
}

extension Shop {

    /// One save, filed — or the reason it was not. The answer goes back to
    /// the popup through the inbox.
    ///
    /// Refused, in this order: saving from the browser switched off on this
    /// Mac; the staff lock, asked the way every library edit asks it; and the
    /// sample book open (there is nothing to write to). Asked with
    /// `lockAllows` rather than `permitted`, because nobody at the Mac pressed
    /// anything here — a refusal goes back to the browser, not into an alert.
    func fileWebSave(_ entry: WebSave.Entry, accepting: Bool) async -> WebInbox.Result {
        guard accepting else { return .init(id: entry.id, state: .refused, reason: "off") }
        guard entry.kind == .save, let page = entry.page else {
            // A download to attach is the browser host's, in the next part
            // of this feature; until then it is said rather than dropped.
            return .init(id: entry.id, state: .refused, reason: "unsupported")
        }
        guard lockAllows("inventory", "edit") else {
            return .init(id: entry.id, state: .refused, reason: "not-allowed")
        }
        guard let build = source.build else { return .init(id: entry.id, state: .refused, reason: "sample") }
        let newId = Self.uid("PF")
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1000, nowISO = StoreWriter.iso(now)
        let outcome: WebSaveRecord.Outcome
        do {
            // Worked out INSIDE the write chain, against the book as it is on
            // disk: two saves of one page a moment apart are one record.
            outcome = try await StoreWriter.updateOffMain(build) { root in
                var rows = Self.rows(root, "printFiles")
                let outcome = WebSaveRecord.apply(page, to: &rows, newId: newId, nowMs: nowMs, nowISO: nowISO)
                root["printFiles"] = .array(rows)
                return outcome
            }
        } catch {
            writeProblem = said(error)
            return .init(id: entry.id, state: .refused, reason: "write")
        }
        await load(source)
        if outcome.wantsCover, let cover = page.cover {
            await addWebCover(cover, to: outcome.id)
        }
        return .init(id: entry.id, state: outcome.created ? .saved : .updated, title: page.title)
    }

    /// The page's cover, as the record's picture — unless it has one by the
    /// time the picture arrives. Failing to fetch it costs the record nothing.
    func addWebCover(_ address: String, to id: String) async {
        guard let build = source.build, lockAllows("inventory", "edit") else { return }
        guard let uri = await Self.fetchWebCover(address) else { return }
        do {
            let wrote = try await StoreWriter.updateOffMain(build) { root -> Bool in
                var rows = Self.rows(root, "printFiles")
                guard WebSaveRecord.setCover(uri, id: id, in: &rows) else { return false }
                root["printFiles"] = .array(rows)
                return true
            }
            if wrote { await load(source) }
        } catch {
            // The record stands without its picture; the next save tries again.
        }
    }

    /// Fetch a cover picture: https only (a redirect elsewhere is refused),
    /// no cookies, at most `ProductPhotos.maxSourceBytes`, and only a body
    /// the picture decoder accepts — then made into the 480 px JPEG data URI
    /// a library photo is. Nil for anything else.
    nonisolated static func fetchWebCover(_ address: String,
                                          session: URLSession = WebCoverFetch.session) async -> String? {
        guard let checked = WebSave.https(address), let url = URL(string: checked) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let cap = ProductPhotos.maxSourceBytes
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              (http.mimeType ?? "").lowercased().hasPrefix("image/"),
              http.expectedContentLength <= Int64(cap) else { return nil }
        var data = Data()
        data.reserveCapacity(min(Int(max(http.expectedContentLength, 0)), cap))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > cap { return nil }
            }
        } catch { return nil }
        let body = data
        return await PinWork.run { Self.coverURI(body) }
    }

    /// The bytes as a library photo, or nil when they are not a picture.
    nonisolated static func coverURI(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else { return nil }
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "khayt-web-cover-scratch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) } // scratch
        guard (try? data.write(to: scratch)) != nil else { return nil }
        return try? LibraryPhoto.dataURI(of: scratch)
    }

    /// Open a saved model's page in the browser — the shop's own click, on
    /// an address that was https when it was saved and is checked again now.
    func openWebSource(_ file: LibraryFile) {
        guard let raw = file.sourceUrl, let checked = WebSave.https(raw), let url = URL(string: checked) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The session covers are fetched with: no cookies, no cache, no credentials,
/// and a redirect followed only to another https address.
enum WebCoverFetch {
    nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: HttpsOnly(), delegateQueue: nil)
    }()

    final class HttpsOnly: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme?.lowercased() == "https" ? request : nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            // A server's own certificate is checked as always; a request for a
            // password is never answered.
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
        }
    }
}
