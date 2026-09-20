import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What a filament wants to be printed at.
///
/// `lib/spool-edit.js` has stored `printTemp`, `bedTemp` and `maxSpeed` since
/// it was written, and this app decoded all three and had a field for none —
/// so a shop working here could not write down the one thing it looks up every
/// time a new spool goes on the machine. Neither book in the repository
/// carries a single temperature, which is what that looks like from the
/// outside: not a shop that declined to record them, one that could not.
@MainActor
struct SpoolTempTests {

    static func spool(_ o: [String: JSONValue]) throws -> Spool {
        var row = o
        row["id"] = .string("SP-T")
        row["material"] = .string("PLA")
        return try JSONDecoder().decode(Spool.self,
                                        from: JSONEncoder().encode(JSONValue.object(row)))
    }

    @Test("the rule stores what was typed, and stores nothing for an empty box")
    func theRuleKeepsThem() async throws {
        let engine = try KhaytEngine()
        let existing = JSONValue.object(["id": .string("SP-T"), "material": .string("PLA"),
                                         "weight": .number(1000)])
        let saved = try await engine.editSpool(
            existing,
            input: ["material": .string("PLA"), "printTemp": .number(215),
                    "bedTemp": .number(60), "maxSpeed": .number(120)],
            settings: [:], today: "2026-09-20")
        let spool = try #require(saved.spool)
        guard case .object(let row) = spool else { Issue.record("not an object"); return }
        #expect(row["printTemp"] == .number(215))
        #expect(row["bedTemp"] == .number(60))
        #expect(row["maxSpeed"] == .number(120))

        // Cleared, which is why the sheet sends a zero rather than leaving the
        // key out: absent means "leave it", zero means "there is no answer".
        let cleared = try await engine.editSpool(
            spool,
            input: ["material": .string("PLA"), "printTemp": .number(0),
                    "bedTemp": .number(0), "maxSpeed": .number(0)],
            settings: [:], today: "2026-09-20")
        guard case .object(let after) = try #require(cleared.spool) else { Issue.record("not an object"); return }
        #expect(after["printTemp"] == nil, "an emptied box left the old temperature behind")
        #expect(after["bedTemp"] == nil)
    }

    @Test("a spool that carries them reads them back")
    func decoded() throws {
        let spool = try Self.spool(["printTemp": .number(240), "bedTemp": .number(80),
                                    "maxSpeed": .number(300)])
        #expect(spool.printTemp == 240)
        #expect(spool.bedTemp == 80)
        #expect(spool.maxSpeed == 300)
    }

    @Test("a spool that carries none says nothing rather than zero")
    func absentIsNotZero() throws {
        // Nil, not 0. A bed temperature of 0°C is a claim about the filament;
        // absent is the truth, which is that nobody has said.
        let spool = try Self.spool([:])
        #expect(spool.printTemp == nil)
        #expect(spool.bedTemp == nil)
        #expect(spool.maxSpeed == nil)
    }

    @Test("the sheet offers all three, and sends them")
    func wired() throws {
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/SpoolSheet.swift"), encoding: .utf8)
        for key in ["inv.print_temp", "inv.bed_temp", "inv.max_speed"] {
            #expect(sheet.contains(key), Comment(rawValue: "\(key) has no field"))
        }
        for field in ["\"printTemp\": .number(printTemp)",
                      "\"bedTemp\": .number(bedTemp)",
                      "\"maxSpeed\": .number(maxSpeed)"] {
            #expect(sheet.contains(field), Comment(rawValue:
                "the sheet draws a box for \(field) and does not send what is in it"))
        }
        // The words are the other app's — nine languages rather than two.
        #expect(!sheet.contains("\"mac.print_temp\""),
                "a Mac-only word was written where a shared one exists")
    }
}
