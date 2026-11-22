import Foundation
import Testing
import KhaytCore
import KhaytWebSave

/// "Save to Khayt" for Chrome, Edge, Brave, Vivaldi and Firefox: the native-
/// messaging framing the browser host speaks, the one reply path it shares
/// with Safari, the host manifests Settings writes — into a TEMPORARY home
/// folder, never a real browser profile — and what a download becomes.
@Suite("Save to Khayt — the browser host")
struct WebSaveHostTests {

    static func temp(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ws-host-\(name)-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stream of bytes, handed out `chunk` at a time, as a pipe does.
    final class Stream: @unchecked Sendable {
        var data: Data
        let chunk: Int
        init(_ data: Data, chunk: Int = 3) { self.data = data; self.chunk = chunk }
        func read(_ n: Int) -> Data {
            let take = data.prefix(min(n, chunk))
            data.removeFirst(take.count)
            return Data(take)
        }
    }

    static func framed(_ body: Data) -> Data {
        let n = UInt32(body.count)
        return Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]) + body
    }

    // MARK: - Framing

    @Test("a message is a little-endian length and JSON, read whole however the pipe hands it over")
    func framing() throws {
        let body = Data(#"{"v":1,"kind":"ping"}"#.utf8)
        let s = Stream(Self.framed(body) + Self.framed(Data("{}".utf8)), chunk: 2)
        #expect(try NativeMessaging.readMessage(s.read) == body)
        #expect(try NativeMessaging.readMessage(s.read) == Data("{}".utf8), "the next message follows")
        #expect(throws: NativeMessaging.ReadError.closed) { try NativeMessaging.readMessage(s.read) }

        let reply = NativeMessaging.frame(["ok": true, "state": "ready"])
        #expect(Array(reply.prefix(4)) == [UInt8(reply.count - 4), 0, 0, 0])
        let decoded = try JSONSerialization.jsonObject(with: reply.dropFirst(4)) as? [String: Any]
        #expect(decoded?["state"] as? String == "ready")
    }

    @Test("caps: a zero or over-1 MB length is not read at all, a short body is truncated, a huge reply is refused")
    func caps() {
        let over = UInt32(NativeMessaging.maxIncoming + 1)
        let lie = Data([UInt8(over & 0xFF), UInt8(over >> 8 & 0xFF), UInt8(over >> 16 & 0xFF), UInt8(over >> 24 & 0xFF)])
        let s = Stream(lie + Data(repeating: 0x20, count: 64))
        #expect(throws: NativeMessaging.ReadError.badLength(over)) { try NativeMessaging.readMessage(s.read) }
        #expect(s.data.count == 64, "nothing past the length was read")
        #expect(throws: NativeMessaging.ReadError.badLength(0)) {
            try NativeMessaging.readMessage(Stream(Data([0, 0, 0, 0])).read)
        }
        #expect(throws: NativeMessaging.ReadError.truncated) {
            try NativeMessaging.readMessage(Stream(Self.framed(Data("{\"v\":1}".utf8)).dropLast(2)).read)
        }
        #expect(throws: NativeMessaging.ReadError.truncated) { try NativeMessaging.readMessage(Stream(Data([5, 0])).read) }
        // Exactly 1 MB is let through to `WebSave`, which then refuses it as too large.
        let big = Data(repeating: 0x20, count: NativeMessaging.maxIncoming)
        #expect((try? NativeMessaging.readMessage(Stream(Self.framed(big), chunk: 65_536).read))?.count == big.count)

        let huge = NativeMessaging.frame(["state": String(repeating: "x", count: NativeMessaging.maxReply)])
        let said = try? JSONSerialization.jsonObject(with: huge.dropFirst(4)) as? [String: Any]
        #expect(said?["state"] as? String == "invalid" && said?["reason"] as? String == "reply")
        #expect(huge.count < 100)
    }

    @Test("which browser: Chromium's origin and its parent's path, Firefox's arguments")
    func whichBrowser() {
        let origin = ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]
        #expect(NativeMessaging.browser(arguments: origin, parentPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") == "chrome")
        #expect(NativeMessaging.browser(arguments: origin, parentPath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge") == "edge")
        #expect(NativeMessaging.browser(arguments: origin, parentPath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser") == "brave")
        #expect(NativeMessaging.browser(arguments: origin, parentPath: "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi") == "vivaldi")
        #expect(NativeMessaging.browser(arguments: origin, parentPath: "/Applications/Chromium.app/Contents/MacOS/Chromium") == "chromium")
        #expect(NativeMessaging.browser(arguments: ["/x/app.khayt.mac.json", "save@khaytapp.com"], parentPath: "") == "firefox")
        #expect(NativeMessaging.browser(arguments: [], parentPath: "/bin/zsh") == "browser")
    }

    // MARK: - One reply, for Safari and the host

    @Test("ping, save, attach and nonsense: one answer path, the inbox written only for a message that passes")
    func reply() throws {
        let inbox = try Self.temp("inbox")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let ping = WebInbox.reply(toMessageData: Data(#"{"v":1,"kind":"ping"}"#.utf8), browser: "chrome",
                                  inbox: inbox, appRunning: false)
        #expect(ping["state"] as? String == "ready" && ping["ok"] as? Bool == true)
        let noGroup = WebInbox.reply(toMessageData: Data(#"{"v":1,"kind":"ping"}"#.utf8), browser: "chrome",
                                     inbox: nil, appRunning: true)
        #expect(noGroup["state"] as? String == "no-inbox")

        let save = try JSONSerialization.data(withJSONObject: [
            "v": 1, "kind": "save", "page": ["url": "https://www.printables.com/model/1-x", "title": "X"]])
        let queued = WebInbox.reply(toMessageData: save, browser: "edge", inbox: inbox, appRunning: false, wait: 0)
        #expect(queued["state"] as? String == "queued")
        let files = WebInbox.pending(in: inbox)
        #expect(files.count == 1)
        let entry = try WebSave.entry(fromInboxFile: Data(contentsOf: try #require(files.first)))
        #expect(entry.browser == "edge" && entry.kind == .save && entry.page?.title == "X")

        let attach = try JSONSerialization.data(withJSONObject: [
            "v": 1, "kind": "attach",
            "attach": ["page": "https://www.printables.com/model/1-x", "path": "/Users/s/Downloads/x.3mf", "name": "x.3mf"]])
        #expect(WebInbox.reply(toMessageData: attach, browser: "firefox", inbox: inbox, appRunning: false, wait: 0)["state"]
                as? String == "queued")
        #expect(WebInbox.pending(in: inbox).count == 2)

        for bad in [Data("not json".utf8), Data(#"{"v":2,"kind":"save"}"#.utf8),
                    Data(#"{"v":1,"kind":"attach","attach":{"page":"https://a.b/","path":"/etc/passwd"}}"#.utf8)] {
            let said = WebInbox.reply(toMessageData: bad, browser: "chrome", inbox: inbox, appRunning: false, wait: 0)
            #expect(said["state"] as? String == "invalid")
        }
        #expect(WebInbox.reply(toMessageData: nil, browser: "chrome", inbox: inbox, appRunning: false)["state"] as? String == "invalid")
        #expect(WebInbox.pending(in: inbox).count == 2, "nothing refused was written")
    }

    @Test("the app's answer, when it comes in time, is the reply")
    func answered() throws {
        let inbox = try Self.temp("answered")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let save = try JSONSerialization.data(withJSONObject: [
            "v": 1, "kind": "save", "page": ["url": "https://makerworld.com/en/models/5", "title": "Bin"]])
        // The app's end, answering whatever arrives.
        let stop = Date().addingTimeInterval(5)
        let app = Thread {
            while Date() < stop {
                if let file = WebInbox.pending(in: inbox).first, let claimed = WebInbox.claim(file),
                   let e = try? WebSave.entry(fromInboxFile: claimed.data) {
                    WebInbox.finish(claimed)
                    try? WebInbox.answer(.init(id: e.id, state: .saved, title: "Bin"), inbox: inbox)
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        app.start()
        let said = WebInbox.reply(toMessageData: save, browser: "chrome", inbox: inbox, appRunning: true, wait: 4)
        #expect(said["state"] as? String == "saved" && said["title"] as? String == "Bin")
        #expect(WebInbox.Result(id: "x", state: .offered).message["ok"] as? Bool == true)
    }

    @Test("the Safari handler answers through the shared path, not a copy of it")
    func safariSharesThePath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let handler = try String(contentsOf: root.appending(path: "Sources/KhaytSafari/SafariWebExtensionHandler.swift"), encoding: .utf8)
        let host = try String(contentsOf: root.appending(path: "Sources/KhaytBrowserHost/main.swift"), encoding: .utf8)
        for source in [handler, host] {
            #expect(source.contains("WebInbox.reply(toMessageData:"))
            #expect(!source.contains("WebInbox.write("), "written only by the shared path")
            for forbidden in ["URLSession", "khayt-store", "NSWorkspace.shared.open", "Process("] {
                #expect(!source.contains(forbidden), "no \(forbidden) in the browser's end")
            }
        }
        // The throwaway inbox is a DEBUG build's only.
        let debugOnly = try #require(host.range(of: "#if DEBUG")).lowerBound
        let override = try #require(host.range(of: "KHAYT_WEBINBOX_DIR")).lowerBound
        let endif = try #require(host.range(of: "#endif")).lowerBound
        #expect(debugOnly < override && override < endif)
    }

    // MARK: - The host manifests

    @Test("Firefox: Install writes the manifest Khayt's host needs, and Remove deletes that one file")
    func firefoxManifest() throws {
        let home = try Self.temp("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let host = "/Applications/Khayt.app/Contents/MacOS/khayt-browser-host"
        #expect(BrowserHosts.status(.firefox, home: home, hostPath: host, chromiumIds: []) == .off)
        try BrowserHosts.install(.firefox, home: home, hostPath: host, chromiumIds: [])
        let url = BrowserHosts.manifestURL(.firefox, home: home)
        #expect(url.path.hasSuffix("/Library/Application Support/Mozilla/NativeMessagingHosts/app.khayt.mac.json"))
        let m = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(m["name"] as? String == "app.khayt.mac")
        #expect(m["path"] as? String == host)
        #expect(m["type"] as? String == "stdio")
        #expect(m["allowed_extensions"] as? [String] == ["save@khaytapp.com"])
        #expect(m["allowed_origins"] == nil)
        #expect(BrowserHosts.status(.firefox, home: home, hostPath: host, chromiumIds: []) == .on)
        // Another copy of Khayt (moved, a dev build): Update.
        #expect(BrowserHosts.status(.firefox, home: home, hostPath: "/Users/x/Khayt.app/Contents/MacOS/khayt-browser-host",
                                    chromiumIds: []) == .stale)

        // Something else in the folder is never touched.
        let neighbour = url.deletingLastPathComponent().appending(path: "org.other.host.json")
        try Data("{}".utf8).write(to: neighbour)
        try BrowserHosts.remove(.firefox, home: home)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "the browser's folder stays")
        try BrowserHosts.remove(.firefox, home: home) // nothing there: nothing done
    }

    @Test("Chromium: nothing written until an extension id is known; then each browser gets its own file")
    func chromiumManifest() throws {
        let home = try Self.temp("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let host = "/Applications/Khayt.app/Contents/MacOS/khayt-browser-host"
        #expect(BrowserExtensionIds.store.isEmpty || BrowserExtensionIds.store.allSatisfy(BrowserExtensionIds.isChromiumId))
        let none = BrowserHosts.chromiumIds(dev: [])
        if none.isEmpty {
            #expect(throws: BrowserHosts.Failure.noExtensionId) {
                try BrowserHosts.install(.chrome, home: home, hostPath: host, chromiumIds: none)
            }
            #expect(!FileManager.default.fileExists(atPath: BrowserHosts.hostsFolder(.chrome, home: home).path),
                    "not even the folder")
        }
        let dev = "abcdefghijklmnopabcdefghijklmnop"
        let ids = BrowserHosts.chromiumIds(dev: [dev, "not-an-id", dev])
        #expect(ids.filter { $0 == dev }.count == 1 && !ids.contains("not-an-id"))
        for browser in BrowserHosts.Browser.allCases where browser.isChromium {
            try BrowserHosts.install(browser, home: home, hostPath: host, chromiumIds: ids)
            let m = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: BrowserHosts.manifestURL(browser, home: home))) as? [String: Any])
            #expect((m["allowed_origins"] as? [String])?.contains("chrome-extension://\(dev)/") == true)
            #expect(m["allowed_extensions"] == nil)
            #expect(BrowserHosts.status(browser, home: home, hostPath: host, chromiumIds: ids) == .on)
        }
        #expect(BrowserHosts.manifestURL(.edge, home: home).path.contains("/Microsoft Edge/NativeMessagingHosts/"))
        #expect(BrowserHosts.manifestURL(.brave, home: home).path.contains("/BraveSoftware/Brave-Browser/NativeMessagingHosts/"))
        #expect(BrowserHosts.manifestURL(.vivaldi, home: home).path.contains("/Vivaldi/NativeMessagingHosts/"))
        #expect(BrowserHosts.manifestURL(.chromium, home: home).path.contains("/Chromium/NativeMessagingHosts/"))
        #expect(BrowserHosts.manifestURL(.chrome, home: home).path.contains("/Google/Chrome/NativeMessagingHosts/"))
        // An id added later (the store's): the file written before needs Update.
        let more = ids + ["ponmlkjihgfedcbaponmlkjihgfedcba"]
        #expect(BrowserHosts.status(.chrome, home: home, hostPath: host, chromiumIds: more) == .stale)
    }

    @Test("a file of that name Khayt did not write: reported, and neither overwritten nor removed")
    func foreignManifest() throws {
        let home = try Self.temp("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = BrowserHosts.manifestURL(.firefox, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = Data(#"{"name":"app.khayt.mac","path":"/usr/local/bin/something-else","type":"stdio"}"#.utf8)
        try theirs.write(to: url)
        let host = "/Applications/Khayt.app/Contents/MacOS/khayt-browser-host"
        #expect(BrowserHosts.status(.firefox, home: home, hostPath: host, chromiumIds: []) == .foreign)
        #expect(throws: BrowserHosts.Failure.foreign) { try BrowserHosts.install(.firefox, home: home, hostPath: host, chromiumIds: []) }
        #expect(throws: BrowserHosts.Failure.foreign) { try BrowserHosts.remove(.firefox, home: home) }
        #expect(try Data(contentsOf: url) == theirs)
        #expect(!BrowserHosts.isOurs(Data("not json".utf8)))
    }

    // MARK: - Downloads

    @Test("Safari's Downloads: only a new model file, once it has stopped growing, and only once")
    func newDownloads() {
        var sizes: [String: Int] = [:]
        let baseline: Set<String> = ["old.stl"]
        func list(_ items: [(String, Bool, Int)]) -> [WebDownloads.Listed] {
            items.map { .init(name: $0.0, isRegularFile: $0.1, size: $0.2) }
        }
        // First look: seen, not yet offered (it may still be arriving).
        #expect(WebDownloads.newModels(list([("old.stl", true, 9), ("dragon.3mf", true, 100), ("a.pdf", true, 5),
                                             ("b.3mf.download", false, 0), (".hidden.stl", true, 3), ("e.stl", true, 0)]),
                                       baseline: baseline, sizes: &sizes, offered: []).isEmpty)
        // Still growing.
        #expect(WebDownloads.newModels(list([("dragon.3mf", true, 200)]), baseline: baseline, sizes: &sizes, offered: []).isEmpty)
        // Settled.
        #expect(WebDownloads.newModels(list([("dragon.3mf", true, 200)]), baseline: baseline, sizes: &sizes, offered: []) == ["dragon.3mf"])
        #expect(WebDownloads.newModels(list([("dragon.3mf", true, 200)]), baseline: baseline, sizes: &sizes,
                                       offered: ["dragon.3mf"]).isEmpty)
    }

    @Test("a path is offered only when it is a non-empty model file under the home folder, not through a link")
    func offerable() throws {
        let home = try Self.temp("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let dl = home.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        let model = dl.appending(path: "x.stl")
        try Data("solid x".utf8).write(to: model)
        let empty = dl.appending(path: "e.stl")
        try Data().write(to: empty)
        let pdf = dl.appending(path: "x.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        let outside = try Self.temp("outside").appending(path: "y.stl")
        try Data("solid y".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let link = dl.appending(path: "link.stl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(WebDownloads.isOfferable(model.path, home: home))
        #expect(!WebDownloads.isOfferable(empty.path, home: home))
        #expect(!WebDownloads.isOfferable(pdf.path, home: home))
        #expect(!WebDownloads.isOfferable(outside.path, home: home))
        #expect(!WebDownloads.isOfferable(link.path, home: home))
        #expect(!WebDownloads.isOfferable(dl.appending(path: "../../\(outside.lastPathComponent)").path, home: home))
        #expect(!WebDownloads.isOfferable("Downloads/x.stl", home: home))
        // A FOLDER in Downloads that links outside home: the file under it
        // is outside home, whatever its spelled path says.
        let away = dl.appending(path: "away", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: away, withDestinationURL: outside.deletingLastPathComponent())
        #expect(!WebDownloads.isOfferable(away.appending(path: outside.lastPathComponent).path, home: home))
    }

    // MARK: - Attaching to the record

    static func webRecord() -> [JSONValue] {
        var rows: [JSONValue] = []
        WebSaveRecord.apply(WebSave.Page(url: "https://www.printables.com/model/7-dragon", site: .printables, title: "Dragon",
                                         creator: "Maker Bob", licence: "cc-by", tags: ["dragon"]),
                            to: &rows, newId: "PF-web", nowMs: 1, nowISO: "2026-10-25T10:00:00.000Z")
        return rows
    }

    static func imported(_ id: String, name: String) -> [String: JSONValue] {
        ["id": .string(id), "name": .string(name), "originalName": .string("\(name).3mf"),
         "sourceFile": .object(["filename": .string("\(name).3mf"), "ext": .string("3mf"), "size": .number(10), "kind": .string("model")]),
         "contentHash": .string("abc"), "geometryKey": .string("g"), "thumbFile": .string("t.png"),
         "source": .string("File Designer"), "licence": .string(""), "tags": .array([]), "printNextAt": .null]
    }

    @Test("a download goes INTO the saved record: its title, creator, tags and page stay; it gains the file")
    func attachInto() throws {
        var rows = Self.webRecord()
        let done = try #require(WebSaveRecord.attach(Self.imported("PF-web", name: "dragon_body"), newId: "PF-web",
                                                     to: "PF-web", in: &rows))
        #expect(done == .init(id: "PF-web", intoSaved: true))
        #expect(rows.count == 1)
        let r = try #require(WebSaveRecord.record("PF-web", in: rows))
        #expect(r["name"] == .string("Dragon"), "the page's title, not the file's name")
        #expect(r["source"] == .string("Maker Bob"), "the page's creator is kept")
        #expect(r["licence"] == .string("cc-by"))
        #expect(r["sourceUrl"] == .string("https://www.printables.com/model/7-dragon"))
        #expect(r["printNextAt"] != nil && r["printNextAt"] != .null)
        #expect(r["contentHash"] == .string("abc") && r["thumbFile"] == .string("t.png"))
        if case .object(let f)? = r["sourceFile"] { #expect(f["filename"] == .string("dragon_body.3mf")) } else { Issue.record("no sourceFile") }
        #expect(WebSaveRecord.hasFile(r))
    }

    @Test("a second download from the same page is a record of its own, carrying the page's facts")
    func attachBeside() throws {
        var rows = Self.webRecord()
        _ = WebSaveRecord.attach(Self.imported("PF-web", name: "body"), newId: "PF-web", to: "PF-web", in: &rows)
        let done = try #require(WebSaveRecord.attach(Self.imported("PF-2", name: "stand"), newId: "PF-2", to: "PF-web", in: &rows))
        #expect(done == .init(id: "PF-2", intoSaved: false))
        #expect(rows.count == 2)
        let r = try #require(WebSaveRecord.record("PF-2", in: rows))
        #expect(r["name"] == .string("stand"))
        #expect(r["sourceUrl"] == .string("https://www.printables.com/model/7-dragon"))
        #expect(r["savedFromWebAt"] != nil)
        #expect(r["source"] == .string("File Designer"), "what the file said is kept")
        #expect(r["licence"] == .string("cc-by"), "a blank licence takes the page's")
        #expect(r["tags"] == .array([.string("dragon")]))
        #expect(WebSaveRecord.attach(Self.imported("PF-3", name: "x"), newId: "PF-3", to: "PF-gone", in: &rows) == nil)
    }
}
