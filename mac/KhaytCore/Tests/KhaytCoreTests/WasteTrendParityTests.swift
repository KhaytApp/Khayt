import Foundation
import Testing
@testable import KhaytCore

/// What the shop threw away, against the JavaScript it came from.
///
/// The module exists because the chart before it named its failure types by
/// hand — `warping`, `adhesion`, `stringing` — and the log's vocabulary has no
/// `adhesion`, it has `bed_adhesion`. So every failed first layer a shop ever
/// logged went into "other", and a chart whose whole point is "what keeps
/// going wrong" could not name the commonest thing that does.
///
/// A port that picks a different three is that bug again, so the ranking, the
/// tie-break and the "other" bucket are all compared rather than spot-checked.
@MainActor
struct WasteTrendParityTests {

    private func js() throws -> JSModule { try JSModule(["waste-trend"]) }

    private func theirs(_ js: JSModule, _ log: [JSONValue], now: Double,
                        months: Int, named: Int) throws -> WasteTrend.Trend {
        let answer = try js.value("""
            globalThis.KhaytWasteTrend.wasteTrend(ARG0, { now: ARG1, months: ARG2, named: ARG3 })
            """, [.array(log), .number(now), .number(Double(months)), .number(Double(named))])
        guard case .object(let o) = answer else {
            Issue.record("not an object")
            return WasteTrend.Trend(types: ["«?»"], months: [], total: -1, entries: -1, byType: [:])
        }
        func doubles(_ v: JSONValue?) -> [String: Double] {
            guard case .object(let d)? = v else { return [:] }
            return d.compactMapValues { if case .number(let n) = $0 { return n }; return nil }
        }
        var types: [String] = []
        if case .array(let t)? = o["types"] {
            types = t.compactMap { if case .string(let s) = $0 { return s }; return nil }
        }
        var months: [WasteTrend.Month] = []
        if case .array(let rows)? = o["months"] {
            months = rows.map { row in
                guard case .object(let r) = row, case .string(let k)? = r["key"],
                      case .number(let total)? = r["total"], case .number(let n)? = r["entries"]
                else {
                    Issue.record(Comment(rawValue: "a month did not survive JSON: \(row)"))
                    return WasteTrend.Month(key: "«lost»", total: .nan, byType: [:], entries: -1)
                }
                return WasteTrend.Month(key: k, total: total, byType: doubles(r["byType"]),
                                        entries: Int(n))
            }
        }
        var total = -1.0; if case .number(let t)? = o["total"] { total = t }
        var entries = -1; if case .number(let e)? = o["entries"] { entries = Int(e) }
        return WasteTrend.Trend(types: types, months: months, total: total,
                                entries: entries, byType: doubles(o["byType"]))
    }

    private func check(_ log: [JSONValue], now: Double, months: Int = 6, named: Int = 3,
                       _ what: String, _ js: JSModule) throws {
        let mine = WasteTrend.trend(log, now: now, months: months, named: named)
        let theirs = try theirs(js, log, now: now, months: months, named: named)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    private func waste(_ date: String, _ type: JSONValue?, _ grams: JSONValue) -> JSONValue {
        var row: [String: JSONValue] = ["date": .string(date), "weight": grams]
        if let type { row["failureType"] = type }
        return .object(row)
    }

    private func at(_ stamp: String) throws -> Double {
        try #require(JSDate.parse(stamp), Comment(rawValue: "could not parse \(stamp)"))
    }

    @Test("a real six months of scrap")
    func realLog() throws {
        let js = try js()
        try check([
            waste("2026-09-02", .string("bed_adhesion"), .number(180.5)),
            waste("2026-09-11", .string("warping"), .number(92)),
            waste("2026-08-14", .string("bed_adhesion"), .number(240)),
            waste("2026-08-29", .string("stringing"), .number(45.25)),
            waste("2026-07-03", .string("layer_shift"), .number(310)),
            waste("2026-06-18", .string("warping"), .number(88)),
            waste("2026-05-05", .string("nozzle_clog"), .number(15)),
        ], now: try at("2026-09-17T13:00:00Z"), "six months", js)
    }

    @Test("the named types come from the data, not from a list somebody typed")
    func namesComeFromTheData() throws {
        // THE BUG THE MODULE EXISTS FOR. `bed_adhesion` is not a name the old
        // chart knew, and it is the heaviest thing here.
        let js = try js()
        let log = [
            waste("2026-09-02", .string("bed_adhesion"), .number(900)),
            waste("2026-09-03", .string("warping"), .number(100)),
            waste("2026-09-04", .string("stringing"), .number(50)),
            waste("2026-09-05", .string("layer_shift"), .number(25)),
        ]
        let now = try at("2026-09-17T13:00:00Z")
        try check(log, now: now, "four types, three named", js)
        #expect(WasteTrend.trend(log, now: now).types.first == "bed_adhesion",
                "the heaviest failure is not named first")
    }

