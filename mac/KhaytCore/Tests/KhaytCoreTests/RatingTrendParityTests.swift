import Foundation
import Testing
@testable import KhaytCore

/// What customers said about the work, against the JavaScript it came from.
///
/// The two faults the rule carries a fix for are both about which jobs count,
/// so most of these cases are jobs that only just do or only just do not.
@MainActor
struct RatingTrendParityTests {

    private func js() throws -> JSModule { try JSModule(["rating-trend"]) }

    private func check(_ orders: [JSONValue], _ months: [String], min: Int,
                       _ what: String, _ js: JSModule) throws {
        let mine = RatingTrend.trend(orders: orders, months: months, minResponses: min)
        let v = try js.value("KhaytRatingTrend.trend(ARG0, ARG1, {minResponses: ARG2})",
                             [.array(orders), .array(months.map(JSONValue.string)),
                              .number(Double(min))])
        guard case .object(let o) = v, case .array(let rows)? = o["points"] else {
            Issue.record("not a report"); return
        }
        let theirPoints: [RatingTrend.Point] = rows.map { row in
            guard case .object(let r) = row else { return .init(month: "?", responses: -1,
                                                                average: nil) }
            var avg: Double?; if case .number(let n)? = r["average"] { avg = n }
            return .init(month: JSSemantics.text(r["month"]),
                         responses: Int(JSSemantics.number(r["responses"])), average: avg)
        }
        var avg: Double?; if case .number(let n)? = o["average"] { avg = n }
        var enough = false; if case .bool(let b)? = o["enough"] { enough = b }
        let theirs = RatingTrend.Report(
            points: theirPoints, responses: Int(JSSemantics.number(o["responses"])),
            average: avg, allTimeResponses: Int(JSSemantics.number(o["allTimeResponses"])),
            enough: enough)
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine)
              js    \(theirs)
            """))
    }

    private func rated(_ rating: JSONValue, completedAt: String = "", date: String = "") -> JSONValue {
        var o: [String: JSONValue] = ["survey": .object(["rating": rating])]
        if !completedAt.isEmpty { o["completedAt"] = .string(completedAt) }
        if !date.isEmpty { o["date"] = .string(date) }
        return .object(o)
    }

    private let window = ["2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09"]

    @Test("a rating with no completedAt still counts, which is the fix")
    func fallsBackToTheDate() throws {
        // A book written before that stamp existed, an imported one, or a job
        // that went straight to delivered has a rating and no `completedAt` —
        // and a rating a customer actually gave was dropped.
        let js = try js()
        try check([rated(.number(5), date: "2026-09-02"),
                   rated(.number(4), completedAt: "2026-09-03T10:00:00Z"),
                   rated(.number(3), completedAt: "2026-09-04"),
                   rated(.number(2))],
                  window, min: 3, "with and without the stamp", js)
    }

    @Test("the caption describes the window, not the whole book")
    func captionIsTheWindow() throws {
        // Six dots at 4.8 under the words "Avg 3.2 / 5" is a figure that
        // contradicts every point above it.
        let js = try js()
        try check([rated(.number(2), date: "2024-01-05"),
                   rated(.number(2), date: "2024-02-05"),
                   rated(.number(5), date: "2026-08-05"),
                   rated(.number(5), date: "2026-09-05")],
                  window, min: 3, "old ratings and new", js)
        let mine = RatingTrend.trend(
            orders: [rated(.number(2), date: "2024-01-05"),
                     rated(.number(5), date: "2026-09-05")], months: window)
        #expect(mine.average == 5, "the caption took in the whole book")
        #expect(mine.responses == 1)
        #expect(mine.allTimeResponses == 2, "the all-time count is still available")
    }

    @Test("a month with nothing said has no average, so the line can gap")
    func emptyMonthsGap() throws {
        let js = try js()
        try check([rated(.number(4), date: "2026-09-01")], window, min: 3, "one month only", js)
        try check([], window, min: 3, "nothing at all", js)
        try check([rated(.number(4), date: "2026-09-01")], [], min: 3, "no months asked for", js)
    }

    @Test("only one to five is a rating")
    func ratingBounds() throws {
        let js = try js()
        for raw: JSONValue in [.number(1), .number(5), .number(0), .number(6), .number(-1),
                               .number(3.5), .string("4"), .string(""), .string("x"),
                               .null, .bool(true), .bool(false), .array([]), .object([:])] {
            let mine = RatingTrend.ratingOf(rated(raw, date: "2026-09-01"))
            let theirs = try js.value("KhaytRatingTrend.ratingOf(ARG0)",
                                      [rated(raw, date: "2026-09-01")])
            var n: Double?; if case .number(let v) = theirs { n = v }
            #expect(mine == n, Comment(rawValue: "\(raw)"))
        }
        // A job with no survey at all, and one whose survey is not an object.
        for order: JSONValue in [.object([:]), .object(["survey": .null]),
                                 .object(["survey": .string("5")]), .null,
                                 .string("x"), .number(1)] {
            let mine = RatingTrend.ratingOf(order)
            let theirs = try js.value("KhaytRatingTrend.ratingOf(ARG0)", [order])
            var n: Double?; if case .number(let v) = theirs { n = v }
            #expect(mine == n, Comment(rawValue: "\(order)"))
        }
    }

    @Test("a timestamp goes through the clock; a plain day is sliced")
    func monthOfMatches() throws {
        // Parsing a plain day would put it at midnight UTC and move it a day
        // for half the world.
        let js = try js()
        for order: JSONValue in [
            rated(.number(5), completedAt: "2026-09-30T23:30:00Z"),
            rated(.number(5), completedAt: "2026-09-01T00:30:00Z"),
            rated(.number(5), completedAt: "2026-09-30"),
            rated(.number(5), date: "2026-09-30"),
            rated(.number(5), completedAt: "not a date"),
            rated(.number(5), date: "not a date"),
            rated(.number(5), date: "2026-9-3"),
            rated(.number(5)),
            .object([:]), .null,
        ] {
            let theirs = try js.value("KhaytRatingTrend.monthOf(ARG0)", [order])
            #expect(.string(RatingTrend.monthOf(order)) == theirs,
                    Comment(rawValue: "\(order)"))
        }
    }

    @Test("how many responses are enough")
    func enoughToDraw() throws {
        let js = try js()
        let two = [rated(.number(4), date: "2026-09-01"), rated(.number(5), date: "2026-09-02")]
        for min in [3, 2, 0, 1, 10, -1] {
            try check(two, window, min: min, "min \(min)", js)
        }
        #expect(RatingTrend.minResponses == 3, "the default is the module's")
    }
}
