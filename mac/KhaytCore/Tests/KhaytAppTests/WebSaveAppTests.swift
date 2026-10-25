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
    }

    @Test("the Safari handler and the app agree on the inbox: a save written there is read, filed and answered")
    func handlerShape() throws {
        // The handler's source names the inbox and the checks, and nothing
        // that reaches the network or the book.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let handler = try String(contentsOf: root.appending(path: "Sources/KhaytSafari/SafariWebExtensionHandler.swift"),
                                 encoding: .utf8)
        #expect(handler.contains("WebSave.entry(fromMessage:"))
        #expect(handler.contains("WebInbox.write("))
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
