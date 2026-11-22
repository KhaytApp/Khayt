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

            // Forget.
            shop.forgetFoundPrinters()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(await shop.rememberedPrinters(now: later).isEmpty)
            shop.forgetFoundPrinters()   // nothing to forget is not a failure
        }
    }
}
