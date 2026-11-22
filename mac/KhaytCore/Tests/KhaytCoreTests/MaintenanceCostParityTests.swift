import Foundation
import Testing
@testable import KhaytCore

/// What each machine cost to keep running, against the JavaScript it came from.
///
/// The module exists because the chart before it read `machine.machMaintLog` —
/// a property Khayt has never written — so it said "No data yet" however many
/// services a shop had logged. A port that reads the wrong thing is that bug
/// again, and the two subtleties below are the ones that would make it read
/// *almost* right.
@MainActor
struct MaintenanceCostParityTests {

    private func js() throws -> JSModule { try JSModule(["maintenance-cost"]) }

    private func theirs(_ js: JSModule, _ machines: [JSONValue], _ entries: [JSONValue],
                        year: String?) throws -> [MaintenanceCost.Row] {
        guard case .array(let rows) = try js.value(
            "globalThis.KhaytMaintenanceCost.byMachine(ARG0, ARG1, { year: ARG2 })",
            [.array(machines), .array(entries), year.map(JSONValue.string) ?? .null])
        else { Issue.record("not an array"); return [] }
        return rows.map { row in
            guard case .object(let r) = row, case .string(let id)? = r["machineId"],
                  case .string(let name)? = r["name"], case .bool(let orphan)? = r["orphan"],
                  case .number(let total)? = r["total"] else {
                Issue.record(Comment(rawValue: "a row did not survive JSON: \(row)"))
                return MaintenanceCost.Row(machineId: "«lost»", name: "", orphan: false, total: .nan)
            }
            return MaintenanceCost.Row(machineId: id, name: name, orphan: orphan, total: total)
        }
    }

    private func check(_ machines: [JSONValue], _ entries: [JSONValue],
                       year: String? = nil, _ what: String, _ js: JSModule) throws {
        let mine = MaintenanceCost.byMachine(machines: machines, entries: entries, year: year)
        let theirs = try theirs(js, machines, entries, year: year)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    private func machine(_ id: String, _ name: JSONValue? = nil,
                         model: JSONValue? = nil) -> JSONValue {
        var m: [String: JSONValue] = ["id": .string(id)]
        if let name { m["name"] = name }
        if let model { m["model"] = model }
        return .object(m)
    }
    private func entry(_ machineId: JSONValue, _ date: String, _ cost: JSONValue) -> JSONValue {
        .object(["id": .string("M-\(date)"), "machineId": machineId,
                 "date": .string(date), "cost": cost, "note": .string("belt")])
    }

    @Test("a real year of servicing")
    func realYear() throws {
        let js = try js()
        let machines = [machine("MACH-1", .string("Core One")),
                        machine("MACH-2", .string("X1C"))]
        let entries = [
            entry(.string("MACH-1"), "2026-02-11", .number(240)),
            entry(.string("MACH-1"), "2026-07-03", .number(95.50)),
            entry(.string("MACH-2"), "2026-05-20", .number(410)),
            entry(.string("MACH-GONE"), "2026-06-01", .number(88)),
            entry(.string("MACH-2"), "2025-12-30", .number(999)),
        ]
        try check(machines, entries, "everything", js)
        try check(machines, entries, year: "2026", "just 2026", js)
        try check(machines, entries, year: "2025", "just 2025", js)
    }

    @Test("the year is read off the string, not through a date")
    func yearIsSliced() throws {
        // `new Date("2026-01-01").getFullYear()` is midnight UTC read in the
        // reader's own zone — the 31st of December west of Greenwich. A shop
        // in New York would have had its new year's maintenance counted
        // against the year before.
        let js = try js()
        for date in ["2026-01-01", "2026-12-31", "2025-12-31T23:59:59Z",
                     "2026-01-01T00:00:00+14:00", "2026", "2026-01", "not a date",
                     "", "26-01-01", "2026/01/01"] {
            try check([machine("M", .string("One"))],
                      [entry(.string("M"), date, .number(100))],
                      year: "2026", "date \(date) in 2026", js)
            try check([machine("M", .string("One"))],
                      [entry(.string("M"), date, .number(100))],
                      "date \(date), no year", js)
        }
        // Said outright, in both directions.
        #expect(MaintenanceCost.year(of: .string("2026-01-01")) == "2026")
        #expect(MaintenanceCost.year(of: .string("2026")) == "",
                "a malformed date was filed into a year")
    }

