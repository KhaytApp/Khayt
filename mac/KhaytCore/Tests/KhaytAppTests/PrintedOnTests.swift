import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A job sent to a printer from the Mac records the machine that printed it.
///
/// `test/print-runs.test.js` holds the rule — which fields, the plan kept, the
/// reprint history, one row in the machine P&L. This holds the Mac's wiring:
/// the send carries the job, the write goes through the chain against the
/// record on disk, and the inspector says "Printed on X (planned Y)".
@MainActor
struct PrintedOnTests {

    static func book() -> [String: JSONValue] {
        [
            "printLog": .array([
                .object(["id": .string("J1"), "project": .string("Lamp"), "status": .string("queued"),
                         "machineId": .string("M1"), "rev": .number(3), "parts": .array([])]),
                .object(["id": .string("J2"), "project": .string("Done"), "status": .string("completed"),
                         "machineId": .string("M1"), "parts": .array([])]),
                // A record from before this existed: no printRuns at all.
                .object(["id": .string("J3"), "project": .string("Old"), "status": .string("pending"),
                         "parts": .array([])]),
            ]),
            "machines": .array([
                .object(["id": .string("M1"), "name": .string("Ender")]),
                .object(["id": .string("M2"), "name": .string("Prusa")]),
            ]),
        ]
    }

    static func job(_ root: [String: JSONValue], _ id: String) -> [String: JSONValue]? {
        guard case .array(let rows)? = root["printLog"] else { return nil }
        for row in rows { if case .object(let o) = row, o["id"] == .string(id) { return o } }
        return nil
    }

    @Test("a job planned for one machine and sent to another: the actual machine, the plan kept, the send in history")
    func plannedElsewhere() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let changed = try await Shop.applyPrintRun(to: &root, jobId: "J1", machineId: "M2", started: true,
                                                   file: "Lamp_plate1.gcode", at: "2026-10-16T09:00:00.000Z",
                                                   engine: engine)
        #expect(changed)
        let job = try #require(Self.job(root, "J1"))
        #expect(job["machineId"] == .string("M2"), "the P&L and the nozzle read machineId")
        #expect(job["plannedMachineId"] == .string("M1"), "the hand-picked machine was overwritten silently")
        guard case .array(let runs)? = job["printRuns"], case .object(let run)? = runs.first else {
            Issue.record("no history"); return
        }
        #expect(runs.count == 1)
        #expect(run["machineId"] == .string("M2"))
        #expect(run["started"] == .bool(true))
        #expect(run["file"] == .string("Lamp_plate1.gcode"))
        #expect(job["status"] == .string("queued"), "a send is not a move: the status is the board's")

        // Back on the planned machine: the plan comes OFF, not set to null.
        _ = try await Shop.applyPrintRun(to: &root, jobId: "J1", machineId: "M1", started: true,
                                         file: "Lamp_plate1.gcode", at: "2026-10-16T14:00:00.000Z",
                                         engine: engine)
        let again = try #require(Self.job(root, "J1"))
        #expect(again["plannedMachineId"] == nil)
        if case .array(let runs)? = again["printRuns"] { #expect(runs.count == 2) } else { Issue.record("history lost") }
    }