    @Test("a tie is broken by name, so the columns do not shuffle")
    func tiesBreakByName() throws {
        let js = try js()
        try check([
            waste("2026-09-02", .string("zebra"), .number(100)),
            waste("2026-09-03", .string("apple"), .number(100)),
            waste("2026-09-04", .string("mango"), .number(100)),
            waste("2026-09-05", .string("banana"), .number(100)),
        ], now: try at("2026-09-17T13:00:00Z"), "four types at 100 g", js)
    }

    @Test("how many are named can be asked for, including none")
    func namedCountMatches() throws {
        let js = try js()
        let log = (1...6).map { waste("2026-09-0\($0)", .string("t\($0)"), .number(Double($0) * 10)) }
        let now = try at("2026-09-17T13:00:00Z")
        for named in [0, 1, 3, 5, 6, 10, -1] {
            try check(log, now: now, named: named, "named \(named)", js)
        }
    }

    @Test("the window can be asked for, and rolls the year over")
    func windowMatches() throws {
        let js = try js()
        let log = [waste("2026-01-15", .string("warping"), .number(50)),
                   waste("2025-12-15", .string("warping"), .number(60)),
                   waste("2025-11-15", .string("stringing"), .number(70))]
        for months in [1, 2, 3, 6, 12, 18, 0, -1] {
            try check(log, now: try at("2026-02-10T13:00:00Z"), months: months,
                      "months \(months)", js)
        }
    }

    @Test("a stored day is sliced, not parsed — and anything else is parsed")
    func dateHandlingMatches() throws {
        // Parsing `2026-09-01` would read it as UTC midnight, and a shop west
        // of Greenwich would file the 1st under the previous month.
        let js = try js()
        for date in ["2026-09-01", "2026-09-30", "2026-09-01T00:00:00Z",
                     "2026-09-01T00:00:00", "2026-09-01T23:59:59+03:00",
                     "2026-09", "2026", "not a date", "", "2026-13-40",
                     "2026-09-01 extra"] {
            try check([waste(date, .string("warping"), .number(100)),
                       waste("2026-08-15", .string("stringing"), .number(50))],
                      now: try at("2026-09-17T13:00:00Z"), "date \(date)", js)
        }
    }

