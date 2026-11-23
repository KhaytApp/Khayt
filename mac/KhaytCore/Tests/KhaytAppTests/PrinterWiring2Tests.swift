import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The rest of printer batches 2 and 3 on the Mac, with no new screens: the
/// poll steps aside for a person's command (C6, `lib/poll-yield.js`), one
/// result per print run (P4, `lib/run-result.js`), and a card leaves out what
/// its model cannot do (C5, `lib/printer-capabilities.js`).
@Suite(.serialized) @MainActor
struct PrinterWiring2Tests {

    static func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/KhaytApp")

    // MARK: - C6: the poll yields

    @Test("a command in flight: the printer is left alone, its seq moves, and a late reply after a release ends nothing")
    func pollYield() async throws {
        let engine = try KhaytEngine()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let id = "M-yield"
        var state = try await engine.pollYieldState(id, now: t0)
        #expect(!state.yielding && state.seq == 0 && !state.justSettled)

        let first = try await engine.pollYieldBegin(id, now: t0)
        state = try await engine.pollYieldState(id, now: t0.addingTimeInterval(1))
        #expect(state.yielding && state.seq == 1)
        #expect(try await engine.pollYieldState("M-other", now: t0).yielding == false, "other printers are polled as usual")

        try await engine.pollYieldEnd(id, token: first, now: t0.addingTimeInterval(2))
        state = try await engine.pollYieldState(id, now: t0.addingTimeInterval(2.5))
        #expect(!state.yielding && state.justSettled, "asked again right after the reply")
        #expect(try await engine.pollYieldState(id, now: t0.addingTimeInterval(30)).justSettled == false)

        // A command that never answers releases its printer; its late reply
        // does not end a newer command.
        let hung = try await engine.pollYieldBegin(id, now: t0.addingTimeInterval(40))
        #expect(try await engine.pollYieldState(id, now: t0.addingTimeInterval(61)).yielding == false, "never for ever")
        let newer = try await engine.pollYieldBegin(id, now: t0.addingTimeInterval(62))
        try await engine.pollYieldEnd(id, token: hung, now: t0.addingTimeInterval(63))
        #expect(try await engine.pollYieldState(id, now: t0.addingTimeInterval(63)).yielding, "the late reply ended nothing")
        try await engine.pollYieldEnd(id, token: newer, now: t0.addingTimeInterval(64))
        #expect(try await engine.pollYieldState(id, now: t0.addingTimeInterval(64)).yielding == false)
        #expect(try await engine.pollYieldState(id, now: t0.addingTimeInterval(64)).seq == 3)
    }

    @Test("every command a person sends goes through the yield, and every poll asks it")
    func commandsYield() throws {
        let printers = try String(contentsOf: Self.sources.appending(path: "Shop+Printers.swift"), encoding: .utf8)
        for call in ["PrinterControl.send(verb, to: machine", "PrinterControl.control(control, to: machine",
                     "PrinterSend.send(file, to: machine", "PrinterControl.drop(object, on: machine"] {
            let at = try #require(printers.range(of: call), Comment(rawValue: call))
            let before = printers[..<at.lowerBound].suffix(120)
            #expect(before.contains("printers.commanding(machine, shop: self)"), Comment(rawValue: call))
        }
        let phone = try String(contentsOf: Self.sources.appending(path: "Shop+PhonePrinter.swift"), encoding: .utf8)
        #expect(phone.contains("printers.commanding(machine, shop: self)"), "a phone's pause or stop is a person's command too")
        let watch = try String(contentsOf: Self.sources.appending(path: "PrinterWatch.swift"), encoding: .utf8)
        // Nothing records an answer that was not asked through the yield.
        let direct = watch.components(separatedBy: "await hear(machine, engine: engine, shop: shop)").count - 1
        #expect(direct == 1, "only hearUnlessCommanded asks a printer directly")
    }

