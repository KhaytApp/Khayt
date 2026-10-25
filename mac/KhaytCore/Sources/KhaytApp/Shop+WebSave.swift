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
    /// The folder a download must be inside to be offered (tests: a temporary one).
    var home: () -> URL = { Shop.webDownloadHome }

    /// The last page filed, for the Settings row.
    private(set) var lastSaved: (title: String, at: Date)?
    /// Saves filed while this app has been open.
    private(set) var savedCount = 0

    func setLastSaved(_ value: (title: String, at: Date)?) { lastSaved = value }

    /// Downloads waiting for the shop's answer, oldest first: the browser's
    /// (an `attach` from the host) and Safari's (`SafariDownloadsWatch`).
    /// The first is the one the window asks about (`WebAttachPrompt`).
    private(set) var offers: [WebAttachOffer] = []
    /// The one being asked about, as the sheet binds it. The sheet setting it
    /// back is ignored: an offer goes only by Not Now or Add to Library
    /// (`dismissOffer`), so a sheet replaced by the next one cannot drop it.
    var offer: WebAttachOffer? {
        get { offers.first }
        set { _ = newValue }
    }
    /// An offer being added right now, and what went wrong with the last one.
    var attaching = false
    var attachProblem: String?
    /// The last download added, for the Settings row: its name and record.
    var lastAttached: (name: String, id: String)?

    /// Put one download to the shop — once per file, however many times the
    /// browser and the watch both noticed it. At most `maxOffers` wait: a
    /// flood of files into Downloads (or of attach messages) cannot stack
    /// questions without end — the rest are simply not asked.
    static let maxOffers = 10

    func enqueue(_ offer: WebAttachOffer) {
        guard !offers.contains(where: { $0.path == offer.path }), offers.count < Self.maxOffers else { return }
        offers.append(offer)
        // The window may be behind the browser: say so on the Dock, once.
        if offers.count == 1, let app = NSApp as NSApplication?, !app.isActive { app.requestUserAttention(.informationalRequest) }
    }

    /// Not Now, or done: the question in front of the shop goes, and the
    /// next one (if any) is asked.
    func dismissOffer() {
        attachProblem = nil
        if !offers.isEmpty { offers.removeFirst() }
    }

    /// Safari's downloads, watched only for a little while after a save.
    @ObservationIgnored lazy var safariDownloads = SafariDownloadsWatch(inbox: self)

    @ObservationIgnored private weak var shop: Shop?
    @ObservationIgnored private var watch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var again = false
    /// Saves were left waiting by the last drain — the staff lock was down,
    /// or no real book was open — so a sign-in or a book opening drains again.
    @ObservationIgnored private(set) var heldBack = false
    /// Saves whose write failed this time, put back for later — not tried
    /// again by the folder event putting them back makes, only once the hold
    /// lifts or the app comes to the front.
    @ObservationIgnored private var retryLater: Set<String> = []

    /// Start reading the inbox for this shop. Called once the book is open.
    func start(shop: Shop) {
        self.shop = shop
        guard let dir = directory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Saves a copy of the app took and never finished filing (it quit or
        // crashed mid-write) wait again.
        WebInbox.recoverClaims(in: dir)
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
                MainActor.assumeIsolated { self?.retryLater = []; self?.drainSoon() }
            }
        }
        drainSoon()
    }

    /// Who is at this Mac, or which book is open, changed: saves held back
    /// for it are tried again.
    func holdMayHaveLifted() {
        guard heldBack else { return }
        retryLater = []
        drainSoon()
    }

    /// A save written this recently may still have its popup waiting for the
    /// answer (`WebInbox.answerWait`); older, nobody is listening.
    static let liveAnswerWindow: TimeInterval = WebInbox.answerWait + 2

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
    ///
    /// A save that cannot be filed YET is left in the inbox, not refused and
    /// deleted: with nobody signed in (or someone who may not edit the
    /// library) it waits for a sign-in, and with no real book open (the
    /// sample) it waits for one — the popup promised it would be added. Only
    /// a save so new its popup is still waiting is answered `refused`, and
    /// then it is done with. A claimed save is let go only once it is
    /// answered for good, so a quit mid-write loses nothing.
    func drain(now: Date = Date()) async {
        guard let shop, let dir = directory() else { return }
        WebInbox.sweepAnswers(inbox: dir)
        heldBack = false
        // A cover is fetched after its save is answered, so a slow picture
        // never makes a filed save look like "Khayt isn't open".
        var covers: [(address: String, id: String)] = []
        for file in WebInbox.pending(in: dir) {
            if retryLater.contains(file.lastPathComponent) { heldBack = true; continue }
            if let hold = shop.webSaveHold {
                heldBack = true
                // The sample: never claimed, so a real book (here later, or
                // another copy of the app) files it.
                if hold == "sample" { continue }
                let made = (try? FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date) ?? .distantPast
                if now.timeIntervalSince(made) > Self.liveAnswerWindow { continue }
            }
            guard let claimed = WebInbox.claim(file) else { continue }
            let fallbackId = file.deletingPathExtension().lastPathComponent
            let result: WebInbox.Result
            var safariSave: WebSave.Page?
            do {
                let entry = try WebSave.entry(fromInboxFile: claimed.data)
                if entry.kind == .attach {
                    let (answer, offer) = shop.offerWebAttach(entry, accepting: accepting, home: home())
                    result = answer
                    if let offer { enqueue(offer) }
                } else {
                    let filed = await shop.fileWebSaveRecord(entry, accepting: accepting)
                    result = filed.result
                    if let cover = filed.cover { covers.append(cover) }
                    if entry.browser == "safari" { safariSave = entry.page }
                }
            } catch {
                result = WebInbox.Result(id: fallbackId, state: .invalid, reason: error.rawValue)
            }
            // A write that failed may work next time: it waits again.
            if result.state == .refused, result.reason == "write" {
                WebInbox.putBack(claimed)
                retryLater.insert(file.lastPathComponent)
                heldBack = true
                continue
            }
            try? WebInbox.answer(result, inbox: dir)
            WebInbox.finish(claimed)
            if result.state == .saved || result.state == .updated {
                lastSaved = (result.title ?? "", Date())
                savedCount += 1
                // Safari cannot say what it downloads: for a while after a
                // Safari save, the app looks in ~/Downloads itself.
                if let page = safariSave, let id = WebSaveRecord.existing(page, in: shop.libraryRows) {
                    safariDownloads.watch(recordId: id, title: page.title, site: page.site)
                }
            }
        }
        for cover in covers { await shop.addWebCover(cover.address, to: cover.id) }
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
        let filed = await fileWebSaveRecord(entry, accepting: accepting)
        if let cover = filed.cover { await addWebCover(cover.address, to: cover.id) }
        return filed.result
    }

    /// Why a save cannot be filed right now, though it may be later: `not-allowed`
    /// (the staff lock), `sample` (no real book). Nil when it can.
    var webSaveHold: String? {
        if !lockAllows("inventory", "edit") { return "not-allowed" }
        if source.build == nil { return "sample" }
        return nil
    }

    /// The record written, and the cover still to fetch for it — fetched by
    /// the caller AFTER the answer has gone back (`WebSaveInbox.drain`).
    func fileWebSaveRecord(_ entry: WebSave.Entry,
                           accepting: Bool) async -> (result: WebInbox.Result, cover: (address: String, id: String)?) {
        guard accepting else { return (.init(id: entry.id, state: .refused, reason: "off"), nil) }
        guard entry.kind == .save, let page = entry.page else {
            // A download to attach is `offerWebAttach`'s, and is never filed
            // without the shop's answer.
            return (.init(id: entry.id, state: .refused, reason: "unsupported"), nil)
        }
        guard lockAllows("inventory", "edit") else {
            return (.init(id: entry.id, state: .refused, reason: "not-allowed"), nil)
        }
        guard let build = source.build else { return (.init(id: entry.id, state: .refused, reason: "sample"), nil) }
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
            return (.init(id: entry.id, state: .refused, reason: "write"), nil)
        }
        await load(source)
        let cover = outcome.wantsCover ? page.cover.map { (address: $0, id: outcome.id) } : nil
        return (.init(id: entry.id, state: outcome.created ? .saved : .updated, title: page.title), cover)
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
        guard let checked = WebSave.https(address), let url = URL(string: checked), let host = url.host else { return nil }
        // Never a machine on the shop's own network: the browser keeps a page
        // from reaching those, and this fetch is the page's choice of address.
        guard await PinWork.run({ WebCoverFetch.isPublic(host: host) }) else { return nil }
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

    /// The picture formats a cover may be. A stranger's bytes reach ImageIO
    /// here, in the main app: only the formats a web page's picture really
    /// is get a decoder — never TIFF, RAW, PSD, EXR, ICNS, JPEG XL or the
    /// rest ImageIO would otherwise guess its way into.
    nonisolated static let coverTypes: Set<String> = ["public.jpeg", "public.png", "org.webmproject.webp",
                                                      "com.compuserve.gif"]
    /// The largest cover, in pixels a side and in all.
    nonisolated static let coverMaxSide = 12_000
    nonisolated static let coverMaxPixels = 64_000_000

    /// The bytes as a library photo, or nil when they are not a picture.
    nonisolated static func coverURI(_ data: Data) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String?, coverTypes.contains(type),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0, w <= coverMaxSide, h <= coverMaxSide, w * h <= coverMaxPixels else { return nil }
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

    /// A host on the internet: not a `.local` or `localhost` name, and every
    /// address it resolves to outside loopback, the private ranges, link-
    /// local, CGNAT and the unique-local IPv6 block. A name that does not
    /// resolve is not fetched either.
    nonisolated static func isPublic(host raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return false }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        var any = false
        while let n = node {
            defer { node = n.pointee.ai_next }
            guard let addr = n.pointee.ai_addr else { continue }
            any = true
            if addr.pointee.sa_family == sa_family_t(AF_INET) {
                let v4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                if !isPublic(v4: [UInt8](withUnsafeBytes(of: v4) { Array($0) })) { return false }
            } else if addr.pointee.sa_family == sa_family_t(AF_INET6) {
                let v6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if !isPublic(v6: withUnsafeBytes(of: v6) { Array($0) }) { return false }
            }
        }
        return any
    }

    /// An IPv4 address, in network order, that is on the internet.
    nonisolated static func isPublic(v4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return false
        case (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false
        case (224...255, _): return false
        default: return true
        }
    }

    /// An IPv6 address that is on the internet (a mapped IPv4 one is asked
    /// as IPv4).
    nonisolated static func isPublic(v6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isPublic(v4: Array(b[12..<16])) }
        if b[0] & 0xFE == 0xFC { return false }             // fc00::/7 unique local
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false } // fe80::/10 link-local
        if b[0] == 0xFF { return false }                    // multicast
        return true
    }

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
            guard request.url?.scheme?.lowercased() == "https", let host = request.url?.host else { return nil }
            return await PinWork.run { WebCoverFetch.isPublic(host: host) } ? request : nil
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
