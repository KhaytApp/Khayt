import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A library record's colours are the slots the print USES (reader 2, #2500),
/// read on the Mac the way the desktop reads them.
///
/// The 3MFs are synthetic (`test/fixtures/library-colours/make.js`) and
/// `expected.json` is what `lib/thumbnail-extract.js colours3mf` says under
/// node; the Mac's own path (a streamed paint check, the mesh through
/// `mf-mesh`, the configs) must name the same colours.
@MainActor
struct ColourReadTests {

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Tests/KhaytAppTests
        .deletingLastPathComponent()   // …/Tests
        .deletingLastPathComponent()   // …/KhaytCore
        .deletingLastPathComponent()   // …/mac
        .deletingLastPathComponent()   // the repository root
        .appending(path: "test/fixtures/library-colours")

    struct Expected: Decodable { let hexes: [String]; let swapCount: Int; let slotsKnown: Bool; let reader: Int }

    static func expected() throws -> [String: Expected] {
        try JSONDecoder().decode([String: Expected].self,
                                 from: Data(contentsOf: fixtures.appending(path: "expected.json")))
    }

    static func hexes(_ colours: [JSONValue]) -> [String] {
        colours.compactMap { if case .object(let o) = $0, case .string(let h)? = o["hex"] { return h }; return nil }
    }

    @Test("each synthetic 3MF names the colours the desktop's rule names")
    func fixturesAgree() async throws {
        let engine = try KhaytEngine()
        let want = try Self.expected()
        #expect(want.count == 3)
        for (name, w) in want {
            let url = Self.fixtures.appending(path: name)
            let entries = try Zip.entries(of: url)
            let read = try #require(await ColourRead.colours(url, entries: entries, engine: engine), Comment(rawValue: name))
            #expect(Self.hexes(read.colors) == w.hexes, Comment(rawValue: name))
            #expect(read.swapCount == w.swapCount, Comment(rawValue: name))
            #expect(read.slotsKnown == w.slotsKnown, Comment(rawValue: name))
            #expect(read.reader == w.reader, Comment(rawValue: name))
        }
    }

    @Test("the paint check: a painted model is found, an unpainted one is not")
    func paintCheck() throws {
        for (name, painted) in [("painted-1-2-5.3mf", true), ("unpainted-slot4.3mf", false)] {
            let url = Self.fixtures.appending(path: name)
            #expect(ColourRead.painted(try Zip.entries(of: url), in: url) == painted, Comment(rawValue: name))
        }
        #expect(ColourRead.contains(Array("a paint_color=\"4\"".utf8), Array("paint_color=".utf8)))
        #expect(!ColourRead.contains(Array("paint_colo".utf8), Array("paint_color=".utf8)))
    }