    @Test("a poll's answer is dropped when a command went out while it was in flight")
    func staleAnswerDropped() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        let engine = try #require(shop.engine)
        let machine = try #require(shop.machines.first)
        let status = try JSONDecoder().decode(KhaytEngine.PrinterStatus.self, from: Data("""
        {"state":"printing","progress":42,"filename":"plate.gcode","type":"moonraker"}
        """.utf8))
        // The printer answers "printing"; while that answer is in flight, Pause is pressed.
        shop.printers.asking = { m, _, _, _ in
            _ = try await engine.pollYieldBegin(m.id)
            return status
        }
        shop.printers.setReadingForTesting(machine.id, .init(status: nil, problem: nil, at: Date()))
        await shop.printers.refresh(machine, shop: shop)
        #expect(shop.printers.readings[machine.id]?.status == nil, "the stale 'printing' was not recorded")
        // With no command in the way, the same answer is recorded.
        shop.printers.asking = { _, _, _, _ in status }
        // Release the command begun above, as its reply would.
        try await engine.pollYieldEnd(machine.id, token: nil)
        await shop.printers.refresh(machine, shop: shop)
        #expect(shop.printers.readings[machine.id]?.status?.state == "printing")
    }

    // MARK: - P4: one result per run

    static func job(_ runs: [JSONValue]) -> JSONValue { .object(["id": .string("J1"), "printRuns": .array(runs)]) }
    static func run(_ machine: String, at: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["machineId": .string(machine), "at": .string(at)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("the printer's result lands on the latest run on that machine, once, and never over the shop's own mark")
    func oneResultPerRun() async throws {
        let engine = OperatorLockTests.sharedEngine
        let end = Date(timeIntervalSince1970: 1_795_200_000)
        let before = StoreWriter.iso(end.addingTimeInterval(-3600)), earlier = StoreWriter.iso(end.addingTimeInterval(-90_000))
        let order = Self.job([Self.run("M1", at: earlier), Self.run("M2", at: before), Self.run("M1", at: before)])
        let written = try await engine.runsWithResult(order: order, machineId: "M1", at: end, result: "finished", source: "printer")
        guard case .array(let runs) = written else { Issue.record("nothing written"); return }
        #expect(Self.obj(runs[2])["result"] == .string("finished") && Self.obj(runs[2])["resultSource"] == .string("printer"))
        #expect(Self.obj(runs[0])["result"] == nil && Self.obj(runs[1])["result"] == nil, "only the run that just ended")
        // Asked again (a re-poll, a restart, the other app): nothing changes.
        #expect(try await engine.runsWithResult(order: Self.job(runs), machineId: "M1", at: end, result: "finished", source: "printer") == .null)
        #expect(try await engine.runsWithResult(order: Self.job(runs), machineId: "M1", at: end, result: "failed", source: "printer") == .null,
                "the printer's first word stands")
        // The shop said it failed: the printer's "finished" is kept beside it, not over it.
        let marked = Self.job([Self.run("M1", at: before, ["result": .string("failed"), "resultSource": .string("shop")])])
        let beside = try await engine.runsWithResult(order: marked, machineId: "M1", at: end, result: "finished", source: "printer")
        guard case .array(let kept) = beside else { Issue.record("nothing written"); return }
        #expect(Self.obj(kept[0])["result"] == .string("failed") && Self.obj(kept[0])["printerResult"] == .string("finished"))
        // No run on that machine before the end, an unknown result, or no runs: nothing.
        #expect(try await engine.runsWithResult(order: order, machineId: "M9", at: end, result: "finished", source: "printer") == .null)
        #expect(try await engine.runsWithResult(order: order, machineId: "M1", at: end, result: "unknown", source: "printer") == .null)
        #expect(try await engine.runsWithResult(order: .object(["id": .string("J")]), machineId: "M1", at: end, result: "finished", source: "printer") == .null)
    }

    @Test("a Bambu print the shop cancelled is cancelled, not a failure; an idle printer says nothing")
    func bambuCancelIsCancelled() async throws {
        let engine = OperatorLockTests.sharedEngine
        #expect(try await engine.printEndedAs(state: "Failed", fault: "The print was cancelled (0300_400C)") == "cancelled")
        #expect(try await engine.printEndedAs(state: "Failed", fault: "Cancelled from the printer (0500_400E)") == "cancelled")
        #expect(try await engine.printEndedAs(state: "Failed", fault: "Nozzle clog (0300_8003)") == "failed")
        #expect(try await engine.printEndedAs(state: "complete", fault: nil) == "finished")
        #expect(try await engine.printEndedAs(state: "cancelled", fault: nil) == "cancelled")
        #expect(try await engine.printEndedAs(state: "standby", fault: nil) == nil)
        #expect(try await engine.printEndedAs(state: nil, fault: nil) == nil)
    }

    @Test("what Khayt saw stands when the printer does not say; unknown records nothing; the sample writes nothing")
    func resultForAnEnd() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        func ended(_ outcome: String, job: String? = "J1") -> FinishCamera.Ended {
            FinishCamera.Ended(machineId: "M-none", machineName: "U1", orderId: job, outcome: outcome, durationS: nil,
                               photoTaken: false, filename: "plate.gcode")
        }
        #expect(await shop.runResult(for: ended("finished")) == "finished")
        #expect(await shop.runResult(for: ended("failed")) == "failed")
        #expect(await shop.runResult(for: ended("cancelled")) == "cancelled")
        #expect(await shop.runResult(for: ended("unknown")) == nil)
        #expect(await shop.noteRunResult(ended("finished", job: nil)) == false, "a print the book cannot name records nothing")
        #expect(await shop.noteRunResult(ended("finished")) == false)
    }

    // MARK: - C5: what a model cannot do

    @Test("a card leaves out what the model cannot do, and keeps what nobody has said anything about")
    func hiddenControls() async throws {
        let engine = OperatorLockTests.sharedEngine
        func m(_ id: String, type: String, catalog: String? = nil, addons: [String] = []) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "printerApi": .object(["type": .string(type)])]
            if let catalog { o["catalogId"] = .string(catalog) }
            if !addons.isEmpty { o["addons"] = .array(addons.map(JSONValue.string)) }
            return .object(o)
        }
        let hidden = try await engine.printerHiddenControls(machines: [
            m("p1p", type: "bambu", catalog: "bambu-p1p"),
            m("p1p-kit", type: "bambu", catalog: "bambu-p1p", addons: ["bambu-p1-camera-led"]),
            m("x1c", type: "bambu", catalog: "bambu-x1c"),
            m("a1", type: "bambu", catalog: "bambu-a1"),
            m("resin", type: "moonraker", catalog: "elegoo-saturn4-ultra"),
            m("voron", type: "moonraker"),
            m("u1", type: "moonraker", catalog: "snapmaker-u1"),
        ]).mapValues(Set.init)
        #expect(hidden["p1p"]?.contains("light") == true, "no light without its kit")
        #expect(hidden["p1p-kit"]?.contains("light") != true, "the kit is fitted")
        #expect(hidden["x1c"]?.contains("light") != true && hidden["x1c"]?.contains("speed") != true)
        #expect(hidden["a1"]?.contains("light") != true, "nobody has said: shown, and the press says what happened")
        #expect(hidden["resin"]?.contains("exclude-object") == true)
        #expect(hidden["voron"]?.contains("exclude-object") != true, "a Klipper printer nobody listed keeps Skip an object")
        #expect(hidden["u1"]?.contains("exclude-object") != true)
        let floor = try String(contentsOf: Self.sources.appending(path: "ShopFloor.swift"), encoding: .utf8)
        for control in ["exclude-object", "speed", "light"] {
            #expect(floor.contains("!hidden.contains(\"\(control)\")"), Comment(rawValue: control))
        }
    }
}
