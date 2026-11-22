import Foundation
import Testing
@testable import KhaytCore

/// What a Bambu printer says it is doing, against the JavaScript it came from.
///
/// The module's own note says why it was shared: *"a printer reported as Idle
/// in one app and Printing in the other is the bug that shared modules exist
/// to prevent."* Porting it makes exactly that bug possible again, so the two
/// are run over every payload shape a printer sends — including the partial
/// deltas, which arrive several times a second and must not be read as reports.
@MainActor
struct BambuReportParityTests {

    private func js() throws -> JSModule { try JSModule(["bambu-report"]) }

    private func theirs(_ js: JSModule, _ payload: String) throws -> JSONValue {
        try js.value("globalThis.KhaytBambuReport.parseBambuReport(ARG0)", [.string(payload)])
    }

    private func check(_ payload: String, _ what: String, _ js: JSModule) throws {
        let mine = BambuReport.parse(payload) ?? .null
        let theirs = try theirs(js, payload)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    @Test("a full snapshot, as a printer actually sends one")
    func realSnapshot() throws {
        let js = try js()
        try check(#"""
            {"print":{"gcode_state":"RUNNING","mc_percent":42,"subtask_name":"bracket.3mf",
            "mc_remaining_time":87,"nozzle_temper":219.5,"bed_temper":60.0,
            "layer_num":134,"total_layer_num":318,"command":"push_status"}}
            """#, "printing", js)
    }

    @Test("every state Bambu names, and the ones it does not")
    func statesMatch() throws {
        let js = try js()
        for state in ["IDLE", "PREPARE", "RUNNING", "PAUSE", "FINISH", "FAILED", "SLICING",
                      "idle", "Running", "  RUNNING", "RUNNING ", "",
                      "UNKNOWN_FUTURE_STATE", "ERROR", "0", "null"] {
            let payload = "{\"print\":{\"gcode_state\":\"\(state)\"}}"
            try check(payload, "state \(state)", js)
            // And the label alone, which the app also calls directly.
            let mine = BambuReport.stateLabel(state)
            guard case .string(let said) = try js.value(
                "globalThis.KhaytBambuReport.bambuStateLabel(ARG0)", [.string(state)])
            else { Issue.record("no label for \(state)"); continue }
            #expect(mine == said, Comment(rawValue: "label \(state): \(mine) vs \(said)"))
        }
    }

    @Test("a state that is not a string at all")
    func oddStates() throws {
        let js = try js()
        for raw in ["null", "0", "false", "true", "123", "[]", "{}", "[\"RUNNING\"]"] {
            try check("{\"print\":{\"gcode_state\":\(raw),\"mc_percent\":1}}",
                      "gcode_state \(raw)", js)
        }
    }

    @Test("a partial delta is not a report")
    func deltasAreRefused() throws {
        // These arrive several times a second. Read as a report, each one
        // blanks the progress bar and the filename on screen.
        let js = try js()
        for payload in [#"{"print":{"command":"push_status","nozzle_temper":219}}"#,
                        #"{"print":{"bed_temper":60}}"#,
                        #"{"print":{}}"#,
                        #"{"print":{"layer_num":5,"total_layer_num":100}}"#,
                        #"{"print":null}"#,
                        #"{"print":"text"}"#,
                        #"{"print":[]}"#,
                        #"{"info":{"command":"get_version"}}"#,
                        #"{}"#, "", "not json at all", "[]", "null", "123", #""a string""#] {
            try check(payload, "delta \(payload.prefix(40))", js)
            #expect(BambuReport.parse(payload) == nil,
                    Comment(rawValue: "\(payload.prefix(40)) was read as a report"))
        }
    }

    @Test("one snapshot field is enough, and which one does not matter")
    func anySnapshotFieldCounts() throws {
        let js = try js()
        for field in [#""gcode_state":"IDLE""#, #""mc_percent":0"#, #""subtask_name":"x""#] {
            try check("{\"print\":{\(field)}}", "only \(field)", js)
            #expect(BambuReport.parse("{\"print\":{\(field)}}") != nil)
        }
    }

    @Test("a figure sent as text reads as nothing, not as a plausible number")
    func typesAreCheckedNotCoerced() throws {
        // The original checks `typeof x === 'number'`. A firmware sending
        // "50" should show as zero — visibly wrong — rather than as a figure
        // nobody questions.
        let js = try js()
        for value in ["\"50\"", "null", "true", "false", "[]", "{}", "\"\"", "0", "-1", "100.5"] {
            try check("{\"print\":{\"gcode_state\":\"RUNNING\",\"mc_percent\":\(value)}}",
                      "mc_percent \(value)", js)
            try check("{\"print\":{\"gcode_state\":\"RUNNING\",\"mc_remaining_time\":\(value)}}",
                      "mc_remaining_time \(value)", js)
            try check("{\"print\":{\"gcode_state\":\"RUNNING\",\"nozzle_temper\":\(value)}}",
                      "nozzle_temper \(value)", js)
            try check("{\"print\":{\"gcode_state\":\"RUNNING\",\"layer_num\":\(value)}}",
                      "layer_num \(value)", js)
        }
    }

    @Test("the filename falls back, and an empty one is not a name")
    func filenameFallsBack() throws {
        let js = try js()
        for pair in [#""subtask_name":"a.3mf","gcode_file":"b.gcode""#,
                     #""subtask_name":"","gcode_file":"b.gcode""#,
                     #""gcode_file":"b.gcode""#,
                     #""subtask_name":"a.3mf""#,
                     #""subtask_name":"","gcode_file":"""#,
                     #""subtask_name":null,"gcode_file":null"#,
                     #""subtask_name":5,"gcode_file":"b.gcode""#] {
            try check("{\"print\":{\"gcode_state\":\"RUNNING\",\(pair)}}", pair, js)
        }
    }

    @Test("minutes on the wire are seconds in the app")
    func remainingTimeConverts() throws {
        let js = try js()
        for minutes in [0, 1, 87, 1440, -5] {
            try check("{\"print\":{\"gcode_state\":\"RUNNING\",\"mc_remaining_time\":\(minutes)}}",
                      "\(minutes) min", js)
        }
        guard case .object(let out)? = BambuReport.parse(
            #"{"print":{"gcode_state":"RUNNING","mc_remaining_time":87}}"#) else {
            Issue.record("no report"); return
        }
        #expect(out["timeRemaining"] == .number(87 * 60), "minutes were not converted")
    }

    // MARK: - Holding the state across deltas (`mergeReport`)

    /// A P1 sends only what changed, so the Mac now keeps one connection and
    /// lays every delta over the last full report. The two apps must agree on
    /// what that held state IS, or the same printer reads differently on each.
    @Test("merging a run of reports agrees with the JavaScript, step by step")
    func mergeAgrees() throws {
        let js = try js()
        let run = [
            #"{"print":{"gcode_state":"RUNNING","mc_percent":42,"subtask_name":"bracket.3mf","nozzle_temper":219.5,"hms":[{"attr":50331904,"code":65543}],"ams":{"tray_now":"1","ams":[{"id":"0","tray":[{"id":"0"}]}]},"command":"push_status"}}"#,
            #"{"print":{"mc_percent":43,"command":"push_status"}}"#,
            #"{"print":{"ams":{"tray_now":"2"},"hms":[]}}"#,
            #"{"info":{"command":"get_version"}}"#,
            #"{"print":{"subtask_name":null,"__proto__":{"x":1},"constructor":{"y":2}}}"#,
            #"{"print":null}"#, #"{"print":[]}"#, "not json", "", "[]", "null",
            #"{"print":{"command":"pause","sequence_id":"3","result":"success"}}"#,
            #"{"print":{"ams":"replaced by a string"}}"#,
            #"{"print":{"gcode_state":"FAILED","print_error":50348044}}"#,
        ]
        var mine: JSONValue? = nil
        var theirs: JSONValue = .null
        for (i, payload) in run.enumerated() {
            mine = BambuReport.merge(mine, payload)
            theirs = try js.value("globalThis.KhaytBambuReport.mergeReport(ARG0, ARG1)",
                                  [theirs, .string(payload)])
            #expect((mine ?? .null) == theirs,
                    Comment(rawValue: "step \(i) \(payload.prefix(40))\n  swift \(mine ?? .null)\n  js    \(theirs)"))
            // And the held state reads the same way through both parsers.
            if let held = mine {
                let swiftRead = BambuReport.parse(value: held) ?? .null
                let jsRead = try js.value(
                    "globalThis.KhaytBambuReport.parseBambuReport(JSON.stringify(ARG0))", [held])
                #expect(swiftRead == jsRead, Comment(rawValue: "read at step \(i)"))
            }
        }
    }

