import Foundation
import Testing
@testable import KhaytCore

/// The revenue outlook, against the JavaScript it came from.
///
/// The module's own comment records the bug it already had: reading the month
/// in UTC put a UTC+3 shop's early-morning jobs in the previous month and slid
/// the whole window back — *"the tests never caught it: they build both now and
/// the fixtures with Date.UTC, so they were self-consistently wrong."*
///
/// So the clocks here are real instants rather than constructed keys, the
/// corpus straddles month boundaries by the hour, and the suite is run under
/// several zones.
@MainActor
struct ForecastParityTests {

    private func js() throws -> JSModule { try JSModule(["forecast"]) }

    /// The JavaScript, with the DEFAULT `revenueOf` — `+o.price || 0`. The
    /// engine passes the shared money rule instead, which is still shared;
    /// what is compared here is the forecast arithmetic, and the Swift side is
    /// handed the same figures the default would produce.
    private func theirs(_ js: JSModule, _ orders: [JSONValue],
                        now: Double, months: Int, periods: Int) throws -> Forecast.Outlook {
        let answer = try js.value("""
            globalThis.KhaytForecast.forecast(ARG0, { now: ARG1, months: ARG2, periods: ARG3 })
            """, [.array(orders), .number(now), .number(Double(months)), .number(Double(periods))])
        guard case .object(let o) = answer else {
            Issue.record("not an object"); return Forecast.Outlook(history: [], projection: [],
                                                                   nextMonth: -1, trendPct: nil,
                                                                   method: "«?»")
        }
        // Named `readMonths`, not `months`: a local `months` shadows the
        // parameter of the same name and the error lands somewhere else.
        // A row that cannot be read is REPORTED, not dropped. The first
        // version `compactMap`ped them away, so when JSON turned an infinite
        // revenue into `null` the month simply vanished from the JavaScript's
        // history and the failure looked like a missing bucket rather than a
        // figure the bridge could not carry.
        func readMonths(_ v: JSONValue?) -> [Forecast.Month] {
            guard case .array(let rows)? = v else { return [] }
            return rows.map { row in
                guard case .object(let r) = row, case .number(let k)? = r["key"],
                      case .string(let l)? = r["label"], case .number(let rev)? = r["revenue"]
                else {
                    Issue.record(Comment(rawValue: "a history row did not survive JSON: \(row)"))
                    return Forecast.Month(key: -1, label: "«lost»", revenue: .nan)
                }
                return Forecast.Month(key: Int(k), label: l, revenue: rev)
            }
        }
        var projection: [Forecast.Projected] = []
        if case .array(let rows)? = o["projection"] {
            projection = rows.compactMap { row in
                guard case .object(let r) = row, case .number(let k)? = r["key"],
                      case .string(let l)? = r["label"], case .number(let p)? = r["projected"]
                else { return nil }
                return Forecast.Projected(key: Int(k), label: l, projected: p)
            }
        }
        var next = -1.0; if case .number(let n)? = o["nextMonth"] { next = n }
        var trend: Double?; if case .number(let t)? = o["trendPct"] { trend = t }
        var method = "«?»"; if case .string(let m)? = o["method"] { method = m }
        return Forecast.Outlook(history: readMonths(o["history"]), projection: projection,
                                nextMonth: next, trendPct: trend, method: method)
    }

    /// The default `revenueOf`, spelled exactly: `+o.price || 0`.
    ///
    /// `||` falls back only on a FALSY value, which for a number is `0` and
    /// `NaN` — not infinity. `+"Infinity"` is `Infinity`, which is truthy and
    /// survives; reading this as "finite or zero" made the harness report a
    /// difference that was in the test rather than in the port.
    private func prices(_ orders: [JSONValue]) -> [Double] {
        orders.map { row in
            guard case .object(let o) = row else { return 0 }
            let n = JSSemantics.number(o["price"])
            return (n == 0 || n.isNaN) ? 0 : n
        }
    }

