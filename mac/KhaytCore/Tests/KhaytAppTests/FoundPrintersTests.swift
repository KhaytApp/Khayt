import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Printers a scan found are remembered on this computer for a few days
/// (`lib/found-printers.js`), in the same file the other app keeps and never
/// in the book.
@MainActor
@Suite(.serialized)
struct FoundPrintersTests {
    static let engine = OperatorLockTests.sharedEngine
    static let day = 24.0 * 60 * 60 * 1000

    static func printer(_ name: String, _ host: String, serial: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "host": .string(host), "port": .number(80)]
        if let serial { o["serial"] = .string(serial) }
        return .object(o)
    }
    static func obj(_ v: JSONValue) -> [String: JSONValue] { if case .object(let o) = v { return o }; return [:] }

    @Test("the bundled rule: one entry per printer, a moved address follows the serial, three days then gone, forty at most")
    func rule() async throws {
        let t0 = 1_795_000_000_000.0
        var list = try await Self.engine.rememberFound(list: .array([]), found: [Self.printer("U1", "192.168.1.20", serial: "SN1"),
                                                                             Self.printer("Mini", "192.168.1.21")],
                                                       nowMs: t0, source: "mdns")
        #expect(list.count == 2)
        // The same printer again, on a new address: still one entry, and it says where it was.
        list = try await Self.engine.rememberFound(list: .array(list), found: [Self.printer("U1", "192.168.1.55", serial: "SN1")],
                                                   nowMs: t0 + 1000, source: "mdns")
        #expect(list.count == 2)
        let u1 = Self.obj(try #require(list.first { Self.obj($0)["serial"] == .string("SN1") }))
        #expect(u1["host"] == .string("192.168.1.55") && u1["previousHost"] == .string("192.168.1.20"))
        #expect(u1["seenCount"] == .number(2) && u1["firstSeen"] == .number(t0) && u1["lastSeen"] == .number(t0 + 1000))
        // What a picker would show: this scan's, then the earlier one it missed.
        let shown = try await Self.engine.foundForScan(list: .array(list), scanned: [Self.printer("U1", "192.168.1.55", serial: "SN1")],
                                                       nowMs: t0 + 2000)
        #expect(shown.map { Self.obj($0)["seenNow"] } == [.bool(true), .bool(false)])
        // Three days on, nothing is remembered.
        #expect(try await Self.engine.recentFound(list: .array(list), nowMs: t0 + 3 * Self.day + 2000).isEmpty)
        #expect(try await Self.engine.recentFound(list: .array(list), nowMs: t0 + 2 * Self.day).count == 2)
        // Forty at most, and junk on disk is an empty list, not a crash.
        let many = (0..<60).map { Self.printer("P\($0)", "10.0.0.\($0 + 1)") }
        #expect(try await Self.engine.rememberFound(list: .array([]), found: many, nowMs: t0, source: "sweep").count == 40)
        #expect(try await Self.engine.rememberFound(list: .string("junk"), found: [], nowMs: t0, source: "mdns").isEmpty)
    }

    // MARK: - The sheet (page 28, frame A)

    static func earlier(_ fields: [String: JSONValue]) -> EarlierFind? { EarlierFind(.object(fields)) }

    @Test("an earlier find is a row the rule marked not seen now, in the shape Add takes")
    func earlierFind() throws {
        let seen = 1_795_000_000_000.0
        let find = try #require(Self.earlier(["name": .string("Saturn 4"), "host": .string("192.168.1.41"), "port": .number(3030),
                                              "vendor": .string("Elegoo"), "serial": .string(""), "connection": .null,
                                              "seenNow": .bool(false), "lastSeen": .number(seen), "previousHost": .string("192.168.1.40")]))
        #expect(find.printer.name == "Saturn 4" && find.printer.host == "192.168.1.41" && find.printer.port == 3030)
        #expect(find.printer.vendor == "Elegoo" && find.printer.serial == nil, "an empty string is not a serial")
        #expect(find.printer.connection == nil, "a printer Khayt cannot talk to still says so")
        #expect(find.lastSeen == Date(timeIntervalSince1970: seen / 1000) && find.previousHost == "192.168.1.40")
        // This scan's own printers are not earlier finds; nor is a row with no address or no time.
        #expect(Self.earlier(["name": .string("U1"), "host": .string("192.168.1.20"), "seenNow": .bool(true), "lastSeen": .number(seen)]) == nil)
        #expect(Self.earlier(["name": .string("U1"), "seenNow": .bool(false), "lastSeen": .number(seen)]) == nil)
        #expect(Self.earlier(["name": .string("U1"), "host": .string("192.168.1.20"), "seenNow": .bool(false)]) == nil)
        #expect(EarlierFind(.string("junk")) == nil)
        // No name: the address stands in. The same address before and now is not a move.
        let bare = try #require(Self.earlier(["host": .string("192.168.1.9"), "seenNow": .bool(false), "lastSeen": .number(seen),
                                              "previousHost": .string("192.168.1.9")]))
        #expect(bare.printer.name == "192.168.1.9" && bare.previousHost == nil)
    }

    @Test("when it was seen is said in words, and a printer that moved says where it was")
    func seenWords() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let two = try #require(Self.earlier(["name": .string("A"), "host": .string("10.0.0.2"), "seenNow": .bool(false),
                                             "lastSeen": .number((now.timeIntervalSince1970 - 2 * 3600) * 1000)]))
        #expect(FindPrintersSheet.seen(two, now: now, words: shop.words) == "Seen 2 hours ago. It may be asleep or busy.")
        let moved = try #require(Self.earlier(["name": .string("B"), "host": .string("10.0.0.3"), "seenNow": .bool(false),
                                               "lastSeen": .number((now.timeIntervalSince1970 - 26 * 3600) * 1000),
                                               "previousHost": .string("10.0.0.9")]))
        #expect(FindPrintersSheet.seen(moved, now: now, words: shop.words) == "Seen yesterday, at another address before: 10.0.0.9")
        // A sighting stamped after "now" (a clock that moved) is never in the future.
        let ahead = try #require(Self.earlier(["name": .string("C"), "host": .string("10.0.0.4"), "seenNow": .bool(false),
                                               "lastSeen": .number((now.timeIntervalSince1970 + 600) * 1000)]))
        #expect(!FindPrintersSheet.seen(ahead, now: now, words: shop.words).contains("in "))
    }

    @Test("the sheet is today's with nothing earlier; the second list, its note and Forget come with earlier finds")
    func sheetWiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let sheet = try String(contentsOf: app.appending(path: "FindPrintersSheet.swift"), encoding: .utf8)
        // The scan first (it remembers), then what it missed.
        let scan = try #require(sheet.range(of: "found = await shop.findPrinters()"))
        let missed = try #require(sheet.range(of: "earlier = await shop.earlierFinds(notIn: found)"))
        #expect(scan.upperBound < missed.lowerBound)
        // One list and no headings when nothing was seen earlier.
        #expect(sheet.contains("if earlier.isEmpty {\n                        ForEach(found) { row($0, when: nil, primary: true) }"))
        for word in ["mac.find_now", "mac.find_earlier", "mac.find_kept_here", "mac.find_forget", "common.done"] {
            #expect(sheet.contains("callIt(\"\(word)\")"), Comment(rawValue: word))
        }
        // Forget asks nothing and empties the list on screen at once.
        #expect(sheet.contains("shop.forgetFoundPrinters()\n                        earlier = []"))
        // Adding an earlier find is adding a found printer: no second path.
        #expect(sheet.components(separatedBy: "await shop.addFound(printer)").count == 3)
        // The frame's words.
        let words = try String(contentsOf: app.appending(path: "Words.swift"), encoding: .utf8)
        #expect(words.contains(#""mac.find_earlier": ["en": "Seen earlier, not in this scan", "ar": "شوهدت سابقًا، وليست في هذا البحث"]"#))
        #expect(words.contains(#""mac.find_forget": ["en": "Forget earlier finds", "ar": "نسيان ما وُجد سابقًا"]"#))
        #expect(words.contains("Printers found in the last 3 days are kept on this computer only. They are not in your book and are never sent anywhere."))
    }

    @Test("the sample book remembers nothing and writes no file")
    func sample() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let found = try JSONDecoder().decode([KhaytEngine.FoundPrinter].self,
                                             from: Data(#"[{"name":"U1","host":"192.168.1.20","port":80}]"#.utf8))
        await shop.rememberFound(found)
        #expect(await shop.rememberedPrinters().isEmpty)
    }

    @Test("Find printers is the one place a scan is remembered, and the list is never put in the book or sent to a phone")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let printers = try String(contentsOf: app.appending(path: "Shop+Printers.swift"), encoding: .utf8)
        #expect(printers.contains("await rememberFound(found)"))
        let store = try String(contentsOf: app.appending(path: "FoundPrintersStore.swift"), encoding: .utf8)
        #expect(!store.contains("StoreWriter"), "the list reached the book's writer")
        let lan = try String(contentsOf: app.appending(path: "LanServer.swift"), encoding: .utf8)
        #expect(!lan.contains("FoundPrintersStore") && !lan.contains("rememberedPrinters"))
    }
}