    @Test("a legacy date form buckets as other here, and the engine still parses it")
    func legacyDateIsOutOfScope() throws {
        // `2026-9-1` is the engine's implementation-defined parser, which
        // `JSDate` deliberately does not reproduce — see
        // `JSDateParityTests.legacyFormsAreOutOfScope`, and the count of
        // stamps in both books that justifies it. Here the consequence is
        // visible rather than abstract: the entry falls out of the window
        // instead of into September.
        let js = try js()
        let log = [waste("2026-9-1", .string("warping"), .number(100))]
        let now = try at("2026-09-17T13:00:00Z")
        #expect(WasteTrend.trend(log, now: now).entries == 0,
                "a legacy form is now in scope — update the note in JSDate")
        let theirs = try theirs(js, log, now: now, months: 6, named: 3)
        #expect(theirs.entries == 1,
                "the engine stopped taking it — the divergence can go, and so can this test")
    }

    @Test("an entry with no date, and a date that is not a string")
    func oddDates() throws {
        let js = try js()
        for value in [JSONValue.null, .number(0), .bool(false), .string(""),
                      .number(1_789_000_000_000), .bool(true), .array([]), .object([:])] {
            try check([.object(["date": value, "failureType": .string("warping"),
                                "weight": .number(100)]),
                       waste("2026-08-15", .string("stringing"), .number(50))],
                      now: try at("2026-09-17T13:00:00Z"), "date \(value)", js)
        }
    }

    @Test("a failure type that is not a non-empty string is other")
    func oddTypes() throws {
        let js = try js()
        for value in [JSONValue.null, .string(""), .number(7), .bool(true), .bool(false),
                      .array([]), .object([:]), .string("other"), .string("  ")] {
            try check([waste("2026-09-02", value, .number(100)),
                       waste("2026-09-03", .string("warping"), .number(50))],
                      now: try at("2026-09-17T13:00:00Z"), "type \(value)", js)
        }
        try check([waste("2026-09-02", nil, .number(100))],
                  now: try at("2026-09-17T13:00:00Z"), "no type at all", js)
    }

    @Test("a weight that is not a positive number is nothing, not a negative")
    func weightsAreFloored() throws {
        // A negative gram would subtract from a month's scrap.
        let js = try js()
        let numbers = Awkward.numbers.filter { $0.isFinite && abs($0) < 1e300 }
        for value in Awkward.notNumbers + numbers.map({ JSONValue.number($0) }) {
            try check([waste("2026-09-02", .string("warping"), value),
                       waste("2026-09-03", .string("stringing"), .number(50))],
                      now: try at("2026-09-17T13:00:00Z"), "weight \(value)", js)
        }
    }

    @Test("rounding a running total is not rounding a sum")
    func runningRoundingMatches() throws {
        // The original rounds at EVERY step. Three entries of 0.05 g come to
        // 0.1 that way and 0.2 the other, and the two apps would print
        // different totals for the same log.
        let js = try js()
        try check((1...9).map { waste("2026-09-0\($0)", .string("warping"), .number(0.05)) },
                  now: try at("2026-09-17T13:00:00Z"), "nine entries of 0.05 g", js)
        try check((1...7).map { waste("2026-09-0\($0)", .string("warping"), .number(1.0 / 3.0)) },
                  now: try at("2026-09-17T13:00:00Z"), "seven thirds", js)
    }

    @Test("an empty log still draws every month in the window")
    func emptyLogMatches() throws {
        // A month with nothing thrown away is a real and good answer, unlike
        // "no hours printed" — so its total is 0 rather than absent.
        let js = try js()
        let now = try at("2026-09-17T13:00:00Z")
        try check([], now: now, "no entries at all", js)
        try check([.null, .bool(false), .number(0), .string("")], now: now, "falsy rows", js)
        try check([.string("x"), .number(3), .array([]), .bool(true)], now: now,
                  "truthy non-objects", js)
        #expect(WasteTrend.trend([], now: now).months.count == 6)
        #expect(WasteTrend.trend([], now: now).types.isEmpty,
                "an empty log named a failure type")
    }

    @Test("an entry outside the window is not counted")
    func windowExcludes() throws {
        let js = try js()
        try check([waste("2026-09-02", .string("warping"), .number(100)),
                   waste("2026-02-02", .string("warping"), .number(999)),
                   waste("2027-01-02", .string("warping"), .number(888))],
                  now: try at("2026-09-17T13:00:00Z"), "before and after", js)
    }
}