    private func check(_ orders: [JSONValue], now: Double, months: Int = 6, periods: Int = 3,
                       _ what: String, _ js: JSModule) throws {
        let mine = Forecast.forecast(orders: orders, revenues: prices(orders),
                                     now: now, months: months, periods: periods)
        let theirs = try theirs(js, orders, now: now, months: months, periods: periods)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    private func job(_ date: String, _ price: Double, status: String = "completed") -> JSONValue {
        .object(["id": .string("O-\(date)-\(price)"), "status": .string(status),
                 "completedAt": .string(date), "price": .number(price)])
    }

    /// A real instant, not a constructed month key.
    private func at(_ stamp: String) throws -> Double {
        try #require(JSDate.parse(stamp), Comment(rawValue: "could not parse \(stamp)"))
    }

    @Test("a real six months of trading")
    func realHistory() throws {
        let js = try js()
        let orders = [
            job("2026-03-14T10:00:00Z", 4200), job("2026-04-02T10:00:00Z", 3900),
            job("2026-04-19T10:00:00Z", 1100), job("2026-05-08T10:00:00Z", 5300),
            job("2026-06-21T10:00:00Z", 6100), job("2026-07-03T10:00:00Z", 5800),
            job("2026-08-30T10:00:00Z", 7200), job("2026-09-02T10:00:00Z", 900),
        ]
        try check(orders, now: try at("2026-09-17T13:00:00Z"), "six months", js)
    }

    @Test("the month boundary, hour by hour")
    func monthBoundaries() throws {
        // THE BUG THE MODULE RECORDS. A job completed just after local midnight
        // on the 1st, and a clock at the same moment: both are keyed the same
        // way, so an off-by-one in either slides the whole window.
        let js = try js()
        let midnight = try at("2026-09-01T00:00:00Z")
        for hour in -4...4 {
            let ms = midnight + Double(hour) * 3_600_000
            let orders = [
                .object(["id": .string("A"), "status": .string("completed"),
                         "completedAt": .number(ms), "price": .number(1000)]),
                job("2026-07-15T10:00:00Z", 2000), job("2026-06-15T10:00:00Z", 2500),
                job("2026-05-15T10:00:00Z", 3000),
            ] as [JSONValue]
            try check(orders, now: ms + 86_400_000 * 20, "a job at hour \(hour)", js)
            try check(orders, now: ms, "the clock at hour \(hour)", js)
        }
    }

    @Test("which stamp dates an order, and in which order they are tried")
    func stampPrecedence() throws {
        let js = try js()
        try check([
            .object(["id": .string("A"), "status": .string("completed"),
                     "completedAt": .string("2026-07-01"), "deliveredAt": .string("2026-05-01"),
                     "date": .string("2026-04-01"), "price": .number(100)]),
            .object(["id": .string("B"), "status": .string("delivered"),
                     "deliveredAt": .string("2026-06-01"), "date": .string("2026-04-01"),
                     "price": .number(200)]),
            .object(["id": .string("C"), "status": .string("completed"),
                     "date": .string("2026-05-01"), "price": .number(300)]),
            .object(["id": .string("D"), "status": .string("completed"),
                     "completedAt": .string(""), "date": .string("2026-05-02"),
                     "price": .number(400)]),
            .object(["id": .string("E"), "status": .string("completed"),
                     "completedAt": .string("not a date"), "price": .number(500)]),
            .object(["id": .string("F"), "status": .string("completed"), "price": .number(600)]),
        ], now: try at("2026-09-17T13:00:00Z"), "precedence", js)
    }

    @Test("only completed and delivered work counts")
    func onlyFinishedWork() throws {
        let js = try js()
        var orders: [JSONValue] = []
        for status in ["completed", "delivered", "quote", "pending", "printing", "post",
                       "qc", "on_hold", "cancelled", "split", "shipped", "", "nonsense"] {
            orders.append(job("2026-07-15T10:00:00Z", 1000, status: status))
        }
        try check(orders, now: try at("2026-09-17T13:00:00Z"), "every status", js)
    }

    @Test("under three months of takings is an average, and none at all is nothing")
    func fallbacksMatch() throws {
        // Two points make a line through anything, and a line through two
        // months of a new shop projects a business that does not exist yet.
        let js = try js()
        let now = try at("2026-09-17T13:00:00Z")
        try check([], now: now, "a shop with no history", js)
        try check([job("2026-07-15T10:00:00Z", 1000)], now: now, "one month", js)
        try check([job("2026-07-15T10:00:00Z", 1000), job("2026-06-15T10:00:00Z", 2000)],
                  now: now, "two months", js)
        try check([job("2026-07-15T10:00:00Z", 1000), job("2026-06-15T10:00:00Z", 2000),
                   job("2026-05-15T10:00:00Z", 3000)], now: now, "three months", js)
        #expect(Forecast.forecast(orders: [], revenues: [], now: now).method == "none")
        #expect(Forecast.forecast(orders: [], revenues: [], now: now).trendPct == nil,
                "a percentage change from nothing is not a number to show anybody")
    }

    @Test("a falling shop is not projected below zero")
    func projectionsAreFloored() throws {
        let js = try js()
        try check([job("2026-04-15T10:00:00Z", 9000), job("2026-05-15T10:00:00Z", 6000),
                   job("2026-06-15T10:00:00Z", 3000), job("2026-07-15T10:00:00Z", 200)],
                  now: try at("2026-09-17T13:00:00Z"), periods: 12, "a collapse", js)
    }

