import AppKit
import Foundation
import Testing
import KhaytCore
import KhaytWebSave
@testable import KhaytApp

/// "Save to Khayt" in the app: a save from the browser filed into a real
/// (temporary) book, answered, found by "Saved from web", left alone by
/// Library Health — and refused, with the reason, when it should be.
///
/// The writes are in `LibraryEditPerfTests` because `withPerfBook` points the
/// whole process at a temporary support folder; run beside another suite doing
/// the same, the two books cross.
@MainActor
@Suite(.serialized)
struct WebSaveAppTests {

    static func entry(url: String = "https://www.printables.com/model/123456-articulated-dragon",
                      title: String = "Articulated Dragon") throws -> WebSave.Entry {
        try WebSave.entry(fromMessage: ["v": 1, "kind": "save",
                                        "page": ["url": url, "title": title, "creator": "Maker Bob",
                                                 "licence": "cc-by-nc-sa", "tags": ["dragon"]]],
                          id: WebSave.newEntryId(), at: "2026-10-25T00:00:00Z", browser: "safari")
    }

    @Test("switched off on this Mac, the sample open, or a staff member who may not edit: refused, and why")
    func refusals() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let e = try Self.entry()
        #expect(await shop.fileWebSave(e, accepting: false) == .init(id: e.id, state: .refused, reason: "off"))
        #expect(await shop.fileWebSave(e, accepting: true) == .init(id: e.id, state: .refused, reason: "sample"))

        let locked = await OperatorLockTests.shop()
        #expect(await locked.signIn("OP-v", pin: "4444") == .ok)
        locked.moveProblem = nil
        #expect(await locked.fileWebSave(e, accepting: true).reason == "not-allowed")
        #expect(locked.moveProblem == nil, "nobody at the Mac pressed anything: no alert")
    }

    @Test("saves the lock or the sample cannot take yet wait in the inbox; only a live popup is told refused")
    func heldSavesWait() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ws-held-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try Self.entry(url: "https://makerworld.com/en/models/1", title: "Old")
        let fresh = try Self.entry(url: "https://makerworld.com/en/models/2", title: "Fresh")
        try WebInbox.write(old, into: dir)
        try WebInbox.write(fresh, into: dir)
        let oldFile = dir.appending(path: "\(old.id).json")
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: oldFile.path)

        // The sample: nothing is claimed — a real book files them.
        let sample = Shop()
        await sample.load(.sample)
        let inbox = WebSaveInbox()
        inbox.directory = { dir }
        inbox.start(shop: sample)
        await inbox.drain()
        #expect(Set(WebInbox.pending(in: dir).map(\.lastPathComponent)) == ["\(old.id).json", "\(fresh.id).json"])
        #expect(inbox.heldBack)

        // Locked, nobody signed in: the old save waits for a sign-in; the
        // fresh one's popup is still open, so it hears why.
        let locked = await OperatorLockTests.shop()
        // "Fresh" is judged by the file's age, and loading two books on a
        // busy runner can take longer than a popup waits: date it now.
        try FileManager.default.setAttributes([.creationDate: Date()],
                                              ofItemAtPath: dir.appending(path: "\(fresh.id).json").path)
        inbox.start(shop: locked)
        await inbox.drain()
        #expect(WebInbox.pending(in: dir).map(\.lastPathComponent) == ["\(old.id).json"])
        #expect(WebInbox.awaitAnswer(fresh.id, inbox: dir, timeout: 1)?.reason == "not-allowed")
        #expect(WebInbox.awaitAnswer(old.id, inbox: dir, timeout: 0.2) == nil, "the waiting save was answered")
        #expect(inbox.heldBack)
    }

    @Test("every word of Save to Khayt is its own: no key shared with another screen's")
    func ownWords() {
        // `Words.own` keeps the FIRST table's value for a repeated key, so a
        // key that collides shows another screen's sentence (it happened:
        // `mac.ws_settings` was already the web store's).
        for (key, value) in WebSaveWords.table {
            #expect(Words.own[key] == value, "\(key) is taken by another table")
        }
    }

    @Test("Saved from web is a built-in smart folder, and its query keeps the axis through the book")
    func smartFolder() async {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.librarySmartRows.contains { $0.id == "builtin:fromWeb" })
        let q = LibrarySmartFolder.fromWeb.query
        #expect(q.fromWeb && q.filtersOn)
        #expect(LibraryQuery(json: q.json)?.fromWeb == true)
        // Opening it sets the Shop's own axis, and Clear filters takes it off.
        shop.openLibraryQuery(q)
        #expect(shop.libraryFromWebOnly && shop.libraryFilterOn)
        shop.clearLibraryFilter()
        #expect(!shop.libraryFromWebOnly)
        // The sample has none — and with one in memory it is counted.
        #expect(shop.libraryCount(q) == 0)
        var rows: [JSONValue] = shop.libraryRows
        WebSaveRecord.apply(try! Self.entry().page!, to: &rows, newId: "PF-web-1", nowMs: 1, nowISO: "2026-10-25T00:00:00.000Z")
        shop.pretendLibrary(rows)
        #expect(shop.libraryCount(q) == 1)
        await shop.load(.sample)
    }

    @Test("a model saved from a page and never downloaded is not missing, and not unmeasured")
    func health() throws {
        var rows: [JSONValue] = []
        WebSaveRecord.apply(try Self.entry().page!, to: &rows, newId: "PF-web-1", nowMs: 1, nowISO: "x")
        let data = try JSONEncoder().encode(rows[0])
        let file = try JSONDecoder().decode(LibraryFile.self, from: data)
        #expect(file.isFromWeb && file.isWebOnly)
        #expect(file.title == "Articulated Dragon" && file.creator == "Maker Bob")
        let presence = Shop.healthPresence([file], roots: ["/nowhere"], online: [], linkedOnline: { _ in false })
        #expect(presence[file.id] == .web)
        let groups = LibraryHealth.groups(models: [Shop.healthModel(file, presence: .web)])
        #expect(!groups.contains { $0.kind == .missing || $0.kind == .noFigures })
    }

    @Test("a cover is kept only when it decodes as a picture, and only over https")
    func cover() async throws {
        #expect(Shop.coverURI(Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)) == nil)
        #expect(Shop.coverURI(Data("not a picture".utf8)) == nil)
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let uri = try #require(Shop.coverURI(png))
        #expect(uri.hasPrefix("data:image/jpeg;base64,"))
        // Refused before anything is asked of the network.
        #expect(await Shop.fetchWebCover("http://example.com/c.jpg") == nil)
        #expect(await Shop.fetchWebCover("file:///etc/hosts") == nil)
        // Nor to the shop's own network, by name or by address.
        for host in ["localhost", "printer.local", "127.0.0.1", "10.0.0.5", "192.168.1.20", "172.20.0.1",
                     "169.254.10.1", "[::1]", "[fe80::1]", "[fd00::1]"] {
            #expect(!WebCoverFetch.isPublic(host: host), "\(host) was taken as public")
            #expect(await Shop.fetchWebCover("https://\(host)/c.jpg") == nil)
        }
        #expect(WebCoverFetch.isPublic(v4: [93, 184, 215, 14]))
        #expect(!WebCoverFetch.isPublic(v4: [100, 64, 0, 1]))
    }

    @Test("a cover is decoded only as JPEG, PNG, WebP or GIF, and only up to a sane size")
    func coverFormats() throws {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        // A TIFF is a picture ImageIO reads, and not one a cover may be.
        #expect(Shop.coverURI(tiff) == nil)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let jpeg = try #require(rep.representation(using: .jpeg, properties: [:]))
        let gif = try #require(rep.representation(using: .gif, properties: [:]))
        #expect(Shop.coverURI(jpeg) != nil && Shop.coverURI(gif) != nil)
        // A PNG header claiming 50,000 × 50,000 is refused before a pixel is made.
        var png = try #require(rep.representation(using: .png, properties: [:]))
        let side: [UInt8] = [0x00, 0x00, 0xC3, 0x50]
        png.replaceSubrange(16..<20, with: side)
        png.replaceSubrange(20..<24, with: side)
        #expect(Shop.coverURI(png) == nil)
    }

    @Test("the Safari handler and the app agree on the inbox: a save written there is read, filed and answered")
    func handlerShape() throws {
        // The handler's source names the inbox and the checks, and nothing
        // that reaches the network or the book.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let handler = try String(contentsOf: root.appending(path: "Sources/KhaytSafari/SafariWebExtensionHandler.swift"),
                                 encoding: .utf8)
        // Checked and written by the path the browser host shares
        // (`WebInbox.reply`, which calls `WebSave.entry` and `WebInbox.write`).
        #expect(handler.contains("WebInbox.reply(toMessageData:"))
        for forbidden in ["URLSession", "khayt-store", "NSWorkspace.shared.open", "Process("] {
            #expect(!handler.contains(forbidden), "the Safari handler must not use \(forbidden)")
        }
    }
}

