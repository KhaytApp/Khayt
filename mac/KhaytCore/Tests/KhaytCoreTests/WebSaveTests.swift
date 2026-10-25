import Foundation
import Testing
@testable import KhaytCore
@testable import KhaytWebSave

/// "Save to Khayt": what a page may send, and the record it becomes.
///
/// The message comes from a web page through a script, so these are the
/// checks that stand between a hostile page and the book — https only, caps
/// on everything, no control characters, the site worked out from the
/// address and never taken from the page — and the record rule: a second save
/// of the same model updates it, and what the shop changed is never undone.
struct WebSaveTests {

    static func message(_ page: [String: Any], v: Int = 1, kind: String = "save") -> [String: Any] {
        ["v": v, "kind": kind, "page": page]
    }

    static var dragon: [String: Any] { [
        "url": "https://www.printables.com/model/123456-articulated-dragon",
        "title": "Articulated Dragon", "creator": "Maker Bob",
        "licence": "cc-by-nc-sa", "description": "A print-in-place dragon.\n\n\n\nNo supports.",
        "tags": ["dragon", "#flexi", "Dragon", ""],
        "cover": "https://media.printables.com/cover.webp",
        "files": [["url": "https://files.printables.com/dragon.3mf", "name": "dragon.3mf"],
                  ["url": "javascript:alert(1)", "name": "x.stl"]],
    ] }

    static func entry(_ page: [String: Any]) throws -> WebSave.Entry {
        try WebSave.entry(fromMessage: message(page), id: WebSave.newEntryId(), at: "2026-10-25T00:00:00Z",
                          browser: "safari")
    }

    // MARK: - The message

    @Test("a model page passes, tidied: tags de-duplicated and unhashed, a javascript: link dropped, blank lines folded")
    func passes() throws {
        let e = try Self.entry(Self.dragon)
        let p = try #require(e.page)
        #expect(e.kind == .save && e.browser == "safari")
        #expect(p.site == .printables)
        #expect(p.title == "Articulated Dragon" && p.creator == "Maker Bob")
        #expect(p.tags == ["dragon", "flexi"])
        #expect(p.files == [.init(url: "https://files.printables.com/dragon.3mf", name: "dragon.3mf")])
        #expect(p.description == "A print-in-place dragon.\n\nNo supports.")
        #expect(p.cover == "https://media.printables.com/cover.webp")
    }

    @Test("refused whole: http, a password in the address, no title, another version, an unknown kind, too big")
    func refusals() {
        func refusal(_ m: [String: Any]) -> WebSave.Refusal? {
            do { _ = try WebSave.entry(fromMessage: m, id: "x", at: "", browser: "chrome"); return nil }
            catch { return error }
        }
        var p = Self.dragon
        p["url"] = "http://www.printables.com/model/1"
        #expect(refusal(Self.message(p)) == .badURL)
        p["url"] = "https://user:pw@printables.com/model/1"
        #expect(refusal(Self.message(p)) == .badURL)
        p["url"] = "file:///etc/passwd"
        #expect(refusal(Self.message(p)) == .badURL)
        p = Self.dragon; p["title"] = "  \u{0007} "
        #expect(refusal(Self.message(p)) == .noTitle)
        #expect(refusal(Self.message(Self.dragon, v: 2)) == .badVersion)
        #expect(refusal(Self.message(Self.dragon, kind: "delete")) == .badKind)
        #expect(refusal(["v": 1, "kind": "save"]) == .notJSON)
        p = Self.dragon; p["description"] = String(repeating: "x", count: 70_000)
        #expect(refusal(Self.message(p)) == .tooLarge)
    }

    @Test("caps and controls: a title cannot be an essay, read backwards, or carry a line break")
    func caps() throws {
        var p = Self.dragon
        p["title"] = "Dra\u{202E}gon\n" + String(repeating: "a", count: 500)
        p["tags"] = (0..<60).map { "t\($0)" }
        p["files"] = (0..<60).map { ["url": "https://x.example/\($0).stl", "name": "\($0).stl"] }
        p["cover"] = "http://insecure.example/c.jpg"
        let page = try #require(try Self.entry(p).page)
        #expect(page.title.count == WebSave.maxTitle)
        #expect(!page.title.unicodeScalars.contains { $0.value == 0x202E || $0 == "\n" })
        #expect(page.title.hasPrefix("Dragon a"))
        #expect(page.tags.count == WebSave.maxTags)
        #expect(page.files.count == WebSave.maxFiles)
        #expect(page.cover == nil, "an http picture is no picture")
    }

