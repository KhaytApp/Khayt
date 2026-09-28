import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Measured electricity per print, and the whole cost of a failed one.
///
/// The rules are `lib/print-energy.js` and `lib/failed-print-cost.js` (their
/// Node tests hold the arithmetic). These prove the Mac reaches them through
/// its own seams: the plug poll feeds the meter, the meter survives a restart
/// through its load/save seam, the finish seam writes the reading onto the
/// job, and a failed print's costing is built from what the app knows.
@MainActor
struct EnergyCostTests {

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func live(_ state: String, _ file: String = "lamp.gcode", progress: Double = 0) -> JSONValue {
        .object(["state": .string(state), "filename": .string(file), "progress": .number(progress)])
    }

    /// A store for the meter that a test can hold, and read after a "restart".
    final class Box { var saved: JSONValue? }

    static func meter(_ box: Box) -> EnergyMeter {
        EnergyMeter(load: { box.saved }, save: { box.saved = $0 })
    }

    @Test("an hour at 150 W on the plug poll is 150 Wh, taken at the end")
    func meters() async throws {
        let engine = try KhaytEngine()
        let m = Self.meter(Box())
        for i in 0...60 {
            await m.observe("M1", watts: 150, live: Self.live("printing"), shared: false,
                            now: Self.t0.addingTimeInterval(Double(i) * 60), engine: engine)
        }
        let r = try #require(await m.take("M1", engine: engine))
        #expect(r.wh == 150)
        #expect(r.coverage == 1)
        #expect(await m.take("M1", engine: engine) == nil, "taken once")
    }

    @Test("a print spanning a restart resumes from what was saved")
    func restart() async throws {
        let engine = try KhaytEngine()
        let box = Box()
        let first = Self.meter(box)
        for i in 0...30 {
            await first.observe("M1", watts: 120, live: Self.live("printing"), shared: false,
                                now: Self.t0.addingTimeInterval(Double(i) * 60), engine: engine)
        }
        // A new app, the same book: the meter is read back from the seam.
        let second = Self.meter(box)
        for i in 32...60 {
            await second.observe("M1", watts: 120, live: Self.live("printing"), shared: false,
                                 now: Self.t0.addingTimeInterval(Double(i) * 60), engine: engine)
        }
        let r = try #require(await second.take("M1", engine: engine))
        #expect(r.wh == 120)
        #expect(r.gaps == 0)
    }

