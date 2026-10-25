import AppKit
import Foundation
import Testing
import KhaytCore
import KhaytWebSave
@testable import KhaytApp

/// A download from a page saved with Save to Khayt: offered, never added on
/// its own; added into the saved record on the shop's yes, the download left
/// where it was; Safari's Downloads looked at only while a save is fresh; and
/// the Settings rows that write a browser's host manifest only on a click.
///
/// Everything against temporary folders: a temporary book (`withPerfBook`), a
/// temporary "home" with its own Downloads, a temporary inbox. Never the real
/// book, the real app group or a real browser profile.
@MainActor
@Suite(.serialized)
struct WebSaveAttachAppTests {

    static let stl = """
    solid part
    facet normal 0 0 1
    outer loop
    vertex 0 0 0
    vertex 10 0 0
    vertex 0 10 0
    endloop
    endfacet
    endsolid part
    """

    /// A temporary home with a Downloads folder holding `name`.
    static func home(with name: String, body: String = stl) throws -> (home: URL, file: URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "ws-attach-home-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        let dl = home.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        let file = dl.appending(path: name)
        try Data(body.utf8).write(to: file)
        return (home, file)
    }

    static func attachEntry(page: String, path: String, browser: String = "chrome") throws -> WebSave.Entry {
        try WebSave.entry(fromMessage: ["v": 1, "kind": "attach", "attach": ["page": page, "path": path,
                                                                            "name": (path as NSString).lastPathComponent]],
                          id: WebSave.newEntryId(), at: "2026-10-25T00:00:00Z", browser: browser)
    }

    static let page = "https://www.printables.com/model/123456-articulated-dragon"

    @Test("on the sample, switched off, or for a page nobody saved: refused, and nothing is offered")
    func refusedOffers() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let (home, file) = try Self.home(with: "dragon.stl")
        defer { try? FileManager.default.removeItem(at: home) }
        let e = try Self.attachEntry(page: Self.page, path: file.path)
        #expect(shop.offerWebAttach(e, accepting: false, home: home).0.reason == "off")
        let (answer, offer) = shop.offerWebAttach(e, accepting: true, home: home)
        #expect(answer.reason == "sample" && offer == nil)
    }

    @Test("the menu is the window's: the prompt is one of the window's sheets, and Settings writes a manifest only from a button")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let window = try String(contentsOf: root.appending(path: "ShopWindow.swift"), encoding: .utf8)
        #expect(window.contains("WebAttachPrompt(shop: shop, offer: $0)"))
        let views = try String(contentsOf: root.appending(path: "WebSaveViews.swift"), encoding: .utf8)
        #expect(views.contains("BrowserHostRows(shop: shop)"))
        // The one place the app writes or removes a host manifest, and the
        // only callers of those two are the rows' buttons.
        var writers: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appending(path: name), encoding: .utf8)
            if text.contains("BrowserHosts.install(") || text.contains("BrowserHosts.remove(") { writers.append(name) }
        }
        #expect(writers == ["BrowserHostSettings.swift"])
        let rows = try String(contentsOf: root.appending(path: "BrowserHostSettings.swift"), encoding: .utf8)
        #expect(rows.components(separatedBy: "install(browser)").count - 1 == 1, "install is called from one button")
        #expect(rows.components(separatedBy: "remove(browser)").count - 1 == 1, "remove is called from one button")
        #expect(!rows.contains(".onAppear { install") && !rows.contains("task { install"))
        // Every new word, in both languages.
        for (key, value) in WebAttachWords.table.merging(BrowserHostWords.table, uniquingKeysWith: { a, _ in a }) {
            #expect(value["en"]?.isEmpty == false && value["ar"]?.isEmpty == false, "\(key)")
            #expect(Words.own[key] == value, "\(key) is taken by another table")
        }
    }

    @Test("Safari's Downloads: what was there is never offered; a new model is, once, for the page saved last")
    func safariWatch() async throws {
        let (home, old) = try Self.home(with: "already-here.stl")
        defer { try? FileManager.default.removeItem(at: home) }
        let inbox = WebSaveInbox()
        let watch = SafariDownloadsWatch(inbox: inbox)
        let dl = old.deletingLastPathComponent()
        watch.folder = { dl }
        watch.home = { home }
        watch.watch(recordId: "PF-web-1", title: "Articulated Dragon", site: .printables)
        defer { watch.stop() }
        #expect(watch.isWatching)

        try Data(Self.stl.utf8).write(to: dl.appending(path: "dragon.stl"))
        try Data("%PDF".utf8).write(to: dl.appending(path: "receipt.pdf"))
        watch.look()
        #expect(inbox.offers.isEmpty, "seen once: it may still be arriving")
        watch.look()
        #expect(inbox.offers.map(\.name) == ["dragon.stl"])
        #expect(inbox.offers.first?.recordId == "PF-web-1" && inbox.offers.first?.browser == "safari")
        watch.look()
        #expect(inbox.offers.count == 1, "offered once")

        // Not Now: gone, and nothing was written anywhere.
        inbox.dismissOffer()
        #expect(inbox.offers.isEmpty)

        // After the window, the folder is not looked at again.
        watch.look(now: Date().addingTimeInterval(WebSave.attachWindow + 1))
        #expect(!watch.isWatching)
        try Data(Self.stl.utf8).write(to: dl.appending(path: "later.stl"))
        watch.look(); watch.look()
        #expect(inbox.offers.isEmpty)
    }

    @Test("the same file noticed twice is asked about once")
    func oneQuestionPerFile() {
        let inbox = WebSaveInbox()
        let a = WebAttachOffer(recordId: "PF-1", title: "A", path: "/Users/s/Downloads/a.stl", size: 1, browser: "chrome")
        let again = WebAttachOffer(recordId: "PF-1", title: "A", path: "/Users/s/Downloads/a.stl", size: 1, browser: "safari")
        inbox.enqueue(a); inbox.enqueue(again)
        #expect(inbox.offers.count == 1)
        inbox.offer = nil
        #expect(inbox.offers.count == 1, "the sheet letting go does not drop the question")
        inbox.dismissOffer()
        #expect(inbox.offer == nil)
    }
}

