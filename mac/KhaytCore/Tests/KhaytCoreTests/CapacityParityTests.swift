import Foundation
import Testing
@testable import KhaytCore

/// Can the shop take this job, against the JavaScript it came from.
///
/// The three things the panel this replaced got wrong are all about what it
/// HID: an overbooked machine clamped to "full", voided jobs still booking a
/// machine, and every untargeted machine dropped from the list entirely.
@MainActor
struct CapacityParityTests {

    private func js() throws -> JSModule { try JSModule(["capacity"]) }

    private func check(_ machines: [JSONValue], _ orders: [JSONValue],
                       days: Double = 7, unassigned: String = "Unassigned",
                       _ what: String, _ js: JSModule) throws {
        let hours = orders.map { order -> Double in
            guard case .object(let o) = order else { return 0 }
            let n = JSSemantics.number(o["printTime"])
            return n.isFinite ? n : 0
        }
        let mine = Capacity.report(machines: machines, orders: orders, hours: hours,
                                   days: days, unassigned: unassigned)
        let v = try js.value("""
            globalThis.KhaytCapacity.capacity(
              {machines: ARG0, orders: ARG1, days: ARG2, unassigned: ARG3}, {})
            """, [.array(machines), .array(orders), .number(days), .string(unassigned)])
        guard case .object(let o) = v, case .array(let rows)? = o["rows"],
              case .object(let t)? = o["totals"] else {
            Issue.record("not a report"); return
        }
        let theirRows: [Capacity.Row] = rows.map { row in
            guard case .object(let r) = row else {
                return .init(machineId: "?", name: "?", color: "?", hoursPerDay: -1,
                             bookedHours: -1, jobs: -1, availableHours: -1,
                             loadPct: nil, daysToClear: nil, overbooked: false)
            }
            var load: Double?; if case .number(let n)? = r["loadPct"] { load = n }
            var clear: Double?; if case .number(let n)? = r["daysToClear"] { clear = n }
            var over = false; if case .bool(let b)? = r["overbooked"] { over = b }
            return .init(machineId: JSSemantics.text(r["machineId"]),
                         name: JSSemantics.text(r["name"]),
                         color: JSSemantics.text(r["color"]),
                         hoursPerDay: JSSemantics.number(r["hoursPerDay"]),
                         bookedHours: JSSemantics.number(r["bookedHours"]),
                         jobs: Int(JSSemantics.number(r["jobs"])),
                         availableHours: JSSemantics.number(r["availableHours"]),
                         loadPct: load, daysToClear: clear, overbooked: over)
        }
        func maybe(_ k: String) -> Double? {
            if case .number(let n)? = t[k] { return n }; return nil
        }
        var over = false; if case .bool(let b)? = t["overbooked"] { over = b }
        var none = false; if case .bool(let b)? = t["noTargets"] { none = b }
        let theirs = Capacity.Report(rows: theirRows, totals: .init(
            bookedHours: JSSemantics.number(t["bookedHours"]),
            availableHours: JSSemantics.number(t["availableHours"]),
            untargeted: JSSemantics.number(t["untargeted"]),
            jobs: Int(JSSemantics.number(t["jobs"])),
            loadPct: maybe("loadPct"), daysToClear: maybe("daysToClear"),
            overbooked: over, noTargets: none))
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine.rows.map { ($0.machineId, $0.bookedHours, $0.loadPct) }) \(mine.totals)
              js    \(theirs.rows.map { ($0.machineId, $0.bookedHours, $0.loadPct) }) \(theirs.totals)
            """))
    }

    private func machine(_ id: String, _ name: String, target: JSONValue = .number(8),
                         color: String = "") -> JSONValue {
        var m: [String: JSONValue] = ["id": .string(id), "name": .string(name),
                                      "targetHoursPerDay": target]
        if !color.isEmpty { m["color"] = .string(color) }
        return .object(m)
    }

    private func job(_ machineId: String, hours: Double, status: String = "pending",
                     voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["status": .string(status),
                                      "printTime": .number(hours)]
        if !machineId.isEmpty { o["machineId"] = .string(machineId) }
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    @Test("a machine booked three weeks over says so, rather than reading full")
    func overbookedIsNotClamped() throws {
        // `Math.min(100, …)` made a machine three weeks behind identical to one
        // with nothing waiting. That is the single most important signal here.
        let js = try js()
        try check([machine("M-1", "Behind"), machine("M-2", "Idle")],
                  [job("M-1", hours: 200)], "one buried, one idle", js)
        let mine = Capacity.report(machines: [machine("M-1", "Behind")],
                                   orders: [job("M-1", hours: 200)],
                                   hours: [200], days: 7)
        #expect((mine.rows.first?.loadPct ?? 0) > 100, "the load was clamped")
        #expect(mine.rows.first?.overbooked == true)
        #expect(mine.rows.first?.daysToClear == 25)
    }

    @Test("a voided job stops booking the machine")
    func voidedStopsBooking() throws {
        let js = try js()
        try check([machine("M-1", "One")],
                  [job("M-1", hours: 10), job("M-1", hours: 90, voided: true)],
                  "one real, one cancelled", js)
    }

    @Test("a machine with no target is still on the list, and its hours are held apart")
    func untargetedIsVisible() throws {
        // A shop that had not filled that field in saw an empty panel while its
        // queue grew.
        let js = try js()
        try check([machine("M-1", "Targeted"), machine("M-2", "No target", target: .number(0)),
                   machine("M-3", "Missing", target: .null)],
                  [job("M-1", hours: 20), job("M-2", hours: 40), job("M-3", hours: 5),
                   job("", hours: 12)],
                  "targets and none", js)
    }

    @Test("work that names no machine is still work")
    func unassignedIsCounted() throws {
        // Dropping it is how a queue grows behind a panel reading 40%.
        let js = try js()
        try check([machine("M-1", "One")],
                  [job("", hours: 30), job("M-9", hours: 15), job("M-1", hours: 10)],
                  "unassigned and unknown", js)
    }

    @Test("only agreed, unfinished work is booked")
    func bookedStatuses() throws {
        let js = try js()
        var orders: [JSONValue] = []
        for status in ["pending", "printing", "post", "qc", "on_hold",
                       "quote", "completed", "delivered", "cancelled", ""] {
            orders.append(job("M-1", hours: 3, status: status))
        }
        try check([machine("M-1", "One")], orders, "every status", js)
    }

    @Test("no machine has a target at all, which is a thing to say")
    func noTargetsAtAll() throws {
        let js = try js()
        try check([machine("M-1", "One", target: .number(0))],
                  [job("M-1", hours: 10)], "no targets", js)
        try check([], [], "no machines at all", js)
        let mine = Capacity.report(machines: [machine("M-1", "One", target: .number(0))],
                                   orders: [job("M-1", hours: 10)], hours: [10])
        #expect(mine.totals.noTargets)
        #expect(mine.totals.loadPct == nil, "a percentage of nothing")
        #expect(mine.totals.untargeted == 10)
    }

    @Test("the window, including the ones that are not windows")
    func windows() throws {
        let js = try js()
        for days in [7.0, 1, 30, 0, -5, 0.5] {
            try check([machine("M-1", "One")], [job("M-1", hours: 40)],
                      days: days, "\(days) days", js)
        }
    }

    @Test("machines and jobs that are not what they should be")
    func degenerate() throws {
        let js = try js()
        try check([.null, .string("x"), .number(1), .object([:]),
                   .object(["id": .string("M-1")]),
                   .object(["id": .number(7), "name": .number(9),
                            "targetHoursPerDay": .string("4")])],
                  [.null, .string("x"), .object([:]),
                   .object(["status": .string("pending"), "printTime": .string("6")]),
                   .object(["status": .string("pending"), "machineId": .number(7),
                            "printTime": .number(2)])],
                  "a mess", js)
    }
}
