import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The library measured again after a reader fault is fixed.
///
/// The RULE — which reader wrote a record, and when it is due — is in
/// `lib/geometry-key.js`, tested where it lives. What is tested here is that
/// this app asks it: reads only what is due, rewrites only what changed,
/// marks everything it read, and leaves alone what it could not find.
@MainActor
struct RemeasureTests {

    static func vault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-remeasure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A 10 × 20 × 5 box under the record's own folder, the way the library keeps files.
    static func place(_ id: String, in vault: URL) throws {
        let dir = vault.appending(path: LibraryLocation.itemDirName(id))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try Mesh3MFTests.make3MF(in: dir, named: "box.3mf", w: 10, d: 20, h: 5)
    }
    static let boxKey = "12:1000:10x20x5"

    static func row(_ id: String, key: String?, reader: Int?, ext: String = "3mf") -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(id), "rev": .number(1),
            "sourceFile": .object(["filename": .string("box.\(ext)"), "ext": .string(ext)]),
        ]
        o["geometryKey"] = key.map(JSONValue.string) ?? .null
        if let reader { o["geometryReader"] = .number(Double(reader)) }
        return .object(o)
    }

    static func files(_ rows: [JSONValue]) throws -> [LibraryFile] {
        try rows.map { try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode($0)) }
    }

    static func object(_ v: JSONValue) -> [String: JSONValue] {
        if case .object(let o) = v { return o } else { return [:] }
    }

    /// stale: an older reader's key.  marked: this reader already read it, key as it is.
    /// absent: due, but not in the folder.  stl: never a 3MF's business.
    static let book: [JSONValue] = [
        row("PF-stale", key: "1:1:1x1x1", reader: nil),
        row("PF-marked", key: "1:1:1x1x1", reader: 2),
        row("PF-absent", key: nil, reader: nil),
        row("PF-stl", key: nil, reader: nil, ext: "stl"),
    ]

    @Test("what is due is decided by the reader that wrote the record, not by the key")
    func due() async throws {
        let engine = try KhaytEngine()
        let due = await Remeasure.due(try Self.files(Self.book), engine: engine).map(\.id)
        #expect(due == ["PF-stale", "PF-absent"], "\(due)")
    }

    @Test("reading finds the new key, and tells a missing file from an unreadable one")
    func measure() async throws {
        let engine = try KhaytEngine()
        let vault = try Self.vault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try Self.place("PF-stale", in: vault)
        // What the app reads: the due list, not the whole library.
        let due = await Remeasure.due(try Self.files(Self.book), engine: engine)
        let report = await Remeasure.measure(due, vault: vault, engine: engine)
        #expect(report.measured == ["PF-stale"])
        #expect(report.missing == ["PF-absent"], "\(report.missing)")
        #expect(report.unreadable.isEmpty)
        #expect(report.changed.count == 1)
        #expect(report.changed.first?.was == "1:1:1x1x1")
        #expect(report.changed.first?.now == Self.boxKey, "\(report.changed.first?.now ?? "-")")
    }

    @Test("the write replaces changed keys, stamps them, marks what was read, and leaves the rest")
    func apply() async throws {
        let engine = try KhaytEngine()
        let vault = try Self.vault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try Self.place("PF-stale", in: vault)
        try Self.place("PF-marked", in: vault)
        let files = try Self.files(Self.book)
        // The command reads everything; the app reads only what is due.
        let report = await Remeasure.measure(files, vault: vault, engine: engine)
        var root: [String: JSONValue] = ["printFiles": .array(Self.book)]
        Remeasure.apply(report, reader: try await engine.geometryReader(), to: &root)
        let rows = Shop.rows(root, "printFiles").map(Self.object)

        #expect(Shop.plainString(rows[0]["geometryKey"]) == Self.boxKey)
        #expect(Shop.plainNumber(rows[0]["geometryReader"]) == 2)
        #expect(Shop.plainNumber(rows[0]["rev"]) == 2, "a corrected key is an edit the other devices must see")
        #expect(Shop.plainString(rows[1]["geometryKey"]) == Self.boxKey, "the command reads marked files too")
        #expect(Shop.plainNumber(rows[1]["rev"]) == 2)
        #expect(rows[2]["geometryReader"] == nil, "a file not in the folder is not marked as read")
        #expect(Shop.plainNumber(rows[2]["rev"]) == 1)
        #expect(rows[3]["geometryReader"] == nil)
    }

    @Test("a due file that was right is marked and not rewritten, and is not due again")
    func rightAlready() async throws {
        let engine = try KhaytEngine()
        let vault = try Self.vault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try Self.place("PF-right", in: vault)
        let before = [Self.row("PF-right", key: Self.boxKey, reader: nil)]
        let report = await Remeasure.measure(try Self.files(before), vault: vault, engine: engine)
        #expect(report.changed.isEmpty)
        #expect(report.measured == ["PF-right"])
        var root: [String: JSONValue] = ["printFiles": .array(before)]
        Remeasure.apply(report, reader: try await engine.geometryReader(), to: &root)
        let after = Shop.rows(root, "printFiles")
        let row = Self.object(after[0])
        #expect(Shop.plainNumber(row["geometryReader"]) == 2)
        #expect(Shop.plainNumber(row["rev"]) == 1, "nothing changed, so nothing is an edit")
        #expect(await Remeasure.due(try Self.files(after), engine: engine).isEmpty)
    }

    @Test("the pass runs after the book loads, below the screen's priority, and the command shares it")
    func wired() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let shop = try String(contentsOf: sources.appending(path: "Shop.swift"), encoding: .utf8)
        let command = try String(contentsOf: sources.appending(path: "ImportCommand.swift"), encoding: .utf8)
        // In `load`, after the book's own reads, not before them.
        let load = shop.range(of: "func load(_ next: Source) async {")
        let call = shop.range(of: "remeasureIfDue()")
        let slicers = shop.range(of: "await readSlicers()")
        #expect(load != nil && call != nil && slicers != nil)
        if let load, let call, let slicers {
            #expect(load.lowerBound < slicers.lowerBound && slicers.lowerBound < call.lowerBound,
                    "the pass must start after the book has loaded")
        }
        #expect(shop.contains("Task.detached(priority: .utility)"), "not at the screen's priority")
        #expect(shop.contains("Remeasure.measure(") && command.contains("Remeasure.measure("),
                "one pass, two callers")
        #expect(shop.contains("Remeasure.apply(") && command.contains("Remeasure.apply("))
    }
}