/// On a real temporary book. In the perf suite's extension because that suite
/// is the one that owns `supportFolderForTests`, one test at a time.
extension LibraryEditPerfTests {
    @Test("the file is this computer's, beside the book and never in it, in the other app's shape")
    func file() async throws {
        try await withPerfBook(Self.shopBook(models: 10)) { shop, url in
            let build = StoreReader.Build.shipped
            let file = FoundPrintersStore.url(build)
            #expect(file.deletingLastPathComponent() == url.deletingLastPathComponent())
            #expect(file.lastPathComponent == "found-printers.json")
            #expect(await shop.rememberedPrinters().isEmpty)
            let bookBefore = try Data(contentsOf: url)

            let found = try JSONDecoder().decode([KhaytEngine.FoundPrinter].self, from: Data(#"""
                [{"name":"U1","host":"192.168.1.20","port":7125,"serial":"SN1","vendor":"Snapmaker"},
                 {"name":"Mini","host":"192.168.1.21","port":80}]
                """#.utf8))
            let now = Date(timeIntervalSince1970: 1_795_000_000)
            await shop.rememberFound(found, now: now)

            // On disk: { version: 1, printers: [...] }, as lib/main/printer-discovery.js writes it.
            let onDisk = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
            guard case .object(let o) = onDisk, case .array(let printers)? = o["printers"] else {
                Issue.record("not the other app's shape"); return
            }
            #expect(o["version"] == .number(1) && printers.count == 2)
            #expect(printers.allSatisfy { FoundPrintersTests.obj($0)["source"] == .string("mdns") })
            // The book is byte for byte what it was.
            #expect(try Data(contentsOf: url) == bookBefore, "a scan wrote to the book")

            let later = now.addingTimeInterval(3600)
            #expect(await shop.rememberedPrinters(now: later).count == 2)
            #expect(await shop.rememberedPrinters(now: now.addingTimeInterval(4 * 86400)).isEmpty, "older than three days")
            // An empty scan forgets nothing.
            await shop.rememberFound([], now: later)
            #expect(await shop.rememberedPrinters(now: later).count == 2)
            // A file that is not ours reads as nothing, and the next scan starts again.
            try Data("[1,2".utf8).write(to: file)
            #expect(await shop.rememberedPrinters(now: later).isEmpty)
            await shop.rememberFound(found, now: later)
            #expect(await shop.rememberedPrinters(now: later).count == 2)
            // THE OTHER APP WRITES BETWEEN OUR READ AND OUR WRITE: its printer
            // is kept, and so is ours. Once, as a real overlap is.
            let theirs = Data(#"{"version":1,"printers":[{"name":"Theirs","host":"192.168.1.99","port":80,"source":"mdns","firstSeen":\#(Int(later.timeIntervalSince1970 * 1000)),"lastSeen":\#(Int(later.timeIntervalSince1970 * 1000)),"seenCount":1}]}"#.utf8)
            var landed = 0
            FoundPrintersStore.beforeWriteForTests = {
                if landed == 0 { try? theirs.write(to: file, options: .atomic) }
                landed += 1
            }
            await shop.rememberFound(found, now: later)
            FoundPrintersStore.beforeWriteForTests = nil
            #expect(landed == 2, "the write was not started again on the new file: \(landed)")
            let merged = await shop.rememberedPrinters(now: later)
            let names = Set(merged.compactMap { v -> String? in
                if case .string(let n)? = FoundPrintersTests.obj(v)["name"] { return n }; return nil })
            #expect(names == ["Theirs", "U1", "Mini"], "one app's write replaced the other's: \(names)")
            // Overtaken every time: this scan gives up, and what the other app wrote stands.
            var round = 0
            FoundPrintersStore.beforeWriteForTests = {
                round += 1
                try? Data(#"{"version":1,"printers":[],"round":\#(round)}"#.utf8).write(to: file, options: .atomic)
            }
            await shop.rememberFound(found, now: later)
            FoundPrintersStore.beforeWriteForTests = nil
            #expect(round == FoundPrintersStore.tries)
            #expect(try String(contentsOf: file, encoding: .utf8).contains(#""round":\#(round)"#), "a clobber after giving up")
            await shop.rememberFound(found, now: later)

            // A printer that moved still says where it was after the file is read back.
            let moved = try JSONDecoder().decode([KhaytEngine.FoundPrinter].self, from: Data(#"""
                [{"name":"U1","host":"192.168.1.77","port":7125,"serial":"SN1"}]
                """#.utf8))
            await shop.rememberFound(moved, now: later.addingTimeInterval(60))
            let after = await shop.rememberedPrinters(now: later.addingTimeInterval(120))
            let u1 = FoundPrintersTests.obj(try #require(after.first { FoundPrintersTests.obj($0)["serial"] == .string("SN1") }))
            #expect(u1["host"] == .string("192.168.1.77") && u1["previousHost"] == .string("192.168.1.20"))
            #expect(u1["vendor"] == .string("Snapmaker"), "a find that did not say the vendor blanked it")

            // WHAT THE SHEET SHOWS UNDER "SEEN EARLIER": a scan that sees only the Mini is told about the U1.
            let onlyMini = try JSONDecoder().decode([KhaytEngine.FoundPrinter].self,
                                                    from: Data(#"[{"name":"Mini","host":"192.168.1.21","port":80}]"#.utf8))
            let missed = await shop.earlierFinds(notIn: onlyMini, now: later.addingTimeInterval(180))
            #expect(missed.map(\.printer.name).contains("U1") && !missed.map(\.printer.name).contains("Mini"))
            let u1Row = try #require(missed.first { $0.printer.name == "U1" })
            #expect(u1Row.printer.host == "192.168.1.77" && u1Row.previousHost == "192.168.1.20" && u1Row.printer.serial == "SN1")
            // A scan that sees everything has nothing under it, and older than three days is gone.
            #expect(await shop.earlierFinds(notIn: moved + onlyMini, now: later.addingTimeInterval(180)).allSatisfy { $0.printer.name == "Theirs" })
            #expect(await shop.earlierFinds(notIn: [], now: later.addingTimeInterval(5 * 86400)).isEmpty)

            // Forget.
            shop.forgetFoundPrinters()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(await shop.rememberedPrinters(now: later).isEmpty)
            shop.forgetFoundPrinters()   // nothing to forget is not a failure
        }
    }
}