extension LibraryEditPerfTests {

    @Test("a download from a saved page: offered, then on Add to Library copied into that record — the download stays put")
    func webAttachLands() async throws {
        try await withPerfBook(LibraryHealthAppTests.book()) { shop, url in
            let saved = await shop.fileWebSave(try WebSaveAppTests.entry(), accepting: true)
            #expect(saved.state == .saved)
            let recordId = try #require(shop.files.first { $0.isFromWeb }?.id)
            let (home, file) = try WebSaveAttachAppTests.home(with: "dragon_body.stl")
            defer { try? FileManager.default.removeItem(at: home) }

            // Through the inbox, as the browser host writes it.
            let dir = FileManager.default.temporaryDirectory.appending(path: "ws-attach-inbox-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let e = try WebSaveAttachAppTests.attachEntry(page: WebSaveAttachAppTests.page, path: file.path)
            let (answer, offer) = shop.offerWebAttach(e, accepting: true, home: home)
            #expect(answer.state == .offered && answer.title == "Articulated Dragon")
            let o = try #require(offer)
            #expect(o.recordId == recordId && o.name == "dragon_body.stl" && o.size > 0)
            let before = try diskRows(url)
            #expect(try #require(WebSaveRecord.record(recordId, in: before))["sourceFile"] == nil,
                    "offering adds nothing")

            // A path outside the home folder, or not a model, is never offered.
            let outside = try WebSaveAttachAppTests.attachEntry(page: WebSaveAttachAppTests.page, path: "/etc/hosts.stl")
            #expect(shop.offerWebAttach(outside, accepting: true, home: home).0.state == .invalid)
            // Nor one from a page nobody saved.
            let stranger = try WebSaveAttachAppTests.attachEntry(page: "https://www.thingiverse.com/thing:1", path: file.path)
            #expect(shop.offerWebAttach(stranger, accepting: true, home: home).0.reason == "no-record")

            // Yes.
            let done = try await shop.attachWebDownload(o, home: home)
            #expect(done == .init(id: recordId, intoSaved: true))
            let after = try diskRows(url)
            #expect(after.count == before.count, "into the saved record, not beside it")
            let r = try #require(WebSaveRecord.record(recordId, in: after))
            #expect(r["name"] == .string("Articulated Dragon"))
            #expect(r["sourceUrl"] != nil && r["contentHash"] != nil)
            guard case .object(let sf)? = r["sourceFile"], case .string(let stored)? = sf["filename"] else {
                Issue.record("no sourceFile"); return
            }
            let primary = try #require(shop.libraryRoots?.primary)
            let copy = URL(fileURLWithPath: primary).appending(path: LibraryLocation.itemDirName(recordId)).appending(path: stored)
            #expect(FileManager.default.fileExists(atPath: copy.path), "copied into the library")
            #expect(FileManager.default.fileExists(atPath: file.path), "the download is left where it is")
            #expect(shop.files.first { $0.id == recordId }?.isWebOnly == false)

            // The same bytes again: already here, said, nothing written.
            let twice = WebAttachOffer(recordId: recordId, title: o.title, path: file.path, size: o.size, browser: "chrome")
            await #expect(throws: Shop.WebAttachFailure.self) { try await shop.attachWebDownload(twice, home: home) }
            #expect(try diskRows(url).count == after.count)

            // A second, different download from the page: a record beside it.
            let stand = file.deletingLastPathComponent().appending(path: "stand.stl")
            try Data(WebSaveAttachAppTests.stl.replacingOccurrences(of: "10 0 0", with: "20 0 0").utf8).write(to: stand)
            let beside = try await shop.attachWebDownload(
                WebAttachOffer(recordId: recordId, title: o.title, path: stand.path, size: 1, browser: "chrome"), home: home)
            #expect(!beside.intoSaved && beside.id != recordId)
            let second = try #require(WebSaveRecord.record(beside.id, in: try diskRows(url)))
            #expect(second["sourceUrl"] == r["sourceUrl"])
            #expect(FileManager.default.fileExists(atPath: stand.path))
        }
    }

