import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What a print has been printed with, and printed as — crossing into the
/// engine and back.
///
/// The rules are `lib/print-setups.js` and `lib/print-versions.js`, pinned by
/// their own tests. These are about the CROSSING: that the derived verdict is
/// the module's and not a second opinion, that "nothing has worked yet" arrives
/// as an absence rather than a bad recommendation, and that a file which has
/// never heard of versions still reports one.
@MainActor
struct PrintSetupsTests {

    static func setup(_ id: String, name: String, ok: Int = 0, failed: Int = 0,
                      status: String? = nil, machine: String? = nil,
                      material: String? = nil, layer: Double? = nil,
                      nozzle: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name),
            "ok": .number(Double(ok)), "failed": .number(Double(failed)),
        ]
        if let status { o["status"] = .string(status) }
        if let machine { o["machineName"] = .string(machine) }
        if let material { o["material"] = .string(material) }
        if let layer { o["layerHeightMm"] = .number(layer) }
        if let nozzle { o["nozzleMm"] = .number(nozzle) }
        return .object(o)
    }

    static func file(setups: [JSONValue]) -> JSONValue {
        .object(["id": .string("F1"), "name": .string("Bracket"),
                 "setups": .array(setups)])
    }

    static func read(_ setups: [JSONValue]) async throws -> KhaytEngine.PrintSetups {
        try await KhaytEngine().printSetups(Self.file(setups: setups))
    }

    // MARK: - Setups

    @Test("a setup nobody has run is untested, not failed")
    func untried() async throws {
        // "Failed" against something never attempted tells the shop something
        // untrue, and it is the difference between "try this" and "do not".
        let out = try await Self.read([Self.setup("S1", name: "Draft on the MK4")])
        #expect(out.setups.first?.status == "needs-test")
        #expect(out.needsTest == 1)
        #expect(out.failed == 0)
        #expect(out.recommendedId == "S1", "untested is still worth reaching for")
    }

    @Test("one bad print does not condemn a setup")
    func rate() async throws {
        // Filament runs out, a spool tangles, somebody knocks the machine. What
        // matters is the rate, so nine of ten is still a setup to reach for.
        let out = try await Self.read([Self.setup("S1", name: "Nine of ten", ok: 9, failed: 1)])
        #expect(out.setups.first?.status == "known-good")
        #expect(out.knownGood == 1)
    }

    @Test("one success against three failures is not a good setup, however recent")
    func badRate() async throws {
        let out = try await Self.read([Self.setup("S1", name: "One of four", ok: 1, failed: 3)])
        #expect(out.setups.first?.status == "needs-test")
        #expect(out.knownGood == 0)
    }

    @Test("the shop's own verdict beats the record's")
    func override() async throws {
        // "It printed, but I did not like the finish" is a judgement no tally
        // can reach, so an override has to win over a perfect record.
        let out = try await Self.read([
            Self.setup("S1", name: "Looks wrong", ok: 10, failed: 0, status: "failed"),
        ])
        #expect(out.setups.first?.status == "failed")
        #expect(out.failed == 1)
    }

    @Test("known-good is recommended over untested, however many prints the untested has")
    func recommendation() async throws {
        let out = try await Self.read([
            Self.setup("S1", name: "Untested"),
            Self.setup("S2", name: "Proven", ok: 4, failed: 0),
        ])
        #expect(out.recommendedId == "S2")
    }

    @Test("nothing is recommended when every setup has failed")
    func nothingWorks() async throws {
        // Nil is the answer, not the least broken one: recommending a known
        // failure wastes a spool and a night, and what the shop needs to hear
        // is "change something".
        let out = try await Self.read([
            Self.setup("S1", name: "Warps", ok: 0, failed: 3),
            Self.setup("S2", name: "Also warps", ok: 0, failed: 2),
        ])
        #expect(out.recommendedId == nil)
        #expect(out.failed == 2)
    }

    @Test("the totals are the whole record, not the setups' count")
    func totals() async throws {
        let out = try await Self.read([
            Self.setup("S1", name: "A", ok: 3, failed: 1),
            Self.setup("S2", name: "B", ok: 2, failed: 0),
        ])
        #expect(out.total == 2)
        #expect(out.prints == 5)
        #expect(out.failures == 1)
    }

    @Test("the fields cross so the line can be written in the reader's language")
    func fields() async throws {
        // describeSetup composes English. This app is read in Arabic too, so
        // the parts cross and the sentence is built against the locale.
        let out = try await Self.read([
            Self.setup("S1", name: "Fine", ok: 1, machine: "Prusa CORE One",
                       material: "PLA", layer: 0.2, nozzle: 0.4),
        ])
        let s = try #require(out.setups.first)
        #expect(s.machineName == "Prusa CORE One")
        #expect(s.material == "PLA")
        #expect(s.layerHeightMm == 0.2)
        #expect(s.nozzleMm == 0.4)
    }

    @Test("a file with no setups is an answer, not a throw")
    func none() async throws {
        let out = try await Self.read([])
        #expect(out.setups.isEmpty)
        #expect(out.total == 0)
        #expect(out.recommendedId == nil)
    }

    // MARK: - Versions

    @Test("a file that has never heard of versions still reports one")
    func implicitVersion() async throws {
        // A print always HAS a version, it just usually has exactly one. That
        // keeps every caller free of "if it has versions" branching.
        let out = try await KhaytEngine().printVersions(.object([
            "id": .string("F1"), "sourceFile": .string("bracket.3mf"),
            "parsed": .object(["grams": .number(42), "hours": .number(1.5)]),
        ]))
        #expect(out.versions.count == 1)
        #expect(out.versions.first?.implicit == true,
                "the stand-in must be distinguishable from a real single version")
        #expect(out.many == false, "one version is not a choice to offer")
        #expect(out.versions.first?.grams == 42)
    }

    @Test("versions carry their own time and weight, which is the point of them")
    func realVersions() async throws {
        // Small and big cost different amounts, and a shop quoting from one
        // estimate would be wrong for both.
        let out = try await KhaytEngine().printVersions(.object([
            "id": .string("F1"),
            "activeVersionId": .string("v2"),
            "versions": .array([
                .object(["id": .string("v1"), "name": .string("Small"),
                         "parsed": .object(["grams": .number(30), "hours": .number(1)])]),
                .object(["id": .string("v2"), "name": .string("Large"),
                         "parsed": .object(["grams": .number(180), "hours": .number(7)])]),
            ]),
        ]))
        #expect(out.versions.count == 2)
        #expect(out.many)
        #expect(out.activeId == "v2", "the active one is what an estimate is about")
        #expect(out.versions.first(where: { $0.id == "v2" })?.grams == 180)
        #expect(out.versions.allSatisfy { !$0.implicit })
    }

    @Test("a file with no geometry at all has no versions to report")
    func nothingToVersion() async throws {
        let out = try await KhaytEngine().printVersions(.object(["id": .string("F1")]))
        #expect(out.versions.isEmpty)
        #expect(out.activeId == nil)
        #expect(out.many == false)
    }
}