    @Test("the tie-break is a locale comparison, not a code-point one")
    func tiesBreakByCollation() throws {
        // `a.name.localeCompare(b.name)` — so "apple" sorts before "Banana"
        // where a plain comparison puts every capital first. A machine list is
        // the shop's own names, often mixed case and often Arabic.
        let js = try js()
        for names in [["Banana", "apple"], ["apple", "Banana"],
                      ["a", "A"], ["A", "a"], ["Zebra", "apple", "Mango"],
                      ["ب", "أ"], ["Core One", "core two"], ["10", "9"],
                      ["", "A"], ["é", "e"], ["e", "é"]] {
            let machines = names.enumerated().map { machine("M\($0.offset)", .string($0.element)) }
            let entries = names.indices.map { entry(.string("M\($0)"), "2026-01-01", .number(100)) }
            try check(machines, entries, "names \(names)", js)
        }
    }

    @Test("a machine the shop has sold keeps its spending, labelled")
    func orphansAreKept() throws {
        // The money left the shop; a chart of what maintenance cost should not
        // quietly shrink because a printer was sold.
        let js = try js()
        try check([machine("MACH-1", .string("Core One"))],
                  [entry(.string("MACH-1"), "2026-01-01", .number(100)),
                   entry(.string("MACH-SOLD"), "2026-01-02", .number(400))],
                  "one sold machine", js)
        let rows = MaintenanceCost.byMachine(
            machines: [machine("MACH-1", .string("Core One"))],
            entries: [entry(.string("MACH-SOLD"), "2026-01-02", .number(400))])
        #expect(rows.first?.orphan == true)
        #expect(rows.first?.name == "MACH-SOLD", "a sold machine lost its label")
    }

    @Test("a machine's name falls back to its model, then to its id")
    func namesFallBack() throws {
        let js = try js()
        // A name that is not a string is the divergence test below: the
        // original has no `.localeCompare` for it and throws.
        try check([machine("A", .string("Named")),
                   machine("B", nil, model: .string("Modelled")),
                   machine("C"),
                   machine("D", .string(""), model: .string(""))],
                  ["A", "B", "C", "D"].map {
                      entry(.string($0), "2026-01-01", .number(100)) },
                  "name fallbacks", js)
    }

    @Test("nothing spent is not a bar")
    func zerosAreDropped() throws {
        let js = try js()
        try check([machine("A", .string("A")), machine("B", .string("B"))],
                  [entry(.string("A"), "2026-01-01", .number(0)),
                   entry(.string("B"), "2026-01-01", .number(-50)),
                   entry(.string("A"), "2026-01-02", .number(10))],
                  "zero and negative", js)
    }

    @Test("a cost that is not a number")
    func oddCosts() throws {
        let js = try js()
        let numbers = Awkward.numbers.filter { $0.isFinite && abs($0) < 1e300 }
        for value in Awkward.notNumbers + numbers.map({ JSONValue.number($0) }) {
            try check([machine("A", .string("A"))],
                      [entry(.string("A"), "2026-01-01", value),
                       entry(.string("A"), "2026-01-02", .number(5))],
                      "cost \(value)", js)
        }
    }

    @Test("a machineId that is not a string, and rows that are not entries")
    func degenerateRows() throws {
        let js = try js()
        try check([machine("A", .string("A"))],
                  [entry(.null, "2026-01-01", .number(10)),
                   entry(.string(""), "2026-01-01", .number(10)),
                   .null, .string("x"), .number(3), .array([]),
                   entry(.string("A"), "2026-01-01", .number(10))],
                  "odd rows", js)
        try check([.null, .string("x"), .object([:]), .object(["id": .string("")])],
                  [entry(.string("A"), "2026-01-01", .number(10))],
                  "odd machines", js)
    }

