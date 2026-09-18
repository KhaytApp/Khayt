import Foundation
import Testing
@testable import KhaytCore

/// When the queue will finish, against the JavaScript it came from.
///
/// This is what tells a shop on Tuesday that Friday's job will not make it —
/// while there is still time to move it, split it, or ring the customer. A
/// projection that is a day out is a phone call not made.
@MainActor
struct ScheduleParityTests {

    private func js() throws -> JSModule { try JSModule(["schedule"]) }

    private func theirs(_ js: JSModule, _ jobs: [JSONValue], daily: Double,
                        start: String) throws -> Schedule.Timeline {
        guard case .object(let o) = try js.value("""
            globalThis.KhaytSchedule.computeSchedule({ jobs: ARG0, dailyHours: ARG1, startDate: ARG2 })
            """, [.array(jobs), .number(daily), .string(start)]) else {
            Issue.record("not an object")
            return Schedule.Timeline(machines: [], generatedAt: "«?»", dailyHours: -1)
        }
        func num(_ v: JSONValue?) -> Double { if case .number(let n)? = v { return n }; return .nan }
        /// `Int(Double.nan)` TRAPS, and a field JSON dropped comes back as
        /// `null` — so the reader itself crashed the suite before the port
        /// could be compared. Saturating here keeps a lost field visible as a
        /// difference instead of as a dead process.
        func int(_ v: JSONValue?) -> Int { Schedule.days(num(v)) }
        func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { return s }; return "«?»" }
        var machines: [Schedule.Machine] = []
        if case .array(let rows)? = o["machines"] {
            machines = rows.map { row in
                guard case .object(let m) = row else {
                    Issue.record(Comment(rawValue: "a machine did not survive JSON: \(row)"))
                    return Schedule.Machine(machineId: "«lost»", unassigned: false, jobs: [],
                                            totalHours: .nan, days: -1, readyDate: "", lateCount: -1)
                }
                var jobs: [Schedule.Job] = []
                if case .array(let js)? = m["jobs"] {
                    jobs = js.map { jr in
                        guard case .object(let j) = jr else {
                            Issue.record("a job did not survive JSON")
                            return Schedule.Job(id: "«lost»", project: "", status: "", hours: .nan,
                                                startDay: -1, etaDate: "", dueDate: "", late: false)
                        }
                        var late = false; if case .bool(let b)? = j["late"] { late = b }
                        return Schedule.Job(id: str(j["id"]), project: str(j["project"]),
                                            status: str(j["status"]), hours: num(j["hours"]),
                                            startDay: int(j["startDay"]),
                                            etaDate: str(j["etaDate"]), dueDate: str(j["dueDate"]),
                                            late: late)
                    }
                }
                var un = false; if case .bool(let b)? = m["unassigned"] { un = b }
                return Schedule.Machine(machineId: str(m["machineId"]), unassigned: un, jobs: jobs,
                                        totalHours: num(m["totalHours"]),
                                        days: int(m["days"]), readyDate: str(m["readyDate"]),
                                        lateCount: int(m["lateCount"]))
            }
        }
        return Schedule.Timeline(machines: machines, generatedAt: str(o["generatedAt"]),
                                 dailyHours: num(o["dailyHours"]))
    }

    private func check(_ jobs: [JSONValue], daily: Double = 8, start: String = "2026-09-17",
                       _ what: String, _ js: JSModule) throws {
        let mine = Schedule.compute(jobs: jobs, dailyHours: daily, startDate: start)
        let theirs = try theirs(js, jobs, daily: daily, start: start)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    private func job(_ id: String, _ hours: JSONValue, machine: JSONValue? = nil,
                     due: String? = nil) -> JSONValue {
        var j: [String: JSONValue] = ["id": .string(id), "hours": hours,
                                      "project": .string("P-" + id),
                                      "status": .string("pending")]
        if let machine { j["machineId"] = machine }
        if let due { j["dueDate"] = .string(due) }
        return .object(j)
    }

    @Test("a real queue across three machines")
    func realQueue() throws {
        let js = try js()
        try check([
            job("A", .number(23.7), machine: .string("M1"), due: "2026-09-24"),
            job("B", .number(6.2), machine: .string("M1"), due: "2026-11-12"),
            job("C", .number(18.1), machine: .string("M2"), due: "2026-10-01"),
            job("D", .number(14.9), machine: .string("M1"), due: "2026-09-16"),
            job("E", .number(5.1), machine: .string("M2")),
            job("F", .number(2.6)),
        ], "three machines", js)
    }

    @Test("a job of any length still lands on day one, not today")
    func anyHoursIsAtLeastADay() throws {
        // Something that takes twenty minutes is still not ready today.
        let js = try js()
        for hours in [0.0, 0.01, 0.1, 0.33, 1, 7.9, 8, 8.1, 16, 24] {
            try check([job("A", .number(hours), machine: .string("M1"))],
                      "\(hours) hours", js)
        }
        let one = Schedule.compute(jobs: [job("A", .number(0.1), machine: .string("M1"))],
                                   dailyHours: 8, startDate: "2026-09-17")
        #expect(one.machines.first?.jobs.first?.etaDate == "2026-09-18",
                "a short job was called ready today")
        let none = Schedule.compute(jobs: [job("A", .number(0), machine: .string("M1"))],
                                    dailyHours: 8, startDate: "2026-09-17")
        #expect(none.machines.first?.jobs.first?.etaDate == "2026-09-17",
                "a job of no hours moved the date")
    }

    @Test("the daily rate falls back and then clamps, in that order")
    func dailyRateMatches() throws {
        // `Math.max(1, +dailyHours || 8)` — 0 and NaN become 8; a negative is
        // clamped to 1, not to 8.
        let js = try js()
        for daily in [8.0, 1, 0, -5, 0.5, 24, 100, 1e-9] {
            try check([job("A", .number(20), machine: .string("M1")),
                       job("B", .number(5), machine: .string("M1"))],
                      daily: daily, "daily \(daily)", js)
        }
    }

    @Test("unassigned jobs share one lane, and it sorts last")
    func unassignedLane() throws {
        let js = try js()
        try check([
            job("A", .number(2)),
            job("B", .number(3), machine: .string("M1")),
            job("C", .number(4)),
            job("D", .number(1), machine: .string("")),
            job("E", .number(1), machine: .null),
        ], "an unassigned lane", js)
        // Even when it is the busiest — `(a.unassigned - b.unassigned)` comes
        // first in the comparator.
        try check([job("A", .number(100)), job("B", .number(1), machine: .string("M1"))],
                  "unassigned is busiest", js)
    }

    @Test("machines with equal hours keep the order the queue arrived in")
    func tiesAreStable() throws {
        let js = try js()
        try check([job("A", .number(5), machine: .string("Zebra")),
                   job("B", .number(5), machine: .string("Apple")),
                   job("C", .number(5), machine: .string("Mango"))],
                  "three at five hours", js)
    }

    @Test("a due date is compared as a string, and an absent one is never late")
    func latenessMatches() throws {
        let js = try js()
        for due in ["2026-09-17", "2026-09-18", "2026-09-19", "2026-01-01",
                    "2027-01-01", "", "not a date", "2026-9-18"] {
            try check([job("A", .number(8), machine: .string("M1"), due: due)],
                      "due \(due)", js)
        }
        try check([job("A", .number(8), machine: .string("M1"))], "no due date", js)
    }

    @Test("the start date rolls the month and the year over")
    func startDatesMatch() throws {
        let js = try js()
        for start in ["2026-09-17", "2026-12-28", "2026-01-31", "2024-02-27",
                      "2026-02-27", "2026-12-31"] {
            try check([job("A", .number(40), machine: .string("M1"))],
                      start: start, "from \(start)", js)
        }
    }

    @Test("a start date that is not a date comes back unchanged")
    func badStartDates() throws {
        // `addDays` returns its input when the date will not parse, rather
        // than guessing — so every ETA reads as the same nonsense the caller
        // supplied rather than as a plausible wrong day.
        let js = try js()
        for start in ["not a date", "2026", "2026-09", "2026-13-40", "",
                      "2026-09-17T00:00:00Z"] {
            try check([job("A", .number(8), machine: .string("M1"))],
                      start: start, "from \(start.debugDescription)", js)
        }
    }

    @Test("hours that are not numbers")
    func oddHours() throws {
        let js = try js()
        // `"Infinity"` is the divergence test below: both sides carry it and
        // only JSON loses it.
        let numbers = Awkward.numbers.filter { $0.isFinite && abs($0) < 1e6 }
        let notNumbers = Awkward.notNumbers.filter { $0 != .string("Infinity") }
        for value in notNumbers + numbers.map({ JSONValue.number($0) }) {
            try check([job("A", value, machine: .string("M1")),
                       job("B", .number(4), machine: .string("M1"))],
                      "hours \(value)", js)
        }
    }

    /// ── AN INFINITE JOB, WHICH BREAKS BOTH SIDES DIFFERENTLY ──────────────
    ///
    /// `+j.hours || 0` keeps a truthy infinity, so the book CAN hold a job
    /// whose hours are infinite — a weight field filled in as `"Infinity"`, or
    /// two enormous jobs summing past `Double`'s range.
    ///
    /// The ORIGINAL then throws: the day count is infinite, `setUTCDate` makes
    /// an invalid date, and `toISOString()` raises a RangeError. The whole
    /// board is lost, not one row.
    ///
    /// The PORT crashed, which is worse. `Int(Double.infinity)` traps, and
    /// once that was saturated the saturated count overflowed the day
    /// arithmetic and trapped again. Both were found by the harness putting
    /// `"Infinity"` in the hours, and neither would have been written by hand.
    ///
    /// It now degrades the way `addDays` already degrades for a date it cannot
    /// parse: that job keeps the start date, and every other job on the board
    /// still has its own.
    @Test("an infinite job loses the board in JavaScript, and loses one row here")
    func infiniteHoursAreSurvivable() throws {
        let js = try js()
        let jobs = [job("A", .string("Infinity"), machine: .string("M1")),
                    job("B", .number(4), machine: .string("M2"))]
        let mine = Schedule.compute(jobs: jobs, dailyHours: 8, startDate: "2026-09-17")
        #expect(mine.machines.count == 2, "the board was lost, not just a row")
        // The healthy machine is unaffected and still has a real date.
        let healthy = mine.machines.first { $0.machineId == "M2" }
        #expect(healthy?.jobs.first?.etaDate == "2026-09-18",
                Comment(rawValue: "the other machine lost its date: \(healthy?.jobs.first?.etaDate ?? "nil")"))
        // And the impossible one says the start date rather than a guess.
        let broken = mine.machines.first { $0.machineId == "M1" }
        #expect(broken?.jobs.first?.etaDate == "2026-09-17")

        // The original: an exception, which the harness reports as no answer.
        var threw = false
        do {
            _ = try js.value("""
                globalThis.KhaytSchedule.computeSchedule({ jobs: ARG0, dailyHours: 8, startDate: ARG1 })
                """, [.array(jobs), .string("2026-09-17")])
        } catch { threw = true }
        #expect(threw, "the original no longer throws — this divergence can go")
    }

    @Test("no jobs at all")
    func emptyQueue() throws {
        try check([], "an empty queue", try js())
    }

    /// ── ROWS THAT ARE NOT JOBS, WHICH THE ORIGINAL DOES NOT EXPECT ────────
    ///
    /// `for (const j of jobs) { const mid = j.machineId || … }` reads a
    /// property off every row:
    ///
    ///   * a `null` row has none, so the original THROWS and the whole board
    ///     is lost;
    ///   * a truthy non-object — a string, a number, `true` — answers
    ///     `undefined` for every field, so the original invents a PHANTOM JOB
    ///     in the unassigned lane with no id and no hours.
    ///
    /// The port skips both: a row that is not a job is not a job, and a lane
    /// full of nameless phantoms is worse than a board that quietly ignores
    /// nonsense. Pinned both ways.
    @Test("a row that is not a job is skipped here, where the original throws or invents one")
    func nonJobRowsAreWhereThePortDiverges() throws {
        let js = try js()
        let real = job("A", .number(4), machine: .string("M1"))

        // A null row: the original throws.
        let withNull: [JSONValue] = [.null, real]
        let mine = Schedule.compute(jobs: withNull, dailyHours: 8, startDate: "2026-09-17")
        #expect(mine.machines.count == 1, "the real job was lost with the null row")
        var threw = false
        do { _ = try theirs(js, withNull, daily: 8, start: "2026-09-17") } catch { threw = true }
        #expect(threw, "the original no longer throws on a null row")

        // A truthy non-object: the original invents a job.
        for row in [JSONValue.string("x"), .number(3), .bool(true), .array([])] {
            let queue: [JSONValue] = [row, real]
            let ours = Schedule.compute(jobs: queue, dailyHours: 8, startDate: "2026-09-17")
            #expect(ours.machines.count == 1,
                    Comment(rawValue: "a phantom lane appeared for \(row)"))
            let theirs = try theirs(js, queue, daily: 8, start: "2026-09-17")
            #expect(theirs.machines.count == 2, Comment(rawValue:
                "the original stopped inventing a job for \(row) — this divergence can go"))
        }
    }

    @Test("a long queue accumulates the same way")
    func longQueueMatches() throws {
        // Rounding a running total is not rounding a sum, and this is where
        // the two would drift if they differed.
        let js = try js()
        try check((1...30).map { job("J\($0)", .number(Double($0) / 3.0),
                                     machine: .string("M\($0 % 3)")) },
                  "thirty jobs of a third of an hour apart", js)
    }
}
