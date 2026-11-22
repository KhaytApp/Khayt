import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac app must file a model where Khayt files it.
///
/// `lib/organise.js` is bundled and runs here, so the rule that matters — a name
/// matching one already in use IS that name and adopts its spelling — is shared
/// rather than copied. Only the cheap read is written twice, because asking a
/// JSContext for the group of every row to draw a sidebar of four hundred models
/// is a call per row for an answer that is two field reads.
///
/// So the read is held to the original here. Getting it backwards would file a
/// king under one name on a Mac and another on the machine beside it.
struct OrganiseParityTests {

    /// Records, as JS object literals, covering every shape the two fields take.
    static let records: [String] = [
        "{}",
        "{group:'Saudi Kings'}",
        "{folder:'Saudi Kings'}",
        // Both, agreeing — every record either app has written.
        "{group:'Saudi Kings', folder:'Saudi Kings'}",
        // Both, DISAGREEING. Two machines, one on an older build. `folder` wins,
        // and that is the whole reason this test exists.
        "{group:'Dental', folder:'Saudi Kings'}",
        "{group:'Saudi Kings', folder:''}",
        "{group:'', folder:'Dental'}",
        "{group:'   ', folder:'   '}",
        "{folder:'  Saudi   Kings  '}",
        "{group:null, folder:null}",
        "{folder:'Kings\\u0000'}",
        "{group:'A'.repeat(200)}",
        "{folder:'العائلة المالكة'}",
    ]

    @Test("Swift reads a record's group the way KhaytOrganise does")
    func groupOfMatches() async throws {
        let engine = try KhaytEngine()
        for literal in Self.records {
            let value = try await engine.raw("(\(literal))", as: JSONValue.self)
            let theirs = try await engine.groupOf(value)

            let data = try JSONEncoder().encode(value)
            let file = try JSONDecoder().decode(Probe.self, from: data)
            // The real code path, not a restatement of it here.
            let mine = LibraryFile.groupName(folder: file.folder, group: file.group) ?? ""

            #expect(mine == theirs, "\(literal): Swift \(mine.debugDescription), JS \(theirs.debugDescription)")
        }
    }

    /// Just the two fields, decoded as leniently as `LibraryFile` does.
    struct Probe: Decodable { let group: String?; let folder: String? }

    @Test("filing under a name the shop already uses adopts its spelling")
    func unifiesSpelling() async throws {
        let engine = try KhaytEngine()
        let patch = try await engine.fileUnderGroup("saudi kings", known: ["Saudi Kings", "Dental"])
        // Both fields, both the existing spelling. Either half missing is a bug:
        // one leaves older builds blind to the change, the other splits one
        // collection into two chips that each hold part of it.
        #expect(patch["group"] == .string("Saudi Kings"))
        #expect(patch["folder"] == .string("Saudi Kings"))
    }

    @Test("a name the shop has not used is kept exactly as typed")
    func keepsNewNames() async throws {
        let engine = try KhaytEngine()
        let patch = try await engine.fileUnderGroup("  Falcon   Hoods ", known: ["Saudi Kings"])
        #expect(patch["group"] == .string("Falcon Hoods"), "whitespace is collapsed, the name is not")
    }

    @Test("clearing a group empties both fields")
    func clearing() async throws {
        let engine = try KhaytEngine()
        let patch = try await engine.fileUnderGroup("", known: ["Saudi Kings"])
        #expect(patch["group"] == .string(""))
        #expect(patch["folder"] == .string(""), "leaving folder set would re-file it on the next read")
    }

    @Test("the sidebar's group list is the one Khayt would show")
    func countsMatch() async throws {
        let engine = try KhaytEngine()
        let records: [JSONValue] = [
            .object(["group": .string("Saudi Kings")]),
            .object(["folder": .string("Saudi Kings")]),
            .object(["group": .string("saudi kings")]),   // same group, typed differently
            .object(["group": .string("Dental")]),
            .object([:]),
        ]
        let counts = try await engine.groupCounts(records)
        #expect(counts.first?.name == "Saudi Kings")
        #expect(counts.first?.count == 3, "a differently-typed spelling is the same group")
        #expect(counts.count == 2, "the ungrouped record is not a group")
    }
}
