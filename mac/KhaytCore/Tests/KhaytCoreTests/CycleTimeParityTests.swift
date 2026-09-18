import Foundation
import Testing
@testable import KhaytCore

/// How long a job takes, against the JavaScript it came from.
///
/// Every reading here is in the shop's LOCAL calendar — which month a finish
/// falls in, and what midnight on the day it was taken means — so the suite is
/// run under several zones.
@MainActor
struct CycleTimeParityTests {

    private func js() throws -> JSModule { try JSModule(["cycle-time"]) }

    private func job(_ date: JSONValue, done: JSONValue = .null, delivered: JSONValue = .null,
                     status: String = "completed", voided: Bool = false,
                     project: String = "", productId: String = "") -> JSONValue {
        var o: [String: JSONValue] = ["status": .string(status), "date": date]
        if case .null = done {} else { o["completedAt"] = done }
        if case .null = delivered {} else { o["deliveredAt"] = delivered }
        if voided { o["voidedAt"] = .string("2026-09-01") }
        if !project.isEmpty { o["project"] = .string(project) }
        if !productId.isEmpty { o["productId"] = .string(productId) }
        return .object(o)
    }

    private var book: [JSONValue] {
        [job(.string("2026-09-01"), done: .string("2026-09-04T12:00:00Z"),
             project: "Dragon", productId: "P-1"),
         job(.string("2026-09-02"), done: .string("2026-09-03T09:00:00Z"), project: "Bracket"),
         job(.string("2026-08-20"), delivered: .string("2026-08-30T10:00:00Z"),
             status: "delivered", project: "Dragon", productId: "P-1"),
         job(.string("2026-07-01"), done: .string("2026-07-20T10:00:00Z"), project: "Sign"),
         // A job finished BEFORE it was taken — a typed date. Left out.
         job(.string("2026-09-10"), done: .string("2026-09-01T10:00:00Z"), project: "Bad"),
         // Still on the bench, voided, and no finish recorded.
         job(.string("2026-09-01"), status: "printing", project: "Open"),
         job(.string("2026-09-01"), done: .string("2026-09-02T10:00:00Z"), voided: true),
         job(.string("2026-09-01"), project: "No finish"),
         job(.null, done: .string("2026-09-02T10:00:00Z"), project: "No start"),
         .null, .string("x"), .number(1), .object([:])]
    }

    /// 2026-09-18T09:00:00Z, the day this was written.
    private let now = 1789707600000.0