    @Test("the site is the address: a page on example.com calling itself Printables is web")
    func siteFromAddress() throws {
        var p = Self.dragon
        p["url"] = "https://printables.com.evil.example/model/1"
        p["site"] = "printables"
        #expect(try Self.entry(p).page?.site == .web)
        #expect(WebSave.Site.of(host: "makerworld.com") == .makerworld)
        #expect(WebSave.Site.of(host: "www.thingiverse.com") == .thingiverse)
        #expect(WebSave.Site.of(host: "cults3d.com") == .cults3d)
    }

    @Test("one model, however its address is written: renamed slugs, locales, queries and fragments")
    func identity() {
        #expect(WebSave.identity(of: "https://www.printables.com/model/123456-articulated-dragon")
                == WebSave.identity(of: "https://printables.com/model/123456-dragon-v2/files?lang=en#comments"))
        #expect(WebSave.identity(of: "https://makerworld.com/en/models/88231")
                == WebSave.identity(of: "https://makerworld.com/zh/models/88231-gridfinity?from=x"))
        #expect(WebSave.identity(of: "https://www.thingiverse.com/thing:4711/files")
                == WebSave.identity(of: "https://thingiverse.com/thing:4711"))
        #expect(WebSave.identity(of: "https://cults3d.com/en/3d-model/art/low-poly-fox")
                == WebSave.identity(of: "https://cults3d.com/fr/3d-model/art/low-poly-fox/"))
        #expect(WebSave.identity(of: "https://www.printables.com/model/1-a")
                != WebSave.identity(of: "https://www.printables.com/model/2-a"))
        #expect(WebSave.identity(of: "https://a.example/x") != WebSave.identity(of: "https://b.example/x"))
    }

    @Test("a download to attach must be a model file, by an absolute path with no ..")
    func attach() throws {
        func m(_ path: String) -> [String: Any] {
            ["v": 1, "kind": "attach", "attach": ["page": "https://printables.com/model/1", "path": path]]
        }
        let ok = try WebSave.entry(fromMessage: m("/Users/a/Downloads/dragon.3mf"), id: "x", at: "", browser: "chrome")
        #expect(ok.attach?.name == "dragon.3mf")
        for bad in ["/Users/a/Downloads/run.command", "Downloads/x.stl", "/Users/a/../../etc/x.stl"] {
            #expect(throws: WebSave.Refusal.badPath) {
                try WebSave.entry(fromMessage: m(bad), id: "x", at: "", browser: "chrome")
            }
        }
    }

    @Test("a page's claimed address on another site is not believed: the tab's address is saved instead")
    func canonicalOnAnotherSite() throws {
        var p = Self.dragon
        p["url"] = "https://www.printables.com/model/123456-articulated-dragon"
        p["tabUrl"] = "https://free-stl.example/dragon"
        let spoofed = try #require(try Self.entry(p).page)
        #expect(spoofed.url == "https://free-stl.example/dragon")
        #expect(spoofed.site == .web)
        // The site's own canonical on another of its hosts stands.
        p["tabUrl"] = "https://printables.com/model/123456-articulated-dragon/files"
        #expect(try Self.entry(p).page?.url == "https://www.printables.com/model/123456-articulated-dragon")
        #expect(WebSave.registrable("shop.example.co.uk") == "example.co.uk")
        #expect(WebSave.registrable("printables.com.evil.example") == "evil.example")
    }

    // MARK: - The inbox

    @Test("written whole, read back through the same checks, claimed once, answered and collected")
    func inbox() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ws-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = try Self.entry(Self.dragon)
        try WebInbox.write(e, into: dir)
        let waiting = WebInbox.pending(in: dir)
        #expect(waiting.map(\.lastPathComponent) == ["\(e.id).json"])
        let claimed = try #require(WebInbox.claim(waiting[0]))
        #expect(WebInbox.claim(waiting[0]) == nil, "a second reader gets nothing")
        #expect(WebInbox.pending(in: dir).isEmpty)
        let back = try WebSave.entry(fromInboxFile: claimed.data)
        #expect(back == e)
        // Kept until it is filed: only `finish` lets it go.
        #expect(FileManager.default.fileExists(atPath: claimed.file.path))
        WebInbox.finish(claimed)
        #expect(!FileManager.default.fileExists(atPath: claimed.file.path))
        try WebInbox.answer(.init(id: e.id, state: .saved, title: "Articulated Dragon"), inbox: dir)
        let answer = WebInbox.awaitAnswer(e.id, inbox: dir, timeout: 1)
        #expect(answer?.state == .saved && answer?.message["ok"] as? Bool == true)
        #expect(WebInbox.awaitAnswer(e.id, inbox: dir, timeout: 0.2) == nil, "collected once")
    }

    @Test("a claimed save handed back, or left by a copy of the app that died, waits in the inbox again")
    func inboxPutBackAndRecover() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ws-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = try Self.entry(Self.dragon)
        try WebInbox.write(e, into: dir)
        let claimed = try #require(WebInbox.claim(WebInbox.pending(in: dir)[0]))
        WebInbox.putBack(claimed)
        #expect(WebInbox.pending(in: dir).map(\.lastPathComponent) == ["\(e.id).json"])
        // A claim by a process that is gone (pid 99999 is not running here,
        // or is not ours) comes back at launch; a live one is left alone.
        let again = try #require(WebInbox.claim(WebInbox.pending(in: dir)[0]))
        let dead = dir.appending(path: ".claimed-99999-\(e.id).json")
        try FileManager.default.moveItem(at: again.file, to: dead)
        let live = dir.appending(path: ".claimed-1-WS-\(UUID().uuidString.uppercased()).json")
        try Data("{}".utf8).write(to: live)
        if kill(99999, 0) != 0 && errno == ESRCH {
            WebInbox.recoverClaims(in: dir)
            #expect(WebInbox.pending(in: dir).map(\.lastPathComponent) == ["\(e.id).json"])
        }
        #expect(FileManager.default.fileExists(atPath: live.path), "launchd's claim (pid 1, alive) was taken")
    }

    @Test("claiming never follows a symlink, never blocks on a FIFO, and reads a regular file only")
    func inboxClaimIsSafe() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ws-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secret = dir.appending(path: "secret.txt")
        try Data("not a save".utf8).write(to: secret)
        let link = dir.appending(path: "WS-\(UUID().uuidString.uppercased()).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let fifo = dir.appending(path: "WS-\(UUID().uuidString.uppercased()).json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        // Neither is listed as waiting.
        #expect(WebInbox.pending(in: dir).isEmpty)
        // And swapped in after the listing, neither is read: no bytes, at once.
        let viaLink = try #require(WebInbox.claim(link))
        #expect(viaLink.data.isEmpty)
        let viaFifo = try #require(WebInbox.claim(fifo))
        #expect(viaFifo.data.isEmpty)
        WebInbox.finish(viaLink); WebInbox.finish(viaFifo)
        #expect(FileManager.default.fileExists(atPath: secret.path), "the link's target was touched")
    }

    @Test("a file in the inbox that was not written by us is ignored, and a tampered one is re-checked")
    func inboxUntrusted() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ws-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appending(path: "WS-not-a-uuid.json"))
        try Data("{}".utf8).write(to: dir.appending(path: "notes.json"))
        #expect(WebInbox.pending(in: dir).isEmpty)
        var e = try Self.entry(Self.dragon)
        e.page?.url = "http://insecure.example/x"
        let tampered = try JSONEncoder().encode(e)
        #expect(throws: WebSave.Refusal.badURL) { try WebSave.entry(fromInboxFile: tampered) }
    }

    // MARK: - The record

    static func page(_ overrides: [String: Any] = [:]) throws -> WebSave.Page {
        var p = dragon
        for (k, v) in overrides { p[k] = v }
        return try #require(try entry(p).page)
    }

    @Test("a new save is a record with no file, its title as the name, on Print next, the licence translated")
    func newRecord() throws {
        var rows: [JSONValue] = [.object(["id": .string("PF-old"), "tags": .array([.string("Dragon")])])]
        let out = WebSaveRecord.apply(try Self.page(), to: &rows, newId: "PF-new", nowMs: 1_000, nowISO: "2026-10-25T00:00:00.000Z")
        #expect(out == .init(id: "PF-new", created: true, wantsCover: true))
        guard case .object(let r) = rows[0] else { Issue.record("no record"); return }
        #expect(r["name"] == .string("Articulated Dragon"))
        #expect(r["sourceFile"] == nil, "no file: the shape a printer-history record already has")
        #expect(r["source"] == .string("Maker Bob"))
        #expect(r["licence"] == .string("cc-by-nc-sa"))
        #expect(r["sourceUrl"] == .string("https://www.printables.com/model/123456-articulated-dragon"))
        #expect(r["sourceSite"] == .string("printables"))
        #expect(r["printNextAt"] == .string("2026-10-25T00:00:00.000Z"))
        #expect(r["savedFromWebAt"] == .string("2026-10-25T00:00:00.000Z"))
        #expect(r["createdAt"] == .number(1_000))
        // The book's own spelling of a tag it already has.
        #expect(r["tags"] == .array([.string("Dragon"), .string("flexi")]))
    }

    @Test("a platform's own licence terms stay unsaid in `licence`, kept as words beside it")
    func platformLicence() throws {
        var rows: [JSONValue] = []
        WebSaveRecord.apply(try Self.page(["licence": "Standard Digital File License"]), to: &rows,
                            newId: "PF-1", nowMs: 0, nowISO: "x")
        guard case .object(let r) = rows[0] else { return }
        #expect(r["licence"] == .string(""))
        #expect(r["sourceLicenceText"] == .string("Standard Digital File License"))
    }

    @Test("the same model saved again updates it, and never undoes what the shop changed")
    func secondSave() throws {
        var rows: [JSONValue] = []
        WebSaveRecord.apply(try Self.page(), to: &rows, newId: "PF-1", nowMs: 0, nowISO: "2026-10-01T00:00:00.000Z")
        guard case .object(var r) = rows[0] else { return }
        r["name"] = .string("Dragon for Noura")      // the shop renamed it
        r["licence"] = .string("commercial")          // and bought a licence
        r["tags"] = .array([.string("gift")])
        r["userPhoto"] = .string("data:image/jpeg;base64,AAAA")
        r.removeValue(forKey: "printNextAt")          // and printed it
        rows[0] = .object(r)
        let out = WebSaveRecord.apply(try Self.page(["url": "https://printables.com/model/123456-dragon-v2",
                                                     "title": "Dragon v2", "description": "Now with wings."]),
                                      to: &rows, newId: "PF-2", nowMs: 0, nowISO: "2026-10-20T00:00:00.000Z")
        #expect(out == .init(id: "PF-1", created: false, wantsCover: false))
        #expect(rows.count == 1)
        guard case .object(let after) = rows[0] else { return }
        #expect(after["name"] == .string("Dragon for Noura"))
        #expect(after["licence"] == .string("commercial"))
        #expect(after["tags"] == .array([.string("gift")]))
        #expect(after["sourceUrl"] == .string("https://printables.com/model/123456-dragon-v2"))
        #expect(after["sourceNote"] == .string("Now with wings."))
        #expect(after["savedFromWebAt"] == .string("2026-10-20T00:00:00.000Z"))
        #expect(after["printNextAt"] == .string("2026-10-20T00:00:00.000Z"), "saving it again is wanting it again")
        #expect(after["rev"] != nil, "stamped for sync")
    }

    @Test("a model whose source the shop typed as the page's address is that model")
    func typedSource() throws {
        var rows: [JSONValue] = [.object(["id": .string("PF-typed"), "name": .string("My dragon"),
                                          "source": .string("https://www.printables.com/model/123456")])]
        let out = WebSaveRecord.apply(try Self.page(), to: &rows, newId: "PF-new", nowMs: 0, nowISO: "x")
        #expect(out.id == "PF-typed" && !out.created)
        guard case .object(let r) = rows[0] else { return }
        #expect(r["source"] == .string("Maker Bob"), "the address moved to sourceUrl; the creator took its place")
        #expect(r["name"] == .string("My dragon"))
    }

    @Test("the cover goes on only while the record still has no picture")
    func cover() throws {
        var rows: [JSONValue] = []
        WebSaveRecord.apply(try Self.page(), to: &rows, newId: "PF-1", nowMs: 0, nowISO: "x")
        #expect(!WebSaveRecord.setCover("https://not-a-data-uri", id: "PF-1", in: &rows))
        #expect(WebSaveRecord.setCover("data:image/jpeg;base64,AAAA", id: "PF-1", in: &rows))
        #expect(!WebSaveRecord.setCover("data:image/jpeg;base64,BBBB", id: "PF-1", in: &rows), "never over a picture")
    }
}
