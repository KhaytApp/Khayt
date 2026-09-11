import Foundation
import Testing
@testable import KhaytCore

/// What a Bambu says it is doing, through the engine.
///
/// `test/bambu.test.js` pins the rule; these are the SAME fixtures asked of the
/// same module from this side, so the two apps cannot read one report two ways.
/// That is the whole reason `lib/bambu-report.js` was split out of
/// `lib/bambu.js`, which is Node-only from its first line and cannot be loaded
/// in JavaScriptCore at all.
@Suite struct BambuStatusTests {

    static let snapshot = #"""
    {"print":{"gcode_state":"RUNNING","mc_percent":42,"mc_remaining_time":12,
    "nozzle_temper":215.3,"bed_temper":60,"subtask_name":"bracket.3mf",
    "layer_num":30,"total_layer_num":120}}
    """#

    @Test("a pushall snapshot reads as the same status the other app reads")
    func aSnapshotReads() async throws {
        let engine = try KhaytEngine()
        let status = try #require(try await engine.bambuStatus(report: Self.snapshot))
        #expect(status.state == "Printing")
        #expect(status.progress == 42)
        #expect(status.timeRemaining == 720)     // 12 minutes, in seconds
        #expect(status.tempNozzle == 215.3)
        #expect(status.tempBed == 60)
        #expect(status.filename == "bracket.3mf")
        #expect(status.type == "bambu")
    }

    /// A Bambu pushes small partial messages continuously and a full state only
    /// when asked. A caller that took the first message regardless would report
    /// a printer as Idle on the strength of one that said nothing about what it
    /// was doing.
    @Test("a delta is nothing, not a printer that is idle")
    func aDeltaIsNotAnAnswer() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.bambuStatus(report: #"{"print":{"command":"push_status"}}"#) == nil)
        #expect(try await engine.bambuStatus(report: #"{"system":{}}"#) == nil)
        #expect(try await engine.bambuStatus(report: "not json") == nil)
        #expect(try await engine.bambuStatus(report: "") == nil)
    }

    /// Every state Bambu reports, because an unmapped one falling through to
    /// "Connected" is a printer that looks fine while it is on fire.
    @Test("every state Bambu names has a word")
    func everyStateIsNamed() async throws {
        let engine = try KhaytEngine()
        let expected = ["IDLE": "Idle", "PREPARE": "Preparing", "RUNNING": "Printing",
                        "PAUSE": "Paused", "FINISH": "Finished", "FAILED": "Failed",
                        "SLICING": "Slicing"]
        for (raw, word) in expected {
            let report = #"{"print":{"gcode_state":"\#(raw)","mc_percent":0}}"#
            let status = try #require(try await engine.bambuStatus(report: report))
            #expect(status.state == word, "\(raw) read as \(status.state)")
        }
    }
}