    /// ── WHERE THE PORT DELIBERATELY DOES NOT AGREE ────────────────────────
    ///
    /// A machine whose `name` is not a string loses the chart, two ways:
    ///
    ///   * `name` comes back as a NUMBER, and `KhaytEngine`'s row decodes it
    ///     as a `String` — so the whole chart fails to decode rather than one
    ///     bar looking odd;
    ///   * and `a.name.localeCompare(b.name)` throws outright when the number
    ///     happens to be the RECEIVER. Whether it is depends on the order the
    ///     engine's sort compares them in, so the same book can throw or not.
    ///
    /// Either way the shop sees nothing. The port coerces, the way everything
    /// else in this file does. Recorded rather than silently improved.
    @Test("a name that is not a string draws here, where the original loses the chart")
    func nonStringNamesAreWhereThePortDiverges() throws {
        let js = try js()
        let cases: [(String, [JSONValue], [JSONValue])] = [
            ("a numeric name", [machine("A", .number(7)), machine("B", .string("B"))],
             [entry(.string("A"), "2026-01-01", .number(10)),
              entry(.string("B"), "2026-01-01", .number(10))]),
            ("a numeric machineId", [machine("A", .string("A"))],
             [entry(.number(7), "2026-01-01", .number(10)),
              entry(.string("A"), "2026-01-01", .number(10))]),
            ("a boolean machineId", [machine("A", .string("A"))],
             [entry(.bool(true), "2026-01-01", .number(10)),
              entry(.string("A"), "2026-01-01", .number(10))]),
        ]
        for (what, machines, entries) in cases {
            // The port: a chart, with every bar labelled.
            let mine = MaintenanceCost.byMachine(machines: machines, entries: entries)
            #expect(!mine.isEmpty, Comment(rawValue: "no chart for \(what)"))
            #expect(mine.allSatisfy { !$0.name.isEmpty },
                    Comment(rawValue: "an unlabelled bar: \(what)"))

            // The original: read RAW, because the comparison reader would
            // report the lost row as a failure of its own.
            var lost = false
            do {
                let answer = try js.value(
                    "globalThis.KhaytMaintenanceCost.byMachine(ARG0, ARG1, {})",
                    [.array(machines), .array(entries)])
                guard case .array(let rows) = answer else { lost = true; return }
                // A `name` that is not a string is one `KhaytEngine`'s row
                // cannot decode, so the chart is lost at the bridge.
                lost = rows.contains { row in
                    guard case .object(let r) = row else { return true }
                    if case .string = r["name"] { return false }
                    return true
                }
            } catch {
                lost = true   // it threw: localeCompare on a number
            }
            #expect(lost, Comment(rawValue:
                "the original now returns a decodable chart for \(what) — "
                + "that divergence can go"))
        }
    }

    @Test("an empty year is every year, not no year")
    func emptyYearIsEveryYear() throws {
        let js = try js()
        let entries = [entry(.string("A"), "2025-01-01", .number(10)),
                       entry(.string("A"), "2026-01-01", .number(20))]
        try check([machine("A", .string("A"))], entries, year: "", "empty year", js)
        try check([machine("A", .string("A"))], entries, year: nil, "no year", js)
        #expect(MaintenanceCost.byMachine(machines: [machine("A", .string("A"))],
                                          entries: entries, year: "").first?.total == 30)
    }

    @Test("nothing at all")
    func emptyInputs() throws {
        let js = try js()
        try check([], [], "no machines and no entries", js)
        try check([machine("A", .string("A"))], [], "no entries", js)
        try check([], [entry(.string("A"), "2026-01-01", .number(10))], "no machines", js)
    }
}