    @Test("the window and the projection length can be asked for")
    func windowsMatch() throws {
        let js = try js()
        let orders = (1...14).map { job(String(format: "2025-%02d-15T10:00:00Z", ($0 % 12) + 1),
                                        Double($0) * 500) }
        let now = try at("2026-09-17T13:00:00Z")
        for months in [1, 2, 3, 6, 12, 24, 0, -1] {
            for periods in [1, 3, 6, 0, -2] {
                try check(orders, now: now, months: months, periods: periods,
                          "months \(months) periods \(periods)", js)
            }
        }
    }

    @Test("a price that is not a number")
    func oddPrices() throws {
        let js = try js()
        // `greatestFiniteMagnitude` is left out: rounding it overflows, both
        // sides produce `Infinity`, and JSON writes `null` — the same bridge
        // artifact pinned in `QcMetricsParityTests`, not a difference in the
        // rule.
        //
        // `"Infinity"` is excluded for the same reason: `+"Infinity"` is a
        // truthy infinity, both sides bucket it, and only JSON loses it.
        let numbers = Awkward.numbers.filter { $0.isFinite && $0 < 1e300 }
        let notNumbers = Awkward.notNumbers.filter { $0 != .string("Infinity") }
        for value in notNumbers + numbers.map({ JSONValue.number($0) }) {
            try check([.object(["id": .string("A"), "status": .string("completed"),
                                "completedAt": .string("2026-07-15T10:00:00Z"), "price": value]),
                       job("2026-06-15T10:00:00Z", 1000)],
                      now: try at("2026-09-17T13:00:00Z"), "price \(value)", js)
        }
    }

    @Test("a revenue past Double's range is bucketed here, and lost by the bridge")
    func infinityCrossesTheBridgeAsNull() throws {
        // Both sides agree — `+"Infinity"` is truthy, so it is added — and
        // JSON writes `null`, which `RevenueOutlook` decodes as a failure. The
        // same artifact pinned in `QcMetricsParityTests`; natively there is no
        // bridge for it to be lost in.
        let js = try js()
        let orders: [JSONValue] = [
            .object(["id": .string("A"), "status": .string("completed"),
                     "completedAt": .string("2026-07-15T10:00:00Z"), "price": .string("Infinity")]),
        ]
        let now = try at("2026-09-17T13:00:00Z")
        let mine = Forecast.forecast(orders: orders, revenues: prices(orders), now: now)
        #expect(mine.history.contains { $0.revenue.isInfinite },
                "the month was not bucketed at all")
        guard case .object(let o) = try js.value(
            "globalThis.KhaytForecast.forecast(ARG0, { now: ARG1 })",
            [.array(orders), .number(now)]), case .array(let rows)? = o["history"] else {
            Issue.record("no answer"); return
        }
        #expect(rows.contains { row in
            if case .object(let r) = row, r["revenue"] == .null { return true }
            return false
        }, "JSON no longer drops it — this note can go")
    }

    @Test("rows that are not orders")
    func degenerateRows() throws {
        let js = try js()
        try check([.null, .bool(false), .number(0), .string(""), .string("x"), .array([]),
                   job("2026-07-15T10:00:00Z", 1000)],
                  now: try at("2026-09-17T13:00:00Z"), "a mix", js)
    }

    @Test("the label is the same string, including before 1970")
    func labelsMatch() throws {
        let js = try js()
        for key in [24_312, 0, 1, -1, -12, -13, 11, 12, 23_711, 30_000] {
            guard case .string(let theirs) = try js.value(
                "globalThis.KhaytForecast.ymLabel(ARG0)", [.number(Double(key))]) else {
                Issue.record("no label for \(key)"); continue
            }
            #expect(Forecast.label(key) == theirs,
                    Comment(rawValue: "key \(key): \(Forecast.label(key)) vs \(theirs)"))
        }
    }

    @Test("the least-squares fit is the same fit")
    func linregMatches() throws {
        let js = try js()
        for values in [[], [5.0], [1, 2], [1, 2, 3], [3, 1, 4, 1, 5, 9],
                       [0, 0, 0, 0], [1e6, 1e6, 1e6], [-5, 0, 5],
                       [0.1, 0.2, 0.30000000000000004], [1e-9, 2e-9, 3e-9]] as [[Double]] {
            guard case .object(let o) = try js.value(
                "globalThis.KhaytForecast.linreg(ARG0)", [.array(values.map(JSONValue.number))]),
                  case .number(let slope)? = o["slope"], case .number(let intercept)? = o["intercept"]
            else { Issue.record("no fit for \(values)"); continue }
            let mine = Forecast.linreg(values)
            #expect(mine.slope == slope && mine.intercept == intercept,
                    Comment(rawValue: "\(values): swift \(mine) vs js (\(slope), \(intercept))"))
        }
    }
}