    private func checkReport(_ orders: [JSONValue], months: Int, _ what: String,
                             _ js: JSModule) throws {
        let mine = CycleTime.report(orders: orders, now: now, months: months)
        let v = try js.value("KhaytCycleTime.cycleTime(ARG0, {now: ARG1, months: ARG2})",
                             [.array(orders), .number(now), .number(Double(months))])
        guard case .object(let o) = v, case .array(let rows)? = o["months"] else {
            Issue.record("not a report"); return
        }
        let theirMonths: [CycleTime.Month] = rows.map { row in
            guard case .object(let r) = row else { return .init(key: "?", avgDays: nil, jobs: -1) }
            var avg: Double?; if case .number(let n)? = r["avgDays"] { avg = n }
            return .init(key: JSSemantics.text(r["key"]), avgDays: avg,
                         jobs: Int(JSSemantics.number(r["jobs"])))
        }
        var avg: Double?; if case .number(let n)? = o["avgDays"] { avg = n }
        let theirs = CycleTime.Report(months: theirMonths, avgDays: avg,
                                      jobs: Int(JSSemantics.number(o["jobs"])))
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine)
              js    \(theirs)
            """))
    }

    @Test("a real book, month by month")
    func monthly() throws {
        let js = try js()
        for months in [6, 1, 3, 12, 0, -1] {
            try checkReport(book, months: months, "\(months) months", js)
        }
        try checkReport([], months: 6, "nothing at all", js)
    }

    @Test("a month with nothing finished has no answer, not nought")
    func emptyMonthIsNil() throws {
        // Zero would say the shop got faster.
        let report = CycleTime.report(orders: [], now: now, months: 3)
        #expect(report.months.allSatisfy { $0.avgDays == nil })
        #expect(report.avgDays == nil)
        #expect(report.months.count == 3)
    }

    @Test("the months counted back cross a year boundary the way JavaScript does")
    func monthKeysMatch() throws {
        let js = try js()
        for (stamp, months) in [(now, 6), (now, 14), (1767225600000.0, 6),
                                (1767225600000.0, 1), (now, 24)] {
            let mine = CycleTime.monthKeys(now: stamp, months: months)
            let theirs = try js.value("KhaytCycleTime.monthKeys(ARG0, ARG1)",
                                      [.number(stamp), .number(Double(months))])
            #expect(.array(mine.map(JSONValue.string)) == theirs,
                    Comment(rawValue: "\(stamp) × \(months)"))
        }
    }

    @Test("a day taken is midnight where the shop is, not in Greenwich")
    func daysToFinishMatches() throws {
        let js = try js()
        var cases = book
        cases += [job(.string("2026-09-01T06:00:00Z"), done: .string("2026-09-01T18:00:00Z")),
                  job(.string("2026-09-01"), done: .string("2026-09-01T00:00:00Z")),
                  job(.string("not a date"), done: .string("2026-09-02T10:00:00Z")),
                  job(.string("2026-09-01"), done: .string("not a date")),
                  job(.number(20260901), done: .string("2026-09-02T10:00:00Z")),
                  job(.string("2026-09-01"), done: .string("2026-09-02T10:00:00Z"),
                      status: "delivered"),
                  job(.string("2026-09-01"), done: .string("2026-09-02T10:00:00Z"),
                      status: "printing")]
        for order in cases {
            let mine = CycleTime.daysToFinish(order)
            let theirs = try js.value("KhaytCycleTime.daysToFinish(ARG0)", [order])
            var theirDays: Double?; if case .number(let n) = theirs { theirDays = n }
            #expect(mine == theirDays, Comment(rawValue: "\(order)"))
        }
    }

    private func checkProducts(_ orders: [JSONValue], top: Int, _ what: String,
                               _ js: JSModule) throws {
        let mine = CycleTime.byProduct(orders: orders, top: top)
        let v = try js.value("KhaytCycleTime.leadTimeByProduct(ARG0, {top: ARG1})",
                             [.array(orders), .number(Double(top))])
        guard case .object(let o) = v, case .array(let rows)? = o["rows"] else {
            Issue.record("not a report"); return
        }
        let theirRows: [CycleTime.ProductRow] = rows.map { row in
            guard case .object(let r) = row else {
                return .init(key: "?", productId: nil, name: "?", avgDays: -1,
                             fastest: -1, slowest: -1, jobs: -1)
            }
            var pid: String?; if case .string(let s)? = r["productId"] { pid = s }
            return .init(key: JSSemantics.text(r["key"]), productId: pid,
                         name: JSSemantics.text(r["name"]),
                         avgDays: JSSemantics.number(r["avgDays"]),
                         fastest: JSSemantics.number(r["fastest"]),
                         slowest: JSSemantics.number(r["slowest"]),
                         jobs: Int(JSSemantics.number(r["jobs"])))
        }
        let theirs = CycleTime.ProductReport(rows: theirRows,
                                             jobs: Int(JSSemantics.number(o["jobs"])))
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine.rows)
              js    \(theirs.rows)
            """))
    }

    @Test("per product, slowest first")
    func products() throws {
        let js = try js()
        for top in [10, 1, 2, 0, -1, 100] {
            try checkProducts(book, top: top, "top \(top)", js)
        }
    }

    @Test("a product taken from the catalogue joins its own rows, however it is spelled")
    func keyedOnProductId() throws {
        // The table used to key on the free-text name, so "Dragon" and "dragon"
        // were two products and a job taken from the catalogue did not join it.
        let js = try js()
        try checkProducts([
            job(.string("2026-09-01"), done: .string("2026-09-03T10:00:00Z"),
                project: "Dragon", productId: "P-1"),
            job(.string("2026-09-01"), done: .string("2026-09-05T10:00:00Z"),
                project: "dragon ", productId: "P-1"),
            job(.string("2026-09-01"), done: .string("2026-09-02T10:00:00Z"),
                project: "Dragon"),
            job(.string("2026-09-01"), done: .string("2026-09-04T10:00:00Z"),
                project: " DRAGON "),
            // No name at all: the row is named by the next job that has one.
            job(.string("2026-09-01"), done: .string("2026-09-06T10:00:00Z"),
                productId: "P-2"),
            job(.string("2026-09-01"), done: .string("2026-09-07T10:00:00Z"),
                project: "Named later", productId: "P-2"),
        ], top: 10, "keys", js)
    }

    @Test("two products on the same average keep the order the book mentioned them in")
    func tiesAreStable() throws {
        let js = try js()
        try checkProducts([
            job(.string("2026-09-01"), done: .string("2026-09-03T10:00:00Z"), project: "Zahra"),
            job(.string("2026-09-01"), done: .string("2026-09-03T10:00:00Z"), project: "Adel"),
            job(.string("2026-09-01"), done: .string("2026-09-03T10:00:00Z"), project: "Badr"),
        ], top: 10, "three tied", js)
    }
}