    @Test("print facts: the slots an unsliced project uses")
    func usedSlots() async throws {
        let engine = try KhaytEngine()
        let url = Self.fixtures.appending(path: "painted-1-2-5.3mf")
        let entries = try Zip.entries(of: url)
        let c = ColourRead.configs(entries, in: url)
        #expect(await ColourRead.usedSlots(url, entries: entries, configs: c, engine: engine) == [1, 2, 5])
        let sliced = Self.fixtures.appending(path: "sliced.3mf")
        let se = try Zip.entries(of: sliced)
        #expect(await ColourRead.usedSlots(sliced, entries: se, configs: ColourRead.configs(se, in: sliced),
                                           engine: engine) == nil, "a sliced file names its own colours")
    }

    // MARK: - Putting a re-read on a record (KhaytThumb.applyColours)

    static let red: JSONValue = .object(["hex": .string("#E23D3D"), "grams": .number(12.5), "label": .string("Filament 1")])
    static let blue: JSONValue = .object(["hex": .string("#2F6FE0"), "grams": .null, "label": .string("Filament 2")])

    @Test("a read naming the used slots replaces the loaded ones, keeps a slice's grams, leaves updatedAt")
    func applyNamed() async throws {
        let engine = try KhaytEngine()
        let rec: [String: JSONValue] = ["id": .string("pf1"), "colors": .array([Self.red, Self.blue]),
                                        "swapCount": .number(3), "updatedAt": .string("U")]
        let read = KhaytEngine.Colours(colors: [.object(["hex": .string("#E23D3D"), "grams": .null, "label": .string("Filament 1")])],
                                       swapCount: 0, slotsKnown: true, reader: 2)
        let out = try await engine.applyColours(rec, read: read)
        #expect(out.changed)
        #expect(out.record["colors"] == .array([Self.red]))
        #expect(out.record["swapCount"] == .number(0))
        #expect(out.record["coloursReader"] == .number(2))
        #expect(out.record["updatedAt"] == .string("U"))
    }

    @Test("a read that cannot name the slots stamps the reader and never empties the colours")
    func applyUnknown() async throws {
        let engine = try KhaytEngine()
        let rec: [String: JSONValue] = ["id": .string("pf1"), "colors": .array([Self.red, Self.blue]), "swapCount": .number(1)]
        let out = try await engine.applyColours(rec, read: .init(colors: [], swapCount: 0, slotsKnown: false, reader: 2))
        #expect(out.changed)
        #expect(out.record["colors"] == .array([Self.red, Self.blue]))
        #expect(out.record["swapCount"] == .number(1))
        #expect(out.record["coloursReader"] == .number(2))
        let again = try await engine.applyColours(out.record, read: .init(colors: [], swapCount: 0, slotsKnown: false, reader: 2))
        #expect(!again.changed)
    }

    // MARK: - The re-read's write

    @Test("the re-read writes only the four colour fields, only to records it read, and only where they did not change meanwhile")
    func rereadPatch() {
        let rows: [JSONValue] = [
            .object(["id": .string("a"), "name": .string("kept"), "colors": .array([Self.red, Self.blue]),
                     "swapCount": .number(3), "notes": .string("typed meanwhile")]),
            .object(["id": .string("b"), "colors": .array([Self.blue])]),
            // Its colours changed after the file was read (a slice's figures, a pull).
            .object(["id": .string("c"), "colors": .array([Self.red]), "swapCount": .number(5)]),
        ]
        let now: [String: JSONValue] = ["colors": .array([Self.red]), "swapCount": .number(0), "coloursReader": .number(2)]
        let patches: [String: ColoursReread.Patch] = [
            "a": .init(was: ["colors": .array([Self.red, Self.blue]), "swapCount": .number(3)], now: now),
            "c": .init(was: ["colors": .array([Self.blue]), "swapCount": .number(1)], now: now),
        ]
        let out = ColoursReread.apply(patches, to: rows)
        #expect(out.written == 1)
        guard case .object(let a) = out.rows[0] else { Issue.record("not an object"); return }
        #expect(a["colors"] == .array([Self.red]))
        #expect(a["swapCount"] == .number(0))
        #expect(a["coloursReader"] == .number(2))
        #expect(a["swapsKnown"] == nil)
        #expect(a["notes"] == .string("typed meanwhile"), "an edit to another field is kept")
        #expect(a["name"] == .string("kept"))
        #expect(out.rows[1] == rows[1], "not read: untouched")
        #expect(out.rows[2] == rows[2], "changed since it was read: untouched, and due again next launch")
    }

    static func file(_ o: [String: JSONValue]) throws -> LibraryFile {
        var r = o
        r["id"] = r["id"] ?? .string("pf1"); r["name"] = r["name"] ?? .string("Snoopy")
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(r)))
    }

    @Test("due: a 3MF below reader 2, or with none, and nothing else")
    func due() throws {
        let threeMF: JSONValue = .object(["filename": .string("a.3mf"), "ext": .string("3mf")])
        let stl: JSONValue = .object(["filename": .string("a.stl"), "ext": .string("stl")])
        let old = try Self.file(["id": .string("old"), "sourceFile": threeMF])
        let one = try Self.file(["id": .string("one"), "sourceFile": threeMF, "coloursReader": .number(1)])
        let now = try Self.file(["id": .string("now"), "sourceFile": threeMF, "coloursReader": .number(2)])
        let mesh = try Self.file(["id": .string("stl"), "sourceFile": stl])
        #expect(ColoursReread.due([old, one, now, mesh], reader: 2).map(\.id) == ["old", "one"])
    }

    // MARK: - What the card says on hover

    @Test("the card: the number only for a sliced file with swaps; an unsliced file's dots say swaps come with slicing")
    func cardTips() throws {
        let words = Words()
        let sliced = try Self.file(["colors": .array([Self.red, Self.blue, Self.red]), "swapCount": .number(2),
                                    "swapsKnown": .bool(true)])
        #expect(PaletteTips.colours(sliced, words) == "Colours: 3. The filaments this print uses.")
        #expect(PaletteTips.swaps(sliced, words)
                == "Filament swaps: about 2. How many times the printer changes filament during this print, from the sliced file.")
        let unsliced = try Self.file(["colors": .array([Self.blue]), "swapCount": .number(0), "swapsKnown": .bool(false)])
        #expect(PaletteTips.colours(unsliced, words)
                == "Colours: 1. The filaments this print uses.\nFilament swaps are known once the file is sliced.")
        #expect(PaletteTips.swaps(unsliced, words) == nil, "no number for swaps no slicer counted")
        // An older record with no swapsKnown: a print time says it was sliced (#2502's rule).
        let oldSliced = try Self.file(["colors": .array([Self.red]), "swapCount": .number(0),
                                       "parsed": .object(["printTimeMins": .number(42)])])
        #expect(oldSliced.swapsKnownGuess)
        #expect(PaletteTips.swaps(oldSliced, words) == nil, "a sliced file with no swaps shows no number")
        let oldUnsliced = try Self.file(["colors": .array([Self.blue]), "swapCount": .number(0)])
        #expect(!oldUnsliced.swapsKnownGuess)
    }
}