    @Test("a compressed download: its model is taken out and filed, and the .zip is left where it is")
    func webAttachArchive() async throws {
        try await withPerfBook(LibraryHealthAppTests.book()) { shop, url in
            _ = await shop.fileWebSave(try WebSaveAppTests.entry(), accepting: true)
            let recordId = try #require(shop.files.first { $0.isFromWeb }?.id)
            let (home, readme) = try WebSaveAttachAppTests.home(with: "README.txt", body: "print it flat")
            defer { try? FileManager.default.removeItem(at: home) }
            let dl = readme.deletingLastPathComponent()
            let pack = dl.appending(path: "pack", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
            try Data(WebSaveAttachAppTests.stl.utf8).write(to: pack.appending(path: "small.stl"))
            try Data((WebSaveAttachAppTests.stl + "\n").utf8).write(to: pack.appending(path: "dragon.3mf.txt"))
            try Data(WebSaveAttachAppTests.stl.replacingOccurrences(of: "10 0 0", with: "30 0 0").utf8)
                .write(to: pack.appending(path: "big.stl"))
            let zip = dl.appending(path: "dragon.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", pack.path, zip.path]
            try ditto.run(); ditto.waitUntilExit()
            #expect(ditto.terminationStatus == 0)

            let offer = WebAttachOffer(recordId: recordId, title: "Articulated Dragon", path: zip.path, size: 1, browser: "edge")
            #expect(offer.isArchive)
            let done = try await shop.attachWebDownload(offer, home: home)
            #expect(done.intoSaved)
            let r = try #require(WebSaveRecord.record(recordId, in: try diskRows(url)))
            guard case .object(let sf)? = r["sourceFile"] else { Issue.record("no sourceFile"); return }
            #expect(sf["ext"] == .string("stl"))
            #expect(r["originalName"] == .string("big.stl"), "the largest of the best kind")
            #expect(FileManager.default.fileExists(atPath: zip.path), "the download is left where it is")
        }
    }

    @Test("the inbox, end to end: an attach entry is answered offered and put to the shop, not filed")
    func webAttachThroughInbox() async throws {
        try await withPerfBook(LibraryHealthAppTests.book()) { shop, url in
            _ = await shop.fileWebSave(try WebSaveAppTests.entry(), accepting: true)
            let (home, file) = try WebSaveAttachAppTests.home(with: "dragon.stl")
            defer { try? FileManager.default.removeItem(at: home) }

            let dir = FileManager.default.temporaryDirectory.appending(path: "ws-attach-inbox-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let e = try WebSaveAttachAppTests.attachEntry(page: WebSaveAttachAppTests.page, path: file.path)
            try WebInbox.write(e, into: dir)
            let before = try diskRows(url)
            let inbox = WebSaveInbox()
            inbox.directory = { dir }
            inbox.home = { home }
            inbox.start(shop: shop)
            await inbox.drain()
            #expect(WebInbox.awaitAnswer(e.id, inbox: dir, timeout: 2)?.state == .offered)
            #expect(inbox.offers.map(\.name) == ["dragon.stl"])
            #expect(try diskRows(url) == before, "nothing is added until the shop says so")
            inbox.dismissOffer()
            #expect(inbox.offers.isEmpty)
            #expect(try diskRows(url) == before)
        }
    }
}
