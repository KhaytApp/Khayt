import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What a printer needs from a person, worked out on the Mac by the shared
/// rules and handed to the phone and the cloud: its problems (C3,
/// `lib/printer-problems.js`; a U1's exceptions and power loss, U1 idea 5) and
/// why it waits at the machine (C4, `lib/waiting-at-machine.js`).
@Suite(.serialized) @MainActor
struct PrinterNeedsTests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }
    static func cases(_ file: String) throws -> [[String: JSONValue]] {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "test/fixtures/\(file)")))
        guard case .array(let cases)? = obj(v)["cases"] else { return [] }
        return cases.map(obj)
    }
    static func why(_ c: [String: JSONValue]) -> Comment {
        if case .string(let s)? = c["why"] { return Comment(rawValue: s) }
        return "?"
    }
    static let engine = OperatorLockTests.sharedEngine

    @Test("the shared problem vectors, through the Mac's engine")
    func problemVectors() async throws {
        let cases = try Self.cases("printer-problems-vectors.json")
        #expect(cases.count >= 15)
        for c in cases {
            guard case .string(let type)? = c["type"] else { Issue.record("no type"); continue }
            #expect(try await Self.engine.problemsFor(type: type, report: c["report"] ?? .null) == c["want"], Self.why(c))
        }
    }

    @Test("the shared waiting vectors, through the Mac's engine")
    func waitingVectors() async throws {
        let cases = try Self.cases("waiting-at-machine-vectors.json")
        #expect(cases.count >= 11)
        for c in cases {
            #expect(try await Self.engine.waitingAtMachine(machine: c["machine"] ?? .null, opts: c["opts"] ?? .null) == c["want"], Self.why(c))
        }
    }

    static func machine(_ id: String, type: String = "moonraker", _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "printerApi": .object(["type": .string(type)])]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("needs per printer: polled problems, a state word, a stored completion, and nothing for a printer never linked")
    func needs() async throws {
        let runout: JSONValue = .object(["code": .string("filament-runout"), "severity": .string("serious"),
                                         "action": .string("load-filament"), "source": .string("moonraker"), "head": .number(1)])
        let machines = [Self.machine("u1"), Self.machine("prusa", type: "prusalink"), Self.machine("done"),
                        Self.machine("auto", ["clearsOwnBed": .bool(true)]), Self.machine("quiet"),
                        Self.machine("bambu", type: "bambu"), .object(["id": .string("shelf")])]
        let cache: [String: JSONValue] = [
            "u1": .object(["state": .string("paused")]),
            "prusa": .object(["state": .string("ATTENTION"), "message": .string("Check the sheet")]),
            "done": .object(["state": .string("standby")]),
            "auto": .object(["state": .string("standby")]),
            "quiet": .object(["state": .string("offline"), "error": .string("no answer"), "consecutiveFailures": .number(3)]),
            "bambu": .object(["state": .string("Failed")]),
        ]
        let finished: JSONValue = .array([.object(["at": .number(1_795_114_800_000), "result": .string("finished")])])
        let completions: JSONValue = .object(["done": finished, "auto": finished, "quiet": .object(["completions": finished])])
        let orders: [JSONValue] = [.object(["id": .string("J1"), "machineId": .string("prusa"),
                                            "completedAt": .string("2026-11-18T10:00:00Z")])]
        let needs = try await Self.engine.printerNeeds(machines: machines, cache: cache, polled: ["u1": [runout]],
                                                       completions: completions, orders: orders)
        // The poll's own findings are passed on as they came, and the runout waits for a person.
        #expect(needs["u1"]?.problems == [runout])
        #expect(Self.obj(needs["u1"]?.waiting.first)["reason"] == .string("filament-runout"))
        // A state word that asks for someone, with the printer's sentence.
        let attention = Self.obj(needs["prusa"]?.problems.first)
        #expect(attention["code"] == .string("printer-attention") && attention["message"] == .string("Check the sheet"))
        #expect(needs["prusa"]?.waiting.map { Self.obj($0)["reason"] } == [.string("printer-attention"), .string("print-to-take-off")],
                "the book's last finished job counts when the poll kept none")
        // A print finished and the bed was not cleared since.
        #expect(needs["done"]?.problems.isEmpty == true)
        #expect(needs["done"]?.waiting == [.object(["reason": .string("print-to-take-off"), "since": .number(1_795_114_800_000)])])
        // A machine that clears its own bed never waits for one.
        #expect(needs["auto"]?.waiting.isEmpty == true)
        // Not answering: no live problems, but what is stored still says it waits.
        #expect(needs["quiet"]?.problems.isEmpty == true)
        #expect(Self.obj(needs["quiet"]?.waiting.first)["reason"] == .string("print-to-take-off"))
        // A Bambu's faults are its poll's to give; a state word alone invents none.
        #expect(needs["bambu"]?.problems.isEmpty == true)
        #expect(needs["shelf"] == nil, "a machine Khayt does not poll has no needs")
    }

    @Test("a U1 is asked for its problem objects only when it lists them, by exact name")
    func problemObjects() {
        func list(_ names: [String]) -> [String: JSONValue] {
            ["result": .object(["objects": .array(names.map(JSONValue.string))])]
        }
        #expect(KhaytEngine.moonrakerProblemObjects(in: list(["print_stats", "exception_manager", "power_loss_check", "power_loss_check e0"]))
                == ["exception_manager", "power_loss_check"])
        #expect(KhaytEngine.moonrakerProblemObjects(in: list(["print_stats", "extruder"])).isEmpty, "a plain Klipper printer is never asked")
        #expect(KhaytEngine.moonrakerProblemObjects(in: list(["exception_manager&gcode_move", "POWER_LOSS_CHECK"])).isEmpty)
        #expect(KhaytEngine.moonrakerProblemObjects(in: [:]).isEmpty)
        #expect(KhaytEngine.moonrakerProblemObjects == ["exception_manager", "power_loss_check"])
    }

    @Test("a U1's reply with an exception and a power loss becomes problems on its status; a plain reply has none")
    func moonrakerProblems() async throws {
        func reply(_ extra: [String: JSONValue]) -> [String: JSONValue] {
            var status: [String: JSONValue] = [
                "print_stats": .object(["state": .string("paused"), "filename": .string("plate.gcode")]),
                "virtual_sdcard": .object(["progress": .number(0.4)]),
            ]
            for (k, v) in extra { status[k] = v }
            return ["result": .object(["status": .object(status)])]
        }
        let u1 = try await Self.engine.moonrakerStatus(reply([
            "exception_manager": .object(["exceptions": .array([.object([
                "id": .number(523), "index": .number(1), "code": .number(0), "level": .number(2),
                "message": .string("e1_filament runout")])])]),
            "power_loss_check": .object(["power_loss_flag": .bool(true)]),
        ]), hot: nil, hotName: nil)
        let codes = (u1.problems ?? []).map { Self.obj($0)["code"] }
        #expect(codes.contains(.string("filament-runout")) && codes.contains(.string("power-lost")), "\(codes)")
        let plain = try await Self.engine.moonrakerStatus(reply([:]), hot: nil, hotName: nil)
        #expect(plain.problems == [], "a paused print with nothing wrong reported has no problems")
    }

    @Test("the live row carries the needs as they are, and the cache entry the printer's own sentence")
    func liveRow() throws {
        let problem: JSONValue = .object(["code": .string("power-lost"), "severity": .string("info")])
        let wait: JSONValue = .object(["reason": .string("print-to-take-off"), "since": .number(1)])
        let row = LanServer.liveRow(id: "M-1", name: "U1", apiType: "moonraker", reading: nil,
                                    needs: .init(problems: [problem], waiting: [wait]))
        #expect(Self.obj(row)["problems"] == .array([problem]) && Self.obj(row)["waiting"] == .array([wait]))
        let status = try JSONDecoder().decode(KhaytEngine.PrinterStatus.self, from: Data("""
        {"state":"ATTENTION","progress":0,"filename":"","type":"prusalink","message":"Check the sheet"}
        """.utf8))
        #expect(PrinterWatch.cacheEntry(status, at: Date())["message"] == .string("Check the sheet"))
        #expect(status.problems == nil, "a status with no problems key decodes: older readings stay readable")
    }

    @Test("the RFID tray and time-lapse rules are bundled and answer through the engine")
    func bundled() async throws {
        let js = Self.root.appending(path: "mac/KhaytCore/Sources/KhaytCore/JS")
        for name in ["moonraker-problems", "printer-problems", "waiting-at-machine", "rfid-tray", "timelapse-attach"] {
            #expect(FileManager.default.fileExists(atPath: js.appending(path: name + ".js").path), Comment(rawValue: name))
        }
        // No tag in any head: nothing is claimed.
        let none = try await Self.engine.rfidTrays(.object(["info": .array([])]))
        if case .array(let trays) = none { #expect(trays.allSatisfy { $0 == .null }) } else { #expect(none == .null || none == .array([])) }
    }
}
