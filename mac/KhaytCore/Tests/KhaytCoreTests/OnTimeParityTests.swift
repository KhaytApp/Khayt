import Foundation
import Testing
@testable import KhaytCore

/// Whether the shop keeps its promises, against the JavaScript it came from.
///
/// This is the figure a shop quotes to a customer who asks "are you reliable",
/// so the two apps disagreeing about it is worse than either being wrong on
/// its own. The corpus is mostly about the boundaries: a job finished ON its
/// due date, a job with no date at all, and the two different ways the module
/// reads a day.
@MainActor
struct OnTimeParityTests {

    private func js() throws -> JSModule { try JSModule(["on-time", "business-scope"]) }

    private func theirs(_ js: JSModule, _ orders: [JSONValue],
                        since: String?) throws -> OnTime.Record {
        let answer = try js.value("""
            globalThis.KhaytOnTime.onTime(ARG0, {
              countsForBusiness: globalThis.KhaytBusinessScope.countsForBusiness,
              since: ARG1 || undefined,
            })
            """, [.array(orders), since.map(JSONValue.string) ?? .null])
        guard case .object(let o) = answer else {
            Issue.record("not an object")
            return OnTime.Record(promised: -1, onTime: -1, late: -1, rate: nil,
                                 avgDelayDays: nil, worstDelayDays: nil, lateJobs: [])
        }
        func int(_ v: JSONValue?) -> Int { if case .number(let n)? = v { return Int(n) }; return -1 }
        func dbl(_ v: JSONValue?) -> Double? { if case .number(let n)? = v { return n }; return nil }
        var jobs: [OnTime.LateJob] = []
        if case .array(let rows)? = o["lateJobs"] {
            jobs = rows.map { row in
                guard case .object(let r) = row, case .string(let id)? = r["id"],
                      case .string(let p)? = r["project"], case .string(let due)? = r["dueDate"],
                      case .string(let fin)? = r["finishedDay"] else {
                    Issue.record(Comment(rawValue: "a late job did not survive JSON: \(row)"))
                    return OnTime.LateJob(id: "«lost»", project: "", dueDate: "",
                                          finishedDay: "", delayDays: -1)
                }
                return OnTime.LateJob(id: id, project: p, dueDate: due, finishedDay: fin,
                                      delayDays: int(r["delayDays"]))
            }
        }
        return OnTime.Record(promised: int(o["promised"]), onTime: int(o["onTime"]),
                             late: int(o["late"]), rate: dbl(o["rate"]),
                             avgDelayDays: dbl(o["avgDelayDays"]),
                             worstDelayDays: dbl(o["worstDelayDays"]).map(Int.init),
                             lateJobs: jobs)
    }

    private func check(_ orders: [JSONValue], since: String? = nil,
                       _ what: String, _ js: JSModule) throws {
        let mine = OnTime.record(orders, since: since)
        let theirs = try theirs(js, orders, since: since)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    private func job(_ id: String, due: JSONValue?, done: JSONValue?,
                     status: String = "completed", extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status),
                                      "project": .string("P-" + id)]
        if let due { o["dueDate"] = due }
        if let done { o["completedAt"] = done }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("a real quarter of promises")
    func realQuarter() throws {
        let js = try js()
        try check([
            job("A", due: .string("2026-09-10"), done: .string("2026-09-08")),
            job("B", due: .string("2026-09-10"), done: .string("2026-09-10")),
            job("C", due: .string("2026-09-01"), done: .string("2026-09-06")),
            job("D", due: .string("2026-08-20"), done: .string("2026-09-02")),
            job("E", due: .string("2026-08-30"), done: .string("2026-08-31"),
                status: "delivered"),
            job("F", due: .null, done: .string("2026-09-01")),
        ], "a quarter", js)
    }