extension LibraryEditPerfTests {

    @Test("a save from the browser lands in the book: a record, on Print next, answered saved; again, updated")
    func webSaveLands() async throws {
        try await withPerfBook(LibraryHealthAppTests.book()) { shop, url in
            let first = try WebSaveAppTests.entry()
            let answer = await shop.fileWebSave(first, accepting: true)
            #expect(answer.state == .saved && answer.title == "Articulated Dragon")
            let rows = try diskRows(url)
            let saved = rows.compactMap { row -> [String: JSONValue]? in
                if case .object(let o) = row, o["sourceUrl"] != nil { o } else { nil }
            }
            #expect(saved.count == 1)
            #expect(saved.first?["name"] == .string("Articulated Dragon"))
            #expect(saved.first?["printNextAt"] != nil)
            #expect(saved.first?["licence"] == .string("cc-by-nc-sa"))
            #expect(shop.files.contains { $0.isFromWeb && $0.isPrintNext })
            #expect(shop.libraryCount(LibrarySmartFolder.fromWeb.query) == 1)

            // The same model at a renamed address: the one record, updated.
            let again = try WebSaveAppTests.entry(url: "https://printables.com/model/123456-dragon-v2", title: "Dragon v2")
            #expect(await shop.fileWebSave(again, accepting: true).state == .updated)
            #expect(try diskRows(url).count == rows.count)
        }
    }

    @Test("the inbox, end to end: a file written the way the extension writes it is filed and answered")
    func webSaveInboxDrains() async throws {
        try await withPerfBook(LibraryHealthAppTests.book()) { shop, url in
            let dir = FileManager.default.temporaryDirectory.appending(path: "ws-app-inbox-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let entry = try WebSaveAppTests.entry(url: "https://makerworld.com/en/models/88231", title: "Gridfinity Bin")
            try WebInbox.write(entry, into: dir)
            let inbox = WebSaveInbox()
            inbox.directory = { dir }
            inbox.start(shop: shop)
            await inbox.drain()
            #expect(WebInbox.pending(in: dir).isEmpty, "taken out of the inbox")
            let answer = WebInbox.awaitAnswer(entry.id, inbox: dir, timeout: 2)
            #expect(answer?.state == .saved)
            #expect(try diskRows(url).contains { row in
                if case .object(let o) = row { o["sourceSite"] == .string("makerworld") } else { false }
            })
            #expect(inbox.lastSaved?.title == "Gridfinity Bin")
        }
    }
}