    @Test("no plug reading, a printer never heard from, or a shared plug: nothing metered")
    func edges() async throws {
        let engine = try KhaytEngine()
        let m = Self.meter(Box())
        for i in 0...5 {
            let at = Self.t0.addingTimeInterval(Double(i) * 60)
            await m.observe("A", watts: nil, live: Self.live("printing"), shared: false, now: at, engine: engine)
            await m.observe("B", watts: 100, live: nil, shared: false, now: at, engine: engine)
            await m.observe("C", watts: 100, live: Self.live("printing"), shared: true, now: at, engine: engine)
        }
        for id in ["A", "B", "C"] { #expect(await m.take(id, engine: engine) == nil, Comment(rawValue: id)) }
        let shared = try await engine.sharedPlugIds(machines: [
            .object(["id": .string("A"), "smartPlug": .object(["type": .string("shelly"), "host": .string("10.0.0.9")])]),
            .object(["id": .string("B"), "smartPlug": .object(["type": .string("shelly"), "host": .string("10.0.0.9")])]),
        ])
        #expect(shared == ["A", "B"])
    }

    @Test("a finished print's reading is written onto its job, stamped, beside the actual time")
    func writtenToTheJob() async throws {
        let engine = try KhaytEngine()
        let store = try FinishPhotoTests.tempStore(["printLog": .array([
            FinishPhotoTests.job("J1", "printing", machine: "M1", file: "lamp.gcode")])])
        let reading = KhaytEngine.EnergyReading(wh: 812.4, coveredS: 21600, spanS: 21700,
                                                coverage: 0.995, samples: 361, gaps: 0)
        let fields = try await engine.energyJobFields(reading, at: "2026-09-28T10:00:00Z")
        try StoreWriter.updateRecord(storeURL: store, owns: { true }, whoHasIt: { nil },
                                     collection: "printLog", id: "J1") { r in
            for (k, v) in fields { r[k] = v }
        }
        guard case .array(let jobs)? = try FinishPhotoTests.read(store)["printLog"],
              case .object(let job)? = jobs.first else { Issue.record("no job"); return }
        #expect(job["actualEnergyWh"] == .number(812.4))
        guard case .object(let meta)? = job["actualEnergy"] else { Issue.record("no meta"); return }
        #expect(meta["source"] == .string("plug"))
        #expect(meta["coverage"] == .number(0.995))
        #expect(job["rev"] != nil || job["updatedAt"] != nil, "an edit the sync can see")
    }

    @Test("a wattage is suggested from three metered prints, never from two")
    func suggestion() async throws {
        let engine = try KhaytEngine()
        func job(_ id: String, _ wh: Double, _ h: Double) -> JSONValue {
            .object(["id": .string(id), "machineId": .string("M1"), "status": .string("completed"),
                     "actualPrintTime": .number(h), "actualEnergyWh": .number(wh),
                     "actualEnergy": .object(["coverage": .number(1), "at": .string("2026-09-2\(id)")])])
        }
        #expect(try await engine.suggestPowerDraw(printLog: [job("1", 300, 2), job("2", 300, 2)], machineId: "M1") == nil)
        let s = try #require(try await engine.suggestPowerDraw(
            printLog: [job("1", 300, 2), job("2", 300, 2), job("3", 150, 1)], machineId: "M1"))
        #expect(s.watts == 150)
        #expect(s.basedOn == 3)
    }

    // MARK: - A failed print, costed whole

    static let machines: [JSONValue] = [.object(["id": .string("M1"), "wearRate": .number(2),
                                                 "powerDraw": .number(250)])]
    static let order: [String: JSONValue] = [
        "id": .string("J1"), "machineId": .string("M1"), "material": .string("PLA"),
        "printTime": .number(10),
        "parts": .array([.object(["printTime": .number(10), "elecRate": .number(0.2)])]),
    ]

    @Test("a stopped print: the printer's hours, else the estimate × its progress at failure")
    func costingFromTheSeam() throws {
        let ended = FinishCamera.Ended(machineId: "M1", machineName: "U1", orderId: "J1",
                                       outcome: "failed", durationS: 7200, photoTaken: false,
                                       filename: "lamp.gcode")
        let withHours = Shop.failedCosting(order: Self.order, machines: Self.machines, ended: ended,
                                           live: Self.live("error", progress: 30), attempt: nil, inspected: false)
        guard case .object(let a) = withHours else { Issue.record("not an object"); return }
        #expect(a["actualHours"] == .number(2))
        #expect(a["progress"] == .number(30))
        #expect(a["machine"] != nil)

        let noTimer = FinishCamera.Ended(machineId: "M1", machineName: "U1", orderId: "J1",
                                         outcome: "cancelled", durationS: nil, photoTaken: false,
                                         filename: "lamp.gcode")
        guard case .object(let b) = Shop.failedCosting(order: Self.order, machines: Self.machines, ended: noTimer,
                                                       live: Self.live("cancelled", progress: 40),
                                                       attempt: nil, inspected: false) else { return }
        #expect(b["actualHours"] == nil)
        #expect(b["progress"] == .number(40))

        // Inspected: it ran to the end, and its own metered energy is on the job.
        var done = Self.order
        done["actualEnergyWh"] = .number(2000)
        done["actualEnergy"] = .object(["coverage": .number(1)])
        guard case .object(let c) = Shop.failedCosting(order: done, machines: Self.machines, ended: nil,
                                                       live: nil, attempt: nil, inspected: true) else { return }
        #expect(c["progress"] == .number(100))
        #expect(c["energy"] == .object(["wh": .number(2000), "coverage": .number(1)]))
    }

    @Test("a waste entry on a job carries machine time and power; `cost` stays the filament")
    func wasteEntry() async throws {
        let engine = try KhaytEngine()
        let shelf: [JSONValue] = [.object(["id": .string("s1"), "material": .string("PLA"),
                                           "cost": .number(80), "weight": .number(1000),
                                           "spoolWeight": .number(1000)])]
        let input: [String: JSONValue] = ["material": .string("PLA"), "weight": .number(100),
                                          "cost": .number(8), "orderId": .string("J1")]
        let plain = try await engine.newWasteEntry(input, id: "W1", today: "2026-09-28", inventory: shelf)
        guard case .object(let p)? = plain.entry else { Issue.record("no entry"); return }
        #expect(p["costFull"] == nil, "no costing: the row it always was")

        let costing: JSONValue = .object(["machine": Self.machines[0], "progress": .number(50)])
        let full = try await engine.newWasteEntry(input, id: "W2", today: "2026-09-28", inventory: shelf,
                                                  order: .object(Self.order), costing: costing)
        guard case .object(let f)? = full.entry else { Issue.record("no entry"); return }
        #expect(f["cost"] == .number(8))
        #expect(f["costMachine"] == .number(10))            // 5 h × 2
        #expect(f["costPower"] == .number(0.25))            // 5 h × 0.25 kW × 0.2
        #expect(f["costFull"] == .number(18.25))
        let decoded = try JSONDecoder().decode(WasteEntry.self, from: JSONEncoder().encode(full.entry!))
        #expect(decoded.full == 18.25)
        #expect(decoded.costMachine == 10)
    }

    @Test("a QC failure is costed whole: the entire print's time")
    func qcFailure() async throws {
        let engine = try KhaytEngine()
        let costing: JSONValue = .object(["machine": Self.machines[0], "progress": .number(100)])
        let out = try await engine.recordQcFailure(
            order: .object(Self.order), failureType: "warping", severity: "major", reason: "",
            weight: 0, inspector: nil, inventory: [], now: Self.t0, wasteId: "W1",
            defaultReason: "QC", costing: costing)
        guard case .object(let w) = out.waste else { Issue.record("no waste"); return }
        #expect(w["costMachine"] == .number(20))
        #expect(w["costPower"] == .number(0.5))
        #expect(w["cost"] == .number(0))
    }

    @Test("the P&L is untouched and the words exist in both languages")
    func wired() throws {
        let words = try SmartPlugTests.source("Words.swift")
        for key in ["mac.waste_machine", "mac.waste_power", "mac.waste_full", "mac.waste_true_title",
                    "mac.waste_true_note", "mac.power_measured", "mac.power_use", "mac.acc_power_title",
                    "mac.waste_job"] {
            #expect(words.contains("\"\(key)\""), Comment(rawValue: key))
        }
        let shop = try SmartPlugTests.source("Shop.swift")
        #expect(shop.contains("await settleEnergy(ended)"), "the finish seam must settle the meter")
        #expect(shop.contains("await meter?.observe("), "the plug poll must feed the meter")
    }
}