    @Test("finished ON the due date is kept, not late")
    func onTheDayIsKept() throws {
        let js = try js()
        for (due, done) in [("2026-09-10", "2026-09-09"), ("2026-09-10", "2026-09-10"),
                            ("2026-09-10", "2026-09-11"), ("2026-12-31", "2027-01-01"),
                            ("2026-02-28", "2026-03-01"), ("2024-02-28", "2024-02-29")] {
            try check([job("A", due: .string(due), done: .string(done))],
                      "due \(due) done \(done)", js)
        }
        #expect(OnTime.record([job("A", due: .string("2026-09-10"),
                                   done: .string("2026-09-10"))]).late == 0,
                "a job finished on its due date was called late")
    }

    @Test("the two ways a day is read, which are not the same way")
    func dayReadingMatches() throws {
        // `^\d{4}-\d{2}-\d{2}$` is anchored at BOTH ends here, so a full
        // timestamp is parsed and read locally rather than sliced.
        let js = try js()
        for value in ["2026-09-10", "2026-09-10T00:00:00Z", "2026-09-10T23:30:00Z",
                      "2026-09-10T00:00:00", "2026-09-10T02:00:00+05:00",
                      "2026-09-10 ", " 2026-09-10", "2026-09-10T", "2026-09",
                      "2026", "not a date", ""] {
            try check([job("A", due: .string(value), done: .string("2026-09-10")),
                       job("B", due: .string("2026-09-10"), done: .string(value))],
                      "value \(value)", js)
        }
    }

    @Test("only finished, un-voided, business work is counted")
    func scopeMatches() throws {
        let js = try js()
        var orders: [JSONValue] = []
        for status in ["completed", "delivered", "quote", "pending", "printing", "post",
                       "qc", "on_hold", "cancelled", "split", "shipped", ""] {
            orders.append(job("S-" + status, due: .string("2026-09-01"),
                              done: .string("2026-09-05"), status: status))
        }
        orders.append(job("voided", due: .string("2026-09-01"), done: .string("2026-09-05"),
                          extra: ["voidedAt": .string("2026-09-06")]))
        orders.append(job("notrade", due: .string("2026-09-01"), done: .string("2026-09-05"),
                          extra: ["nonBusiness": .bool(true)]))
        // `!== true`, so these all still count.
        for value in [JSONValue.string("yes"), .number(1), .string("true"), .null, .bool(false)] {
            orders.append(job("nb-\(value)", due: .string("2026-09-01"),
                              done: .string("2026-09-05"),
                              extra: ["nonBusiness": value]))
        }
        try check(orders, "every scope", js)
    }

    @Test("a since cuts on the job's own date, and excludes one with no date")
    func sinceMatches() throws {
        let js = try js()
        let orders = [
            job("A", due: .string("2026-09-01"), done: .string("2026-09-05"),
                extra: ["date": .string("2026-08-01")]),
            job("B", due: .string("2026-09-01"), done: .string("2026-09-05"),
                extra: ["date": .string("2026-09-01")]),
            job("C", due: .string("2026-09-01"), done: .string("2026-09-05"),
                extra: ["date": .string("2026-10-01")]),
            job("D", due: .string("2026-09-01"), done: .string("2026-09-05")),
        ]
        for since in [nil, "2026-09-01", "2026-01-01", "2027-01-01", ""] {
            try check(orders, since: since, "since \(since ?? "nil")", js)
        }
    }

    @Test("which stamp says a job is finished, and in which order")
    func finishedPrecedence() throws {
        let js = try js()
        try check([
            .object(["id": .string("A"), "status": .string("completed"),
                     "dueDate": .string("2026-09-01"), "completedAt": .string("2026-09-05"),
                     "deliveredAt": .string("2026-09-09"), "date": .string("2026-09-20")]),
            .object(["id": .string("B"), "status": .string("delivered"),
                     "dueDate": .string("2026-09-01"), "deliveredAt": .string("2026-09-09"),
                     "date": .string("2026-09-20")]),
            .object(["id": .string("C"), "status": .string("completed"),
                     "dueDate": .string("2026-09-01"), "date": .string("2026-09-20")]),
            .object(["id": .string("D"), "status": .string("completed"),
                     "dueDate": .string("2026-09-01"), "completedAt": .string(""),
                     "date": .string("2026-09-20")]),
            .object(["id": .string("E"), "status": .string("completed"),
                     "dueDate": .string("2026-09-01"), "completedAt": .string("rubbish")]),
        ], "precedence", js)
    }

    @Test("late jobs are worst first, and a tie keeps the book's order")
    func sortMatches() throws {
        let js = try js()
        try check([
            job("A", due: .string("2026-09-01"), done: .string("2026-09-03")),
            job("B", due: .string("2026-09-01"), done: .string("2026-09-11")),
            job("C", due: .string("2026-09-01"), done: .string("2026-09-03")),
            job("D", due: .string("2026-09-01"), done: .string("2026-09-05")),
            job("E", due: .string("2026-09-01"), done: .string("2026-09-03")),
        ], "five late jobs, three tied", js)
    }

    @Test("nothing promised is nothing to report, not nought per cent")
    func nullRatesMatch() throws {
        let js = try js()
        try check([], "no orders", js)
        try check([job("A", due: .null, done: .string("2026-09-05"))], "nothing promised", js)
        try check([job("A", due: .string("2026-09-10"), done: .string("2026-09-01"))],
                  "all kept", js)
        #expect(OnTime.record([]).rate == nil, "0% of no promises is not a record")
        #expect(OnTime.record([]).avgDelayDays == nil)
        #expect(OnTime.record([]).worstDelayDays == nil)
    }

    @Test("rows that are not orders")
    func degenerateRows() throws {
        let js = try js()
        try check([.null, .bool(false), .number(0), .string(""), .string("x"),
                   .number(3), .array([]), .bool(true),
                   job("A", due: .string("2026-09-01"), done: .string("2026-09-05"))],
                  "a mix", js)
    }

    @Test("a long delay, and a delay across a year end")
    func longDelays() throws {
        let js = try js()
        try check([job("A", due: .string("2025-12-28"), done: .string("2026-03-15")),
                   job("B", due: .string("2026-01-01"), done: .string("2026-01-02")),
                   job("C", due: .string("2024-02-28"), done: .string("2024-03-01"))],
                  "long delays", js)
    }
}
