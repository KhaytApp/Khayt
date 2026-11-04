import Foundation
import Testing
@testable import KhaytCore

/// Real figures for a Bambu job on the Mac, through the path the Mac runs.
///
/// A Bambu reports no extrusion and no elapsed time, so before this a finished
/// Bambu job froze nothing at all and the completion sheet offered the quote.
/// Now `printer-poll-cache` keeps a clock for a Bambu job it watched start, and
/// its observed duration (pauses taken off) is frozen on the edge out of
/// printing. Grams come from the sliced 3MF the desktop app sent — labelled
/// SLICED through to this sheet, never "measured".
///
/// The statuses are built by `engine.bambuStatus(held:)` from MQTT reports in
/// the shape `BambuReport` already parses, then re-encoded exactly as
/// `PrinterWatch.capture` does. Unverified on a real Bambu: the bench has none.
@Suite struct BambuActualsTests {

    static func report(_ state: String, percent: Int) -> JSONValue {
        .object(["print": .object([
            "gcode_state": .string(state),
            "mc_percent": .number(Double(percent)),
            "mc_remaining_time": .number(30),
            "subtask_name": .string("khayt-xyz.gcode.3mf"),
        ])])
    }

    /// What `PrinterWatch.capture` hands the cache: the status, through JSON.
    static func row(_ engine: KhaytEngine, _ state: String, percent: Int) async throws -> JSONValue {
        guard let status = try await engine.bambuStatus(held: report(state, percent: percent)) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let data = try JSONEncoder().encode(status)
        return try JSONValue.decode(JSONValue.self, from: data)
    }

    @Test("a Bambu watched from start to finish freezes its observed time, pauses off")
    func observedDuration() async throws {
        let engine = try KhaytEngine()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var entry = JSONValue.object([:])
        // Every 10 s, as the Mac polls: 20 min printing, 5 min paused, 20 min printing.
        var t = t0
        func poll(_ state: String, _ pct: Int, for seconds: Int) async throws {
            for _ in 0..<(seconds / 10) {
                entry = try await engine.mergePoll(previous: entry,
                                                   status: try await Self.row(engine, state, percent: pct),
                                                   now: t)
                t = t.addingTimeInterval(10)
            }
        }
        try await poll("IDLE", 0, for: 10)
        try await poll("RUNNING", 0, for: 1200)
        try await poll("PAUSE", 40, for: 300)
        try await poll("RUNNING", 41, for: 1200)
        let before = entry
        entry = try await engine.mergePoll(previous: entry,
                                           status: try await Self.row(engine, "FINISH", percent: 100), now: t)

        #expect(try await engine.completionIsNew(before: before, after: entry))
        guard case .object(let e) = entry, case .object(let last)? = e["lastCompleted"],
              case .object(let a)? = last["actuals"] else {
            Issue.record("a watched Bambu job froze nothing"); return
        }
        #expect(a["durationS"] == JSONValue.number(2400), "40 minutes printing, the 5 paused taken off")
        #expect(a["timeBasis"] == JSONValue.string("observed"))
        #expect(a["filamentGrams"] == JSONValue.null, "no grams were sent, so none are claimed")
    }

    @Test("sliced figures reach the sheet as SLICED, never measured")
    func slicedIsSaid() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let completion = JSONValue.object([
            "at": .number(now.addingTimeInterval(-600).timeIntervalSince1970 * 1000),
            "filename": .string("khayt-xyz.gcode.3mf"),
            "actuals": .object([
                "filamentGrams": .number(41.83), "durationS": .number(5600),
                "source": .string("bambu-sliced"), "gramsBasis": .string("sliced"),
                "timeBasis": .string("observed"), "plate": .number(2),
            ]),
        ])
        let pre = try await engine.actualsPrefill(
            completions: .object(["B1": .array([completion])]), machineId: "B1",
            filename: "khayt-xyz.gcode.3mf", estimateHours: 2, estimateGrams: 50, now: now)
        #expect(pre.weightG == 41.8)
        #expect(pre.weightMeasured == false, "a sliced figure called measured is the R1 failure")
        #expect(pre.weightSliced == true)
        #expect(pre.timeMeasured == true, "the observed time is a measurement")
        #expect(pre.timeSliced == false)
        #expect(pre.sliced == true)
        #expect(pre.plate == 2)
    }

    @Test("the sheet's words for a sliced figure exist in every language")
    func wordsExist() async throws {
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/KhaytCore/JS/locale-\(lang).js")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("\"act.sliced\""), "\(lang) has no act.sliced")
            #expect(text.contains("\"act.sliced_note\""), "\(lang) has no act.sliced_note")
        }
    }
}