    @Test("a finished job and a missing job are left alone; an old record takes its first send")
    func edges() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let at = "2026-10-16T09:00:00.000Z"
        #expect(try await !Shop.applyPrintRun(to: &root, jobId: "J2", machineId: "M2", started: true,
                                               file: "", at: at, engine: engine))
        #expect(Self.job(root, "J2")?["machineId"] == .string("M1"))
        #expect(try await !Shop.applyPrintRun(to: &root, jobId: "NOPE", machineId: "M2", started: true,
                                               file: "", at: at, engine: engine))
        #expect(try await Shop.applyPrintRun(to: &root, jobId: "J3", machineId: "M2", started: false,
                                              file: "", at: at, engine: engine))
        let old = try #require(Self.job(root, "J3"))
        #expect(old["machineId"] == .string("M2"))
        #expect(old["plannedMachineId"] == nil, "nothing was planned on an unassigned job")
    }

    @Test("the write reaches the file through the chain, and a job never sent reads as nothing")
    func onDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-printed-on-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(JSONValue.object(Self.book())).write(to: url)

        let engine = try KhaytEngine()
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            _ = try await Shop.applyPrintRun(to: &root, jobId: "J1", machineId: "M2", started: true,
                                             file: "a.gcode", at: "2026-10-16T09:00:00.000Z", engine: engine)
        }
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)) else {
            Issue.record("the book is unreadable"); return
        }
        let job = try #require(Self.job(root, "J1"))
        #expect(job["machineId"] == .string("M2"))
        #expect(job["rev"] == .number(4), "a changed record is stamped, or it never syncs")

        let printed = try #require(try await engine.printedOn(order: .object(job)))
        #expect(printed.machineId == "M2")
        #expect(printed.planned == "M1")
        #expect(printed.started)
        #expect(printed.earlier.isEmpty)
        #expect(try await engine.printedOn(order: .object(try #require(Self.job(root, "J3")))) == nil,
                "a record from before this must read as it always did")
    }

    @Test("the inspector says where it printed, and the plan, in both languages")
    func inspectorSentence() async throws {
        let engine = try KhaytEngine()
        let names = ["M1": "Ender", "M2": "Prusa"]
        let name: (String) -> String = { names[$0] ?? $0 }
        var job: [String: JSONValue] = ["id": .string("J1"), "status": .string("queued"), "machineId": .string("M1")]
        for (machine, at) in [("M2", "2026-10-15T09:00:00.000Z"), ("M2", "2026-10-16T09:00:00.000Z")] {
            let f = try #require(try await engine.printRunFields(order: .object(job), machineId: machine,
                                                                 at: at, started: true, file: ""))
            for (k, v) in f { if v == .null { job.removeValue(forKey: k) } else { job[k] = v } }
        }
        let printed = try #require(try await engine.printedOn(order: .object(job)))

        let en = Words()
        await en.load("en", engine: engine)
        #expect(JobMachineLine.sentence(printed, name: name, words: en) == "Printed on Prusa (planned Ender)")
        #expect(JobMachineLine.earlier(printed.earlier, name: name, words: en).hasPrefix("Earlier: Prusa"))

        let ar = Words()
        await ar.load("ar", engine: engine)
        let said = JobMachineLine.sentence(printed, name: name, words: ar)
        #expect(said.contains("Prusa") && said.contains("Ender") && !said.contains("Printed"))
        #expect(!said.contains("mac."), "a key with no Arabic")

        let uploaded: JSONValue = .object(["id": .string("J9"), "machineId": .string("M2"), "printRuns": .array([
            .object(["machineId": .string("M2"), "at": .string("2026-10-16T09:00:00.000Z"), "started": .bool(false)]),
        ])])
        let sentOnly = try #require(try await engine.printedOn(order: uploaded))
        #expect(JobMachineLine.sentence(sentOnly, name: name, words: en) == "Sent to Prusa")
    }

    @Test("the send carries the job, and records it only once the printer took the file")
    func wired() throws {
        let sheet = try SmartPlugTests.source("SendToPrinterSheet.swift")
        #expect(sheet.contains("startPrint: go, jobId: jobId"), "the sheet sends without saying which job")
        let printers = try SmartPlugTests.source("Shop+Printers.swift")
        let send = try #require(printers.range(of: "let sent = try await PrinterSend.send("))
        let record = try #require(printers.range(of: "await recordPrintRun(jobId: jobId"))
        #expect(send.upperBound < record.lowerBound, "recorded before the printer accepted it")
        #expect(printers.contains("try await StoreWriter.updateAsync(build) { root in\n                _ = try await Self.applyPrintRun("),
                "the job is written outside the write chain")
        let inspector = try SmartPlugTests.source("OrderInspector.swift")
        #expect(inspector.contains("JobMachineLine(shop: shop, job: job, printed: printed)"))
    }
}