    @Test("a delta keeps what it does not name, and an emptied list empties")
    func mergeKeepsAndClears() throws {
        let full = #"{"print":{"gcode_state":"RUNNING","mc_percent":42,"subtask_name":"a.3mf","hms":[{"attr":1,"code":2}],"ams":{"tray_now":"1","ams":[1]}}}"#
        var held = BambuReport.merge(nil, full)
        held = BambuReport.merge(held, #"{"print":{"mc_percent":50,"hms":[],"ams":{"tray_now":"2"}}}"#)
        guard case .object(let root)? = held, case .object(let p)? = root["print"],
              case .object(let ams)? = p["ams"] else { Issue.record("no held state"); return }
        #expect(p["mc_percent"] == .number(50))
        #expect(p["subtask_name"] == .string("a.3mf"))
        #expect(p["hms"] == .array([]))
        #expect(ams["tray_now"] == .string("2"))
        #expect(ams["ams"] == .array([.number(1)]))
    }

    @Test("nesting deeper than the cap is taken whole, the same on both sides")
    func mergeDepthCap() throws {
        let js = try js()
        func nest(_ n: Int, _ leaf: String) -> String {
            String(repeating: #"{"a":"#, count: n) + leaf + String(repeating: "}", count: n)
        }
        let first = #"{"print":"# + nest(40, #"{"x":1}"#) + "}"
        let second = #"{"print":"# + nest(40, #"{"y":2}"#) + "}"
        let mine = BambuReport.merge(BambuReport.merge(nil, first), second) ?? .null
        let theirs = try js.value(
            "globalThis.KhaytBambuReport.mergeReport(globalThis.KhaytBambuReport.mergeReport(null, ARG0), ARG1)",
            [.string(first), .string(second)])
        #expect(mine == theirs)
        #expect(BambuReport.mergeDepth == 32)
    }
}
