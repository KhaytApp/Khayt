import Foundation
import Testing
@testable import KhaytCore

/// What an hour earned and what a gram cost, against the JavaScript.
///
/// Both figures were wrong in the screen this replaces, and in opposite ways —
/// one dropped the shop's best months, the other reported one number twelve
/// times — so both are pinned.
@MainActor
struct CostTrendsParityTests {

    private func js() throws -> JSModule { try JSModule(["cost-trends"]) }

    private func check(_ orders: [JSONValue], _ spools: [JSONValue],
                       now: Double, months: Int = 12, _ what: String,
                       _ js: JSModule) throws {
        let revenues = orders.map { order -> Double in
            guard case .object(let o) = order else { return 0 }
            let n = JSSemantics.number(o["price"])
            return n.isFinite ? n : 0
        }
        let mine = CostTrends.report(orders: orders, spools: spools, revenues: revenues,
                                     now: now, months: months)
        let v = try js.value("""
            KhaytCostTrends.costTrends(ARG0, ARG1, {
              now: ARG2, months: ARG3,
              revenueOf: function (o) { var n = Number(o && o.price);
                                        return isFinite(n) ? n : 0; }})
            """, [.array(orders), .array(spools), .number(now), .number(Double(months))])
        guard case .object(let o) = v, case .array(let rows)? = o["months"] else {
            Issue.record("not a report"); return
        }
        let theirMonths: [CostTrends.Month] = rows.map { row in
            guard case .object(let r) = row else {
                return .init(key: "?", revenue: -1, hours: -1, perHour: nil,
                             costPerGram: nil, spoolsOpened: -1)
            }
            var per: Double?; if case .number(let n)? = r["perHour"] { per = n }
            var gram: Double?; if case .number(let n)? = r["costPerGram"] { gram = n }
            return .init(key: JSSemantics.text(r["key"]),
                         revenue: JSSemantics.number(r["revenue"]),
                         hours: JSSemantics.number(r["hours"]),
                         perHour: per, costPerGram: gram,
                         spoolsOpened: Int(JSSemantics.number(r["spoolsOpened"])))
        }
        var per: Double?; if case .number(let n)? = o["perHour"] { per = n }
        var gram: Double?; if case .number(let n)? = o["costPerGram"] { gram = n }
        let theirs = CostTrends.Report(months: theirMonths, perHour: per, costPerGram: gram)
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine.perHour.debugDescription) \(mine.costPerGram.debugDescription)
              js    \(theirs.perHour.debugDescription) \(theirs.costPerGram.debugDescription)
            """))
    }

    private func job(_ status: String, price: Double, hours: Double,
                     done: String = "", delivered: String = "", date: String = "",
                     voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["status": .string(status), "price": .number(price),
                                      "printTime": .number(hours)]
        if !done.isEmpty { o["completedAt"] = .string(done) }
        if !delivered.isEmpty { o["deliveredAt"] = .string(delivered) }
        if !date.isEmpty { o["date"] = .string(date) }
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    private func spool(cost: Double, newWeight: JSONValue, opened: String = "",
                       remaining: Double = 0) -> JSONValue {
        var s: [String: JSONValue] = ["cost": .number(cost), "spoolWeight": newWeight,
                                      "remainingWeight": .number(remaining)]
        if !opened.isEmpty { s["openedAt"] = .string(opened) }
        return .object(s)
    }

    /// 2026-09-18T09:00:00Z.
    private let now = 1789707600000.0

    @Test("delivered work is in the chart, which is what used to be missing")
    func deliveredCounts() throws {
        // A shop that delivers promptly saw its best months as its emptiest.
        let js = try js()
        try check([job("completed", price: 900, hours: 10, done: "2026-09-02"),
                   job("delivered", price: 1500, hours: 20, delivered: "2026-08-14"),
                   job("delivered", price: 600, hours: 5, done: "2026-07-01",
                       delivered: "2026-07-09"),
                   job("printing", price: 400, hours: 8, date: "2026-09-01"),
                   job("completed", price: 400, hours: 8, done: "2026-09-01", voided: true)],
                  [], now: now, "delivered and completed", js)
    }

    @Test("a gram costs what the spool cost divided by what it weighed NEW")
    func gramsAreNewWeight() throws {
        // Dividing by the REMAINING weight made a spool dearer as it was used,
        // and a nearly finished one cost a fortune.
        let js = try js()
        try check([], [spool(cost: 100, newWeight: .number(1000),
                             opened: "2026-09-01", remaining: 20),
                       spool(cost: 60, newWeight: .number(750),
                             opened: "2026-08-15", remaining: 700)],
                  now: now, "two spools", js)
        let mine = CostTrends.report(
            orders: [], spools: [spool(cost: 100, newWeight: .number(1000),
                                       opened: "2026-09-01", remaining: 20)],
            revenues: [], now: now)
        #expect(mine.costPerGram == 0.1, "priced off the remaining weight")
    }

    @Test("two spools in a month are weighted by grams, not averaged")
    func weightedByGrams() throws {
        let js = try js()
        try check([], [spool(cost: 100, newWeight: .number(1000), opened: "2026-09-01"),
                       spool(cost: 90, newWeight: .number(300), opened: "2026-09-02")],
                  now: now, "a cheap one and a dear one", js)
    }

    @Test("the shelf figure covers every spool, the hours figure only the window")
    func asymmetryIsDeliberate() throws {
        // The shelf is what it is, and a window that happens to contain no
        // purchases has not made material free.
        let js = try js()
        try check([job("completed", price: 100, hours: 5, done: "2026-09-01")],
                  [spool(cost: 100, newWeight: .number(1000), opened: "2019-01-01")],
                  now: now, "a spool from before the window", js)
        let mine = CostTrends.report(
            orders: [], spools: [spool(cost: 100, newWeight: .number(1000),
                                       opened: "2019-01-01")],
            revenues: [], now: now)
        #expect(mine.costPerGram == 0.1, "an old spool stopped pricing material")
        #expect(mine.months.allSatisfy { $0.costPerGram == nil }, "it landed in a month")
    }

    @Test("a month with no answer says nothing, not nought")
    func emptyMonthsAreNil() throws {
        let js = try js()
        try check([], [], now: now, "an empty year", js)
        let empty = CostTrends.report(orders: [], spools: [], revenues: [], now: now)
        #expect(empty.perHour == nil, "no hours printed read as earned nothing per hour")
        #expect(empty.costPerGram == nil, "no spool opened read as material being free")
        #expect(empty.months.count == 12)
    }

    @Test("which month a job counts in, and which a spool does")
    func monthPicking() throws {
        let js = try js()
        for order: JSONValue in [
            job("completed", price: 1, hours: 1, done: "2026-09-30T23:30:00Z"),
            job("completed", price: 1, hours: 1, done: "2026-09-30"),
            job("completed", price: 1, hours: 1, delivered: "2026-08-01", date: "2026-07-01"),
            job("completed", price: 1, hours: 1, date: "2026-06-01"),
            job("completed", price: 1, hours: 1, done: "not a date", date: "2026-05-01"),
            job("completed", price: 1, hours: 1),
        ] {
            let theirs = try js.value("KhaytCostTrends.monthDone(ARG0)", [order])
            var key: String?; if case .string(let s) = theirs { key = s }
            #expect(CostTrends.monthDone(order) == key, Comment(rawValue: "\(order)"))
        }
        // `monthOf` is not exported — the module's api is
        // `{costTrends, monthKeys, monthDone, DONE}` — so it is compared
        // through the door that is: a job carrying the stamp and nothing else.
        for stamp: JSONValue in [.string("2026-09-30"), .string("2026-09-30T23:30:00Z"),
                                 .string("2026-09"), .string("not a date"), .string(""),
                                 .null, .number(0), .bool(true), .number(1789707600000)] {
            let order: JSONValue = .object(["completedAt": stamp])
            let theirs = try js.value("KhaytCostTrends.monthDone(ARG0)", [order])
            var key: String?; if case .string(let s) = theirs { key = s }
            #expect(CostTrends.monthOf(stamp) == key,
                    Comment(rawValue: "as completedAt: \(stamp)"))
        }
    }

    @Test("the window, and figures that are not figures")
    func degenerate() throws {
        let js = try js()
        for months in [12, 1, 6, 0, -1] {
            try check([job("completed", price: 100, hours: 4, done: "2026-09-01")],
                      [spool(cost: 50, newWeight: .number(500), opened: "2026-09-01")],
                      now: now, months: months, "\(months) months", js)
        }
        try check([.null, .string("x"), .object([:]),
                   .object(["status": .string("completed"), "price": .string("90"),
                            "printTime": .string("3"), "completedAt": .string("2026-09-01")])],
                  [.null, .string("x"), .object([:]),
                   spool(cost: 0, newWeight: .number(500), opened: "2026-09-01"),
                   spool(cost: 50, newWeight: .number(0), opened: "2026-09-01"),
                   spool(cost: 50, newWeight: .null, opened: "2026-09-01"),
                   spool(cost: 50, newWeight: .string("500"), opened: "2026-09-01")],
                  now: now, "a mess", js)
    }
}
