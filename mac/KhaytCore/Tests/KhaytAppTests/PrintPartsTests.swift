import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The files one print is made of, crossing into the engine and back.
///
/// The rule is `lib/print-file-parts.js`. Most of these are about the awkward
/// case it exists for: `sourceFile` and `files` are kept equal by everything in
/// this app, an older build's Identify writes one and not the other, and sync
/// merges whole records last-writer-wins — so a record arrives disagreeing with
/// itself and neither list can be trusted over the other.
@MainActor
struct PrintPartsTests {

    static func part(_ name: String, size: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["filename": .string(name)]
        if let size { o["size"] = .number(size) }
        return .object(o)
    }

    static func read(files: [JSONValue]? = nil, source: JSONValue? = nil) async throws
        -> KhaytEngine.PrintParts {
        var rec: [String: JSONValue] = ["id": .string("F1"), "name": .string("Spiderman")]
        if let files { rec["files"] = .array(files) }
        if let source { rec["sourceFile"] = source }
        return try await KhaytEngine().printParts(.object(rec))
    }

    @Test("a print of one file is not a kit")
    func single() async throws {
        let out = try await Self.read(source: Self.part("bracket.3mf", size: 1_200))
        #expect(out.parts.count == 1)
        #expect(out.multi == false, "one file is not something to draw a parts list for")
        #expect(out.primary == "bracket.3mf")
        #expect(out.totalSize == 1_200)
    }

    @Test("a kit reports every file, primary first")
    func kit() async throws {
        let out = try await Self.read(files: [
            Self.part("torso.stl", size: 4_000),
            Self.part("head.stl", size: 1_000),
            Self.part("arm-l.stl", size: 800),
            Self.part("arm-r.stl", size: 800),
        ], source: Self.part("torso.stl", size: 4_000))
        #expect(out.multi)
        #expect(out.parts.map(\.filename) == ["torso.stl", "head.stl", "arm-l.stl", "arm-r.stl"])
        #expect(out.primary == "torso.stl")
        #expect(out.totalSize == 6_600)
    }

    @Test("a record that disagrees with itself keeps both, and loses nothing")
    func disagreement() async throws {
        // The older build's Identify pointed `sourceFile` at a file it found on
        // that computer and never touched `files`. Preferring `files` would
        // drop the file somebody just chose; preferring `sourceFile` would drop
        // every other part of the kit.
        let out = try await Self.read(files: [
            Self.part("head.stl", size: 1_000),
            Self.part("torso.stl", size: 4_000),
        ], source: Self.part("chosen-on-this-mac.3mf", size: 9_000))
        #expect(out.parts.count == 3, "nothing may be dropped when the two lists disagree")
        #expect(out.parts.first?.filename == "chosen-on-this-mac.3mf",
                "the file somebody most recently pointed at is the one the card speaks for")
        #expect(out.parts.map(\.filename).contains("torso.stl"))
    }

    @Test("agreement is not a disagreement")
    func agreement() async throws {
        // `sourceFile` equal to `files[0]` is the ordinary case, and it must
        // not produce a duplicate first entry.
        let out = try await Self.read(files: [
            Self.part("head.stl", size: 1_000),
            Self.part("torso.stl", size: 4_000),
        ], source: Self.part("head.stl", size: 1_000))
        #expect(out.parts.count == 2)
        #expect(out.parts.map(\.filename) == ["head.stl", "torso.stl"])
    }

    @Test("a total that could not measure every part is no total at all")
    func unmeasured() async throws {
        // Summing what it can and presenting that as the size of the print
        // understates it, and nothing on screen would say so.
        let out = try await Self.read(files: [
            Self.part("head.stl", size: 1_000),
            Self.part("torso.stl"),
        ])
        #expect(out.parts.count == 2)
        #expect(out.totalSize == nil)
    }

    @Test("a record with no file at all has no parts")
    func none() async throws {
        let out = try await Self.read()
        #expect(out.parts.isEmpty)
        #expect(out.multi == false)
        #expect(out.primary == nil)
        #expect(out.totalSize == nil)
    }
}
