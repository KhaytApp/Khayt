import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The colour re-read after the beta.40 full review (stability area): a file
/// left unread is not marked read; a Mac that can hold a file another could
/// not reads it; the pass decodes on its own engine, stops on a book switch,
/// resolves files off the main actor, and writes rarely and silently.
@MainActor
struct ColoursRereadHardeningTests {

    static func file(_ o: [String: JSONValue]) throws -> LibraryFile {
        var r = o
        r["id"] = r["id"] ?? .string("pf1"); r["name"] = r["name"] ?? .string("Model")
        r["sourceFile"] = r["sourceFile"] ?? .object(["filename": .string("a.3mf"), "ext": .string("3mf")])
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(r)))
    }

    @Test("due: an older reader, or a budget smaller than this Mac's")
    func dueByBudget() throws {
        let gb = 1 << 30
        let current = try Self.file(["id": .string("now"), "coloursReader": .number(5)])
        let old = try Self.file(["id": .string("old"), "coloursReader": .number(4)])
        let small = try Self.file(["id": .string("small"), "coloursReader": .number(5),
                                   "coloursUnreadBudget": .number(Double(gb / 4))])
        let same = try Self.file(["id": .string("same"), "coloursReader": .number(5),
                                  "coloursUnreadBudget": .number(Double(gb))])
        let bigger = try Self.file(["id": .string("bigger"), "coloursReader": .number(5),
                                    "coloursUnreadBudget": .number(Double(2 * gb))])
        let due = ColoursReread.due([current, old, small, same, bigger], reader: 5, budget: gb).map(\.id)
        #expect(due == ["old", "small"], "a Mac that can hold more tries again; the same Mac does not every launch")
    }

    @Test("a read's fields: budget mark past the budget, file mark for any other unread, both cleared once named")
    func marking() throws {
        let applied: [String: JSONValue] = ["id": .string("pf1"), "colors": .array([]), "coloursReader": .number(5),
                                            "coloursUnreadBudget": .number(1), "coloursUnreadFile": .string("old:1")]
        let colours = KhaytEngine.Colours(colors: [], swapCount: 0, slotsKnown: false, reader: 5)
        var over = ColourRead.Read(colours: colours); over.paintUnread = true; over.overBudget = 500
        let o = ColoursReread.marked(applied, read: over, file: "10:20")
        #expect(o["coloursUnreadBudget"] == .number(500) && o["coloursUnreadFile"] == nil)
        var other = ColourRead.Read(colours: colours); other.paintUnread = true
        let f = ColoursReread.marked(applied, read: other, file: "10:20")
        #expect(f["coloursUnreadFile"] == .string("10:20") && f["coloursUnreadBudget"] == nil,
                "the triangle cap, a member that is not text: marked, not retried every launch")
        let named = ColourRead.Read(colours: KhaytEngine.Colours(colors: [], swapCount: 0, slotsKnown: true, reader: 5))
        let n = ColoursReread.marked(applied, read: named, file: "10:20")
        #expect(n["coloursUnreadBudget"] == nil && n["coloursUnreadFile"] == nil)
        let failed = ColoursReread.failed(["id": .string("pf1"), "colors": .array([]), "coloursReader": .number(3)],
                                          reader: 5, file: "10:20")
        #expect(failed["coloursReader"] == .number(5) && failed["coloursUnreadFile"] == .string("10:20"))
        #expect(ColoursReread.fields.contains("coloursUnreadBudget") && ColoursReread.fields.contains("coloursUnreadFile"),
                "the compare-and-set covers both marks")
    }

    @Test("a file mark makes the record a candidate; the pass skips it while the file is unchanged")
    func fileMark() throws {
        let marked = try Self.file(["id": .string("m"), "coloursReader": .number(5), "coloursUnreadFile": .string("10:20")])
        #expect(ColoursReread.due([marked], reader: 5, budget: 1 << 30).map(\.id) == ["m"])
        let d = FileManager.default.temporaryDirectory.appending(path: "khayt-sig-\(UUID().uuidString).3mf")
        try Data("abc".utf8).write(to: d)
        defer { try? FileManager.default.removeItem(at: d) }
        let sig = try #require(ColoursReread.signature(d))
        #expect(sig.hasPrefix("3:"))
        try Data("abcd".utf8).write(to: d)
        #expect(ColoursReread.signature(d) != sig, "a changed file is a different signature")
        let src = MenuCoverageTests.source("ColoursReread.swift")
        #expect(src.contains("file.coloursUnreadFile == sig"))
        #expect(src.contains("Date().timeIntervalSince(lastWrite) >= ColoursReread.writeEvery"))
        #expect(ColoursReread.writeEvery == 120)
    }

    @Test("past the budget is told from the entries alone, each at the larger of its sizes")
    func pastBudget() {
        let m = { (n: String, s: Int, c: Int) in Zip.Entry(name: n, compressedSize: c, size: s, method: 8, offset: 0) }
        #expect(!ColourRead.pastBudget([m("3D/a.model", 100, 10), m("3D/b.model", 100, 10)], memberLimit: 100, totalLimit: 200))
        #expect(ColourRead.pastBudget([m("3D/a.model", 101, 10)], memberLimit: 100, totalLimit: 1000))
        #expect(ColourRead.pastBudget([m("3D/a.model", 1, 101)], memberLimit: 100, totalLimit: 1000), "the packed size counts")
        #expect(ColourRead.pastBudget([m("3D/a.model", 100, 1), m("3D/b.model", 100, 1)], memberLimit: 100, totalLimit: 199))
        #expect(!ColourRead.pastBudget([m("Metadata/thumb.png", 10_000, 10_000)], memberLimit: 100, totalLimit: 100),
                "only model files count")
    }

    @Test("the pass: its own engine, stops on a book switch, off the main actor, rare and silent writes")
    func wired() {
        let src = MenuCoverageTests.source("ColoursReread.swift")
        #expect(src.contains("guard let studio = await PinWork.run({ try? StudioEngine() })"))
        #expect(src.contains("ColourRead.read(url, entries: entries, engine: engine, studio: studio)"))
        #expect(src.contains("coloursRereading?.cancel()") && src.contains("coloursRereading = Task(priority: .utility) { [weak self] in"))
        #expect(src.contains("guard !Task.isCancelled, let now = self?.source else { return false }"))
        #expect(src.contains("guard now == source else { return }\n            await self.load(now)"), "reload only the book it read")
        #expect(src.contains("Shop.modelFile(for: file, roots: roots)") && !src.contains("self.modelFile(for: file)"))
        #expect(src.contains("recordingDeletes: false,\n                        announce: false"))
        #expect(ColoursReread.batch == 100)
        let writer = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/StoreWriter.swift"), encoding: .utf8)) ?? ""
        #expect(writer.contains("if announce { Task { @MainActor in StoreWriter.didWrite?(url) } }"))
        #expect(MenuCoverageTests.source("Remeasure.swift").contains("await PinWork.run({ try? Mesh.measure3MF(model) })"))
    }
}
