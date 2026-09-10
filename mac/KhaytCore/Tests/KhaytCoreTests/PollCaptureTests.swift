import Foundation
import Testing
@testable import KhaytCore

/// Freezing what a finished job used, from the polls this app already makes.
///
/// A printer's filament and duration counters are per-JOB and reset when the
/// next print begins, so the only moment they are true is the edge out of
/// printing. Khayt has captured them there for a while; this app read the
/// cache and could not fill it, so a shop running only the Mac never saw a
/// measured figure on the sheet that asks what a job took.
///
/// Every rule below is `printer-poll-cache.js`'s. What is tested here is that
/// this app asks it the right question and believes the answer — the arithmetic
/// has its own suite, and a second opinion in Swift is the thing to avoid.
@Suite struct PollCaptureTests {

    static func status(_ state: String, file: String,
                       durationS: Double? = nil, filamentG: Double? = nil,
                       source: String = "moonraker") -> JSONValue {
        var actuals: [String: JSONValue] = ["source": .string(source)]
        actuals["durationS"] = durationS.map(JSONValue.number) ?? .null
        actuals["filamentGrams"] = filamentG.map(JSONValue.number) ?? .null
        return .object([
            "state": .string(state), "progress": .number(0),
            "filename": .string(file), "type": .string("moonraker"),
            "actuals": .object(actuals),
        ])
    }

    /// The whole point: the numbers are kept at the moment the job ends, not
    /// when the shop gets round to closing the order.
    @Test("a print ending freezes what it used")
    func theEdgeIsCaptured() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let printing = try await engine.mergePoll(
            previous: .object([:]),
            status: Self.status("printing", file: "hood.gcode", durationS: 7100, filamentG: 220),
            now: now.addingTimeInterval(-60))
        let finished = try await engine.mergePoll(
            previous: printing,
            status: Self.status("idle", file: "hood.gcode", durationS: 7200, filamentG: 226),
            now: now)

        #expect(try await engine.completionIsNew(before: printing, after: finished),
                "the end of a print was not noticed")
        guard case .object(let entry) = finished, case .object(let last)? = entry["lastCompleted"],
              case .object(let a)? = last["actuals"] else {
            Issue.record("no completion was frozen"); return
        }
        // The reading taken AFTER the end, not the last one during: Moonraker
        // and OctoPrint both hold a finished job's stats until the next print
        // starts, and the poll before the end can be several percent short.
        #expect(a["filamentGrams"] == JSONValue.number(226))
        #expect(last["filename"] == JSONValue.string("hood.gcode"))
    }

    /// PAUSED IS NOT FINISHED. Pausing is an edge out of printing too, and
    /// treating it as the end recorded a job's mid-print figures as its total —
    /// invisibly, because the real completion overwrote them hours later.
    @Test("pausing a job does not record it as finished")
    func pauseIsNotAnEnding() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let printing = try await engine.mergePoll(
            previous: .object([:]),
            status: Self.status("printing", file: "hood.gcode", durationS: 3600, filamentG: 110),
            now: now.addingTimeInterval(-60))
        let paused = try await engine.mergePoll(
            previous: printing,
            status: Self.status("paused", file: "hood.gcode", durationS: 3610, filamentG: 111),
            now: now)
        #expect(!(try await engine.completionIsNew(before: printing, after: paused)),
                "a paused job was recorded as a finished one")
    }

    /// A poll that changes nothing must not look like a job ending, or this app
    /// would write the shop's book every ten seconds.
    @Test("a machine sitting idle is not a job ending, poll after poll")
    func idleIsNotAnEvent() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        var entry = JSONValue.object([:])
        for i in 0..<3 {
            let next = try await engine.mergePoll(
                previous: entry,
                status: Self.status("idle", file: ""),
                now: now.addingTimeInterval(Double(i) * 10))
            #expect(!(try await engine.completionIsNew(before: entry, after: next)),
                    "poll \(i) looked like a completion")
            entry = next
        }
    }

    /// What reaches the disk is finished jobs and NOTHING LIVE. A saved status
    /// comes back as a confident "Printing · 47%" for a machine that has been
    /// off all night — the exact failure the dashboard's freshness check
    /// exists to prevent.
    @Test("only finished jobs are written, never a live status")
    func nothingLiveIsPersisted() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let printing = try await engine.mergePoll(
            previous: .object([:]),
            status: Self.status("printing", file: "hood.gcode", durationS: 7100, filamentG: 220),
            now: now.addingTimeInterval(-60))
        let finished = try await engine.mergePoll(
            previous: printing,
            status: Self.status("idle", file: "hood.gcode", durationS: 7200, filamentG: 226),
            now: now)

        let saved = try await engine.completionsToPersist(.object(["M1": finished]))
        guard case .object(let byMachine) = saved, case .array(let list)? = byMachine["M1"] else {
            Issue.record("nothing was kept for M1"); return
        }
        #expect(list.count == 1)
        guard case .object(let one) = list[0] else { return }
        #expect(one["state"] == nil, "a live state reached the disk")
        #expect(one["progress"] == nil, "a live progress reached the disk")
        #expect(one["actuals"] != nil, "the measurement is what this is for")
    }

    /// And it round-trips: what this app writes is what it later reads back to
    /// offer on the completion sheet. The two halves were written days apart
    /// and only meet on a shop's disk.
    @Test("what is written is what the completion sheet reads back")
    func theRoundTripCloses() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let printing = try await engine.mergePoll(
            previous: .object([:]),
            status: Self.status("printing", file: "hood.gcode", durationS: 7100, filamentG: 220),
            now: now.addingTimeInterval(-60))
        let finished = try await engine.mergePoll(
            previous: printing,
            status: Self.status("idle", file: "hood.gcode", durationS: 7200, filamentG: 226),
            now: now)
        let saved = try await engine.completionsToPersist(.object(["M1": finished]))

        let pre = try await engine.actualsPrefill(completions: saved, machineId: "M1",
                                                  filename: "hood.gcode",
                                                  estimateHours: 1.5, estimateGrams: 190, now: now)
        #expect(pre.measured, "the sheet could not read back what the poller wrote")
        #expect(pre.weightG == 226)
        #expect(pre.timeH == 2)
        #expect(pre.source == "moonraker")
    }
}
