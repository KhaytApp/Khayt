import Foundation
import Testing
@testable import KhaytCore

/// When work actually finishes, against the JavaScript it came from.
///
/// The grid is read for its SHAPE, so an off-by-one in the weekday moves a
/// shop's whole week and an off-by-one in the hour moves its whole day. Both
/// come out of local-time readers, so the suite is run under several zones.
@MainActor
struct ThroughputParityTests {

    private func js() throws -> JSModule { try JSModule(["throughput"]) }

    private func theirs(_ js: JSModule, _ orders: [JSONValue], openDays: [Bool],
                        minimum: Double?) throws -> Throughput.Grid {
        guard case .object(let o) = try js.value("""
            globalThis.KhaytThroughput.throughput({
              orders: ARG0, openDays: ARG1, minimum: ARG2,
            }, {})
            """, [.array(orders), .array(openDays.map(JSONValue.bool)),
                  minimum.map(JSONValue.number) ?? .null]) else {
            Issue.record("not an object")
            return Throughput.Grid(matrix: [], byDay: [], byHour: [],
                                   totals: .init(jobs: -1, enough: false, busiestDay: nil,
                                                 busiestHour: nil, onClosedDays: -1,
                                                 closedDayShare: nil, peak: -1))
        }
        func int(_ v: JSONValue?) -> Int { if case .number(let n)? = v { return Int(n) }; return -1 }
        var matrix: [[Int]] = []
        if case .array(let rows)? = o["matrix"] {
            matrix = rows.map { row in
                guard case .array(let cells) = row else { return [] }
                return cells.map { if case .number(let n) = $0 { return Int(n) } else { return -1 } }
            }
        }
        var byDay: [Throughput.Day] = []
        if case .array(let rows)? = o["byDay"] {
            byDay = rows.map { row in
                guard case .object(let r) = row else { return .init(day: -1, jobs: -1, open: false) }
                var open = false; if case .bool(let b)? = r["open"] { open = b }
                return .init(day: int(r["day"]), jobs: int(r["jobs"]), open: open)
            }
        }
        var byHour: [Throughput.Hour] = []
        if case .array(let rows)? = o["byHour"] {
            byHour = rows.map { row in
                guard case .object(let r) = row else { return .init(hour: -1, jobs: -1) }
                return .init(hour: int(r["hour"]), jobs: int(r["jobs"]))
            }
        }
        var totals = Throughput.Totals(jobs: -1, enough: false, busiestDay: nil, busiestHour: nil,
                                       onClosedDays: -1, closedDayShare: nil, peak: -1)
        if case .object(let t)? = o["totals"] {
            var enough = false; if case .bool(let b)? = t["enough"] { enough = b }
            var bDay: Int?; if case .number(let n)? = t["busiestDay"] { bDay = Int(n) }
            var bHour: Int?; if case .number(let n)? = t["busiestHour"] { bHour = Int(n) }
            var share: Double?; if case .number(let n)? = t["closedDayShare"] { share = n }
            totals = .init(jobs: int(t["jobs"]), enough: enough, busiestDay: bDay,
                           busiestHour: bHour, onClosedDays: int(t["onClosedDays"]),
                           closedDayShare: share, peak: int(t["peak"]))
        }
        return Throughput.Grid(matrix: matrix, byDay: byDay, byHour: byHour, totals: totals)
    }

