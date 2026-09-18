import Foundation
import Testing
@testable import KhaytCore

/// Which machine is costing the shop, against the JavaScript it came from.
///
/// "Replace the old one" is a decision worth thousands, so the case that
/// matters most is the one where ranking the wrong way names the wrong
/// printer.
@MainActor
struct MachineReliabilityParityTests {

    private func js() throws -> JSModule { try JSModule(["machine-reliability"]) }

    private func check(_ machines: [JSONValue], _ orders: [JSONValue], _ waste: [JSONValue],
                       from: String = "", to: String = "", unassigned: String = "Unassigned",
                       _ what: String, _ js: JSModule) throws {
        let mine = MachineReliability.report(machines: machines, orders: orders, waste: waste,
                                             from: from, to: to, unassigned: unassigned)
        let v = try js.value("""
            globalThis.KhaytMachineReliability.machineReliability({
              machines: ARG0, orders: ARG1, waste: ARG2,
              from: ARG3, to: ARG4, unassigned: ARG5,
            }, {})
            """, [.array(machines), .array(orders), .array(waste),
                  .string(from), .string(to), .string(unassigned)])
        guard case .object(let o) = v, case .array(let rows)? = o["rows"],
              case .object(let t)? = o["totals"] else {
            Issue.record("not a report"); return
        }
        func row(_ value: JSONValue) -> MachineReliability.Row {
            guard case .object(let r) = value else {
                return .init(machineId: "?", name: "?", color: "?", jobs: -1, grams: -1,
                             hours: -1, scraps: -1, scrapGrams: -1, scrapCost: -1,
                             scrapRate: nil, worstFault: nil)
            }
            var rate: Double?; if case .number(let n)? = r["scrapRate"] { rate = n }
            var fault: MachineReliability.Fault?
            if case .object(let f)? = r["worstFault"] {
                fault = .init(type: JSSemantics.text(f["type"]),
                              grams: JSSemantics.number(f["grams"]))
            }
            return .init(machineId: JSSemantics.text(r["machineId"]),
                         name: JSSemantics.text(r["name"]),
                         color: JSSemantics.text(r["color"]),
                         jobs: Int(JSSemantics.number(r["jobs"])),
                         grams: JSSemantics.number(r["grams"]),
                         hours: JSSemantics.number(r["hours"]),
                         scraps: Int(JSSemantics.number(r["scraps"])),
                         scrapGrams: JSSemantics.number(r["scrapGrams"]),
                         scrapCost: JSSemantics.number(r["scrapCost"]),
                         scrapRate: rate, worstFault: fault)
        }
        var rate: Double?; if case .number(let n)? = t["scrapRate"] { rate = n }
        var worst: MachineReliability.Row?
        if case .object? = t["worst"], let w = t["worst"] { worst = row(w) }
        let theirs = MachineReliability.Report(rows: rows.map(row), totals: .init(
            jobs: Int(JSSemantics.number(t["jobs"])),
            grams: JSSemantics.number(t["grams"]),
            scrapGrams: JSSemantics.number(t["scrapGrams"]),
            scraps: Int(JSSemantics.number(t["scraps"])),
            scrapCost: JSSemantics.number(t["scrapCost"]),
            scrapRate: rate, worst: worst))
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine.rows.map { ($0.machineId, $0.scrapRate) }) worst=\(mine.totals.worst?.machineId ?? "-")
              js    \(theirs.rows.map { ($0.machineId, $0.scrapRate) }) worst=\(theirs.totals.worst?.machineId ?? "-")
            """))
    }

    private func machine(_ id: String, _ name: String) -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "color": .string("#112233")])
    }

    private func job(_ machineId: String, grams: Double, hours: Double,
                     date: String = "2026-09-01", status: String = "completed",
                     voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "status": .string(status), "date": .string(date),
            "parts": .array([.object(["printWeight": .number(grams),
                                      "supportWeight": .number(0),
                                      "printTime": .number(hours),
                                      "qty": .number(1)])]),
        ]
        if !machineId.isEmpty { o["machineId"] = .string(machineId) }
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    private func scrap(_ machineId: String, weight: Double, cost: Double = 0,
                       fault: String = "warping", date: String = "2026-09-02") -> JSONValue {
        var w: [String: JSONValue] = ["weight": .number(weight), "cost": .number(cost),
                                      "date": .string(date)]
        if !machineId.isEmpty { w["machineId"] = .string(machineId) }
        if !fault.isEmpty { w["failureType"] = .string(fault) }
        return .object(w)
    }

    @Test("the busiest machine is not the worst one")
    func rateNotGrams() throws {
        // A printer that ran nine hundred hours and scrapped two kilos is doing
        // better than one that ran ninety and scrapped one. Ranking by grams
        // always names the busiest machine, which is the wrong printer to sell.
        let js = try js()
        try check([machine("M-1", "Busy"), machine("M-2", "Bad")],
                  [job("M-1", grams: 900_000, hours: 900),
                   job("M-1", grams: 900_000, hours: 900),
                   job("M-2", grams: 90_000, hours: 90),
                   job("M-2", grams: 90_000, hours: 90)],
                  [scrap("M-1", weight: 2000), scrap("M-2", weight: 1000)],
                  "busy versus bad", js)
        let mine = MachineReliability.report(
            machines: [machine("M-1", "Busy"), machine("M-2", "Bad")],
            orders: [job("M-1", grams: 900_000, hours: 900),
                     job("M-1", grams: 900_000, hours: 900),
                     job("M-2", grams: 90_000, hours: 90),
                     job("M-2", grams: 90_000, hours: 90)],
            waste: [scrap("M-1", weight: 2000), scrap("M-2", weight: 1000)])
        #expect(mine.rows.first?.machineId == "M-2", "ranked by grams, not by rate")
        #expect(mine.totals.worst?.machineId == "M-2")
    }

    @Test("a machine that has run twice is not evidence of anything")
    func worstNeedsEnoughJobs() throws {
        let js = try js()
        try check([machine("M-1", "One job only"), machine("M-2", "Several")],
                  [job("M-1", grams: 100, hours: 1),
                   job("M-2", grams: 1000, hours: 10),
                   job("M-2", grams: 1000, hours: 10)],
                  [scrap("M-1", weight: 900), scrap("M-2", weight: 50)],
                  "one job against several", js)
        let mine = MachineReliability.report(
            machines: [machine("M-1", "One job only"), machine("M-2", "Several")],
            orders: [job("M-1", grams: 100, hours: 1),
                     job("M-2", grams: 1000, hours: 10),
                     job("M-2", grams: 1000, hours: 10)],
            waste: [scrap("M-1", weight: 900), scrap("M-2", weight: 50)])
        #expect(mine.rows.first?.machineId == "M-1", "the worst RATE is still first")
        #expect(mine.totals.worst?.machineId == "M-2",
                "a machine with one job was named as the one to replace")
    }

    @Test("scrap that names no machine is still scrap")
    func unassignedIsCounted() throws {
        // Hiding it makes the shop's total look better than it is.
        let js = try js()
        try check([machine("M-1", "One")],
                  [job("M-1", grams: 1000, hours: 10)],
                  [scrap("", weight: 300), scrap("M-9", weight: 100),
                   scrap("M-1", weight: 50)],
                  "unassigned and unknown", js)
    }

    @Test("the denominator is everything the machine consumed")
    func rateIsOfWhatItHandled() throws {
        // A machine that scrapped half its filament reads as 50%, not 100%.
        let js = try js()
        try check([machine("M-1", "Half")],
                  [job("M-1", grams: 500, hours: 5)],
                  [scrap("M-1", weight: 500)], "half scrapped", js)
        let mine = MachineReliability.report(
            machines: [machine("M-1", "Half")],
            orders: [job("M-1", grams: 500, hours: 5)],
            waste: [scrap("M-1", weight: 500)])
        #expect(mine.rows.first?.scrapRate == 0.5)
    }

    @Test("what it keeps doing wrong, by grams")
    func worstFault() throws {
        let js = try js()
        try check([machine("M-1", "One")],
                  [job("M-1", grams: 1000, hours: 10)],
                  [scrap("M-1", weight: 100, fault: "stringing"),
                   scrap("M-1", weight: 400, fault: "warping"),
                   scrap("M-1", weight: 50, fault: "warping"),
                   scrap("M-1", weight: 30, fault: "")],
                  "three faults", js)
    }

    @Test("the window, and work outside it")
    func windows() throws {
        let js = try js()
        let book = [job("M-1", grams: 100, hours: 1, date: "2026-07-01"),
                    job("M-1", grams: 200, hours: 2, date: "2026-09-10"),
                    job("M-1", grams: 300, hours: 3, date: "2026-12-01"),
                    job("M-1", grams: 400, hours: 4, status: "printing"),
                    job("M-1", grams: 500, hours: 5, voided: true)]
        let bin = [scrap("M-1", weight: 10, date: "2026-07-02"),
                   scrap("M-1", weight: 20, date: "2026-09-11"),
                   scrap("M-1", weight: 30, date: ""),
                   scrap("M-1", weight: 40, date: "2026-12-02")]
        for (from, to) in [("", ""), ("2026-09-01", "2026-09-30"),
                           ("2026-09-01", ""), ("", "2026-08-31")] {
            try check([machine("M-1", "One")], book, bin, from: from, to: to,
                      "\(from.debugDescription)…\(to.debugDescription)", js)
        }
    }

    @Test("a part with no quantity counts once, not none")
    func quantityFloor() throws {
        // `Math.max(1, num(qty) || 1)`.
        let js = try js()
        try check([machine("M-1", "One")],
                  [.object(["machineId": .string("M-1"), "status": .string("completed"),
                            "date": .string("2026-09-01"),
                            "parts": .array([
                                .object(["printWeight": .number(100), "printTime": .number(1)]),
                                .object(["printWeight": .number(100), "printTime": .number(1),
                                         "qty": .number(0)]),
                                .object(["printWeight": .number(100), "printTime": .number(1),
                                         "qty": .number(3)]),
                                .object(["printWeight": .number(100), "printTime": .number(1),
                                         "qty": .string("2")]),
                                .string("not a part"), .null,
                            ])])],
                  [], "quantities", js)
    }

    @Test("machines and scrap that are not what they should be")
    func degenerate() throws {
        let js = try js()
        try check([.null, .string("x"), .object([:]), .object(["id": .string("M-1")]),
                   .object(["id": .number(7), "name": .number(9), "color": .number(1)])],
                  [.null, .string("x"), .object([:]),
                   .object(["status": .string("completed"), "date": .string("2026-09-01"),
                            "parts": .string("not a list")])],
                  [.null, .string("x"), .object([:]),
                   .object(["weight": .string("40"), "date": .string("2026-09-01")])],
                  "a mess", js)
        try check([], [], [], "nothing at all", js)
    }
}
