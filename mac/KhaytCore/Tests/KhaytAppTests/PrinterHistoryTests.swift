import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the machine itself remembers.
///
/// Khayt's print log is a BUSINESS record — orders a shop took, with a client
/// and a price. The printer's own history is a more literal thing: every job it
/// ran, including test prints, reprints and calibration. For "how much has gone
/// through this nozzle" the printer is the ground truth and the order log is a
/// sample of it, and on the machine this shop keeps that difference is a factor
/// of six.
///
/// The mapping is `lib/moonraker-history.js`'s. The fixtures here are the U1's
/// literal reply, because the corrections that matter are all about what a
/// four-head toolchanger actually sends.
@MainActor
struct PrinterHistoryTests {

    /// Two completed jobs, verbatim from `/server/history/list` on the bench.
    static let raw: [String: JSONValue] = {
        let json = """
        {"count": 133, "jobs": [
          {"job_id": "000084",
           "filename": "Snapmaker U1 Auxiliary Fan Deflector (v3.1) 35 deg_PETG_11m2s.gcode",
           "status": "completed", "start_time": 1788462549.671484, "end_time": 1788463396.685,
           "filament_used": 1337.97, "print_duration": 675.41, "total_duration": 846.88,
           "metadata": {"filament_type": "PETG;PLA;PLA;PLA",
                        "filament_name": "Generic PETG\\";\\"Generic PLA\\";\\"Generic PLA\\";\\"Generic PLA",
                        "filament_weight": [4.03, 0.0, 0.0, 0.0], "filament_weight_total": 4.03,
                        "layer_height": 0.2, "nozzle_diameter": 0.4}},
          {"job_id": "000083", "filename": "Interior Grille Guard_PETG_40m29s.gcode",
           "status": "completed", "start_time": 1788457535.392, "end_time": 1788460414.630,
           "filament_used": 1271.98, "print_duration": 2636.03, "total_duration": 2879.23,
           "metadata": {"filament_type": "PETG;PLA;PLA;PLA",
                        "filament_name": "Generic PETG\\";\\"Generic PLA\\";\\"Generic PLA\\";\\"Generic PLA",
                        "filament_weight": [3.83, 0.0, 0.0, 0.0], "filament_weight_total": 3.83,
                        "layer_height": 0.2, "nozzle_diameter": 0.4}}
        ]}
        """
        return try! JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }()

    @Test("a four-head toolchanger's material list reads as one material")
    func toolchangerMaterial() async throws {
        // The U1 reports `filament_type` once per TOOL — "PETG;PLA;PLA;PLA" —
        // whether or not the tool was used, and the slicer writes the names
        // ALREADY QUOTED. Stored verbatim, every multi-tool job looks like a
        // material nobody stocks and the abrasiveness match in
        // `lib/nozzle-wear.js` misses it entirely.
        let jobs = try await KhaytEngine().printerHistoryJobs(Self.raw)
        #expect(jobs.count == 2)
        guard case .object(let first) = jobs[0] else { Issue.record("not mapped"); return }
        guard case .string(let material)? = first["material"] else { Issue.record("no material"); return }
        #expect(!material.contains("\""), "the slicer's quotes came through: \(material)")
        #expect(!material.contains(";"))
        #expect(material.contains("PETG"))
    }

    @Test("the slicer's thumbnails do not come with it")
    func noThumbnails() async throws {
        // A hundred base64 previews would land in the store file, which is
        // pushed to the cloud encrypted on every sync.
        let jobs = try await KhaytEngine().printerHistoryJobs(Self.raw)
        let text = String(decoding: try JSONEncoder().encode(jobs), as: UTF8.self)
        #expect(!text.contains("thumbnail"))
        #expect(!text.contains("base64"))
    }

    @Test("importing twice adds nothing")
    func mergeIsIdempotent() async throws {
        // Merged by job id. A shop that presses it again after a print should
        // gain that one print, not a second copy of everything.
        let engine = try KhaytEngine()
        let jobs = try await engine.printerHistoryJobs(Self.raw)
        let again = try await engine.mergePrinterHistory(jobs, jobs)
        #expect(again.count == jobs.count)
    }

    @Test("a new job is added and the old ones kept")
    func mergeAdds() async throws {
        let engine = try KhaytEngine()
        let jobs = try await engine.printerHistoryJobs(Self.raw)
        let extra: JSONValue = .object([
            "jobId": .string("000085"), "filename": .string("later.gcode"),
            "status": .string("completed"), "startedAt": .string("2026-09-05T01:00:00.000Z"),
            "grams": .number(50), "hours": .number(1),
        ])
        let merged = try await engine.mergePrinterHistory(jobs, [extra])
        #expect(merged.count == jobs.count + 1)
        // Newest first, so the most recent print is the one at the top.
        guard case .object(let top) = merged[0] else { Issue.record("no rows"); return }
        #expect(top["jobId"] == .string("000085"))
    }

    @Test("the totals are the grams and the hours, counted from a date")
    func totals() async throws {
        let engine = try KhaytEngine()
        let jobs = try await engine.printerHistoryJobs(Self.raw)
        let all = try await engine.printerHistoryTotals(jobs, since: "")
        #expect(all.jobs == 2)
        // 4.03 g + 3.83 g, from `filament_weight_total` — the weight the slicer
        // computed for the whole plate. NOT `filament_used`, which is length in
        // millimetres and would read as a plausible weight in the wrong unit:
        // these two jobs would come to 2,609 "grams" instead of eight.
        #expect(abs(all.grams - 7.86) < 0.01)
        #expect(all.hours > 0)

        // A nozzle fitted after both jobs has nothing to answer for.
        let sinceLater = try await engine.printerHistoryTotals(jobs, since: "2027-01-01")
        #expect(sinceLater.grams == 0)
        #expect(sinceLater.jobs == 0)
    }

    @Test("only a Klipper machine has a history this can read")
    func onlyMoonraker() async throws {
        // The other six protocols do not expose one, and a menu item that
        // always answers "not this printer" is one people learn to ignore.
        let engine = try KhaytEngine()
        let bambu = PrinterWatchTests.machine("bambu")
        await #expect(throws: PrinterWatch.Refusal.self) {
            try await PrinterWatch.history(bambu, engine: engine)
        }
    }

    @Test("the wear figure says where it came from")
    func provenance() throws {
        // The counter reads completed ORDERS unless the machine's own history
        // has been read, and on this shop's book the two answers are 0 g and
        // 6,375 g — its orders carry no part weights at all. A number whose
        // source is not stated is a number nobody can check.
        let row: JSONValue = .object([
            "id": .string("M-1"), "name": .string("Bench"),
            "printerHistory": .object([
                "source": .string("moonraker"),
                "importedAt": .string("2026-09-05T01:00:00.000Z"),
                "jobs": .array([]),
            ]),
        ])
        let machine = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
        #expect(machine.hasPrinterHistory)

        let bare: JSONValue = .object(["id": .string("M-2"), "name": .string("Other")])
        let plain = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(bare))
        #expect(!plain.hasPrinterHistory)
    }
}