    private func check(_ orders: [JSONValue], openDays: [Bool] = [], minimum: Double? = nil,
                       _ what: String, _ js: JSModule) throws {
        let mine = Throughput.grid(orders: orders, openDays: openDays, minimum: minimum)
        let theirs = try theirs(js, orders, openDays: openDays, minimum: minimum)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine.totals)\n  js    \(theirs.totals)"))
    }

    private func job(_ at: String, status: String = "completed",
                     voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string("O-" + at), "status": .string(status),
                                      "completedAt": .string(at)]
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    /// Sunday to Thursday, the shop's own week.
    private let gulfWeek = [true, true, true, true, true, false, false]

    @Test("a real month of finishing times")
    func realMonth() throws {
        let js = try js()
        try check([
            job("2026-09-01T09:15:00Z"), job("2026-09-01T17:40:00Z"),
            job("2026-09-02T11:00:00Z"), job("2026-09-04T23:50:00Z"),
            job("2026-09-05T02:10:00Z"), job("2026-09-06T14:00:00Z"),
            job("2026-09-08T09:15:00Z"), job("2026-09-10T20:00:00Z"),
            job("2026-09-12T06:30:00Z"), job("2026-09-14T13:45:00Z"),
            job("2026-09-15T08:00:00Z", status: "delivered"),
        ], openDays: gulfWeek, "a month", js)
    }

    @Test("only finished, un-voided work with a readable time")
    func scopeMatches() throws {
        let js = try js()
        var orders: [JSONValue] = []
        for status in ["completed", "delivered", "quote", "pending", "printing",
                       "post", "qc", "on_hold", "cancelled", "shipped", ""] {
            orders.append(job("2026-09-01T09:00:00Z", status: status))
        }
        orders.append(job("2026-09-01T09:00:00Z", voided: true))
        orders.append(.object(["id": .string("no-time"), "status": .string("completed")]))
        orders.append(.object(["id": .string("bad-time"), "status": .string("completed"),
                               "completedAt": .string("not a date")]))
        orders.append(.object(["id": .string("null-time"), "status": .string("completed"),
                               "completedAt": .null]))
        try check(orders, openDays: gulfWeek, "every status", js)
    }

    @Test("a tie for busiest keeps the first, so the answer does not move")
    func tiesKeepTheFirst() throws {
        // `r.jobs > top.jobs` is strict — Sunday over Tuesday, midnight over
        // noon. A shop looking at one answer should get the same one twice.
        let js = try js()
        try check([job("2026-09-06T09:00:00Z"), job("2026-09-08T09:00:00Z")],
                  openDays: gulfWeek, "two days tied", js)
        try check([job("2026-09-06T00:00:00Z"), job("2026-09-06T12:00:00Z")],
                  openDays: gulfWeek, "two hours tied", js)
    }

    @Test("work finishing on a closed day is counted and shared")
    func closedDaysMatch() throws {
        let js = try js()
        let orders = [job("2026-09-04T10:00:00Z"),   // Friday
                      job("2026-09-05T10:00:00Z"),   // Saturday
                      job("2026-09-06T10:00:00Z")]   // Sunday
        try check(orders, openDays: gulfWeek, "the Gulf week", js)
        try check(orders, openDays: [true, true, true, true, true, true, true], "open always", js)
        // Anything other than exactly seven means "no idea", and every day
        // counts as open rather than as closed.
        for days in [[], [true], Array(repeating: true, count: 6),
                     Array(repeating: true, count: 8)] {
            try check(orders, openDays: days, "openDays of \(days.count)", js)
        }
    }

    @Test("the minimum decides whether the grid means anything")
    func minimumMatches() throws {
        let js = try js()
        let orders = (1...5).map { job("2026-09-0\($0)T10:00:00Z") }
        for minimum in [nil, 0, 1, 5, 6, 10, -1, 0.5] as [Double?] {
            try check(orders, openDays: gulfWeek, minimum: minimum,
                      "minimum \(minimum.map { "\($0)" } ?? "nil")", js)
        }
    }

    @Test("nothing finished at all")
    func emptyGrid() throws {
        let js = try js()
        try check([], openDays: gulfWeek, "no orders", js)
        try check([job("2026-09-01T09:00:00Z", status: "quote")], openDays: gulfWeek,
                  "nothing finished", js)
        let empty = Throughput.grid(orders: [], openDays: gulfWeek)
        #expect(empty.totals.busiestDay == nil, "a busiest day with no jobs in it")
        #expect(empty.totals.closedDayShare == nil, "a share of nothing")
        #expect(empty.totals.peak == 0)
    }

    @Test("rows that are not orders")
    func degenerateRows() throws {
        let js = try js()
        try check([.null, .bool(false), .number(0), .string(""), .string("x"),
                   .number(3), .array([]), .bool(true),
                   job("2026-09-01T09:00:00Z")], openDays: gulfWeek, "a mix", js)
    }

    @Test("every hour of a day, so an hour cannot be one out")
    func everyHourMatches() throws {
        let js = try js()
        var orders: [JSONValue] = []
        for hour in 0..<24 {
            orders.append(job(String(format: "2026-09-08T%02d:30:00Z", hour)))
        }
        try check(orders, openDays: gulfWeek, "every hour", js)
    }

    @Test("every day of a week, so a weekday cannot be one out")
    func everyDayMatches() throws {
        let js = try js()
        var orders: [JSONValue] = []
        for day in 6...12 {
            orders.append(job(String(format: "2026-09-%02dT10:00:00Z", day)))
        }
        try check(orders, openDays: gulfWeek, "every weekday", js)
    }
}
