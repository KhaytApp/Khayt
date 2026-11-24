import Foundation
import Testing
@testable import KhaytCore

/// `KhaytEngine.successRates` against the vectors the Windows/Linux app's own
/// test runs (`test/fixtures/printer-success-vectors.json`,
/// `test/printer-batch3.test.js`): the Mac and the phone count a printer's
/// prints exactly as the desktop does.
struct SuccessRatesTests {

    struct Case: Decodable {
        struct Input: Decodable { let machines: [JSONValue]?; let orders: [JSONValue]?; let from: String?; let to: String? }
        /// The caller's calendar, on cases that have one (the Windows/Linux app's #2702).
        struct CalendarOf: Decodable { let utcOffsetMinutes: Int }
        let why: String
        let input: Input
        let calendar: CalendarOf?
        let want: [KhaytEngine.SuccessRow]
    }
    /// `percent.cases`, on a fixture new enough to have them.
    struct Percent: Decodable {
        struct One: Decodable { let why: String; let rate: Double?; let want: Int? }
        let cases: [One]
    }
    struct Vectors: Decodable { let cases: [Case]; let percent: Percent? }

    @Test("the desktop's vectors: worst first, cancelled and unknown outside the rate, too few is not enough, the date window")
    func vectors() async throws {
        let engine = try KhaytEngine()
        let file = try Data(contentsOf: CrossAppFixtureTests.fixture("printer-success-vectors.json"))
        let cases = try JSONDecoder().decode(Vectors.self, from: file).cases
        #expect(cases.count >= 2, "the fixture lost its cases")
        var sawWindow = false, sawNil = false, sawNotEnough = false
        for c in cases {
            var zone: Calendar?
            if let minutes = c.calendar?.utcOffsetMinutes {
                var made = Calendar(identifier: .gregorian)
                made.timeZone = try #require(TimeZone(secondsFromGMT: minutes * 60))
                zone = made
            }
            let got = try await engine.successRates(orders: c.input.orders ?? [], machines: c.input.machines ?? [], from: c.input.from, to: c.input.to,
                                                    calendar: zone)
            #expect(got == c.want, Comment(rawValue: c.why))
            sawWindow = sawWindow || c.input.from != nil
            sawNil = sawNil || c.want.contains { $0.rate == nil }
            sawNotEnough = sawNotEnough || c.want.contains { !$0.enough && $0.decided > 0 }
        }
        // The vectors still cover what this test's name says.
        #expect(sawWindow && sawNil && sawNotEnough)
    }

    @Test("the days are the calendar's: the same instants, read in Riyadh, New York and UTC, with a daylight-saving change in between")
    func whoseDay() async throws {
        func zone(_ id: String) throws -> Calendar {
            var c = Calendar(identifier: .gregorian); c.timeZone = try #require(TimeZone(identifier: id)); return c
        }
        func run(_ at: JSONValue) -> JSONValue { .object(["machineId": .string("M"), "at": at]) }
        let orders: [JSONValue] = [.object(["id": .string("1"), "printRuns": .array([
            run(.string("2026-10-31T22:30:00.000Z")),      // Nov 1, 01:30 in Riyadh; Oct 31, 18:30 in New York
            run(.string("2026-11-01T03:30:00Z")),          // Nov 1 in Riyadh and UTC; Oct 31, 23:30 in New York (still daylight time)
            run(.string("2026-11-01T06:30:00+00:00")),     // Nov 1 everywhere: 01:30 in New York, just after its clocks went back
            run(.number(1_793_485_800_000)),               // the first instant again, as milliseconds
            run(.string("2026-11-01")),                    // a bare day is kept as written, whatever the zone
            run(.string("soon")), run(.null),
        ])])]
        let riyadh = KhaytEngine.runDays(orders, calendar: try zone("Asia/Riyadh"))
        #expect(riyadh["2026-10-31T22:30:00.000Z"] == .string("2026-11-01") && riyadh["#1793485800000"] == .string("2026-11-01"))
        #expect(riyadh["2026-11-01"] == .string("2026-11-01") && riyadh["soon"] == .string("") && riyadh.count == 6)
        let newYork = KhaytEngine.runDays(orders, calendar: try zone("America/New_York"))
        #expect(newYork["2026-10-31T22:30:00.000Z"] == .string("2026-10-31") && newYork["2026-11-01T03:30:00Z"] == .string("2026-10-31"))
        #expect(newYork["2026-11-01T06:30:00+00:00"] == .string("2026-11-01"), "the hour the clocks went back was put on the wrong day")
        // Asked for November 1 only. The counts differ by zone exactly as the days do.
        let engine = try KhaytEngine()
        func count(_ calendar: Calendar?) async throws -> Int {
            let rows = try await engine.successRates(orders: orders, machines: [], from: "2026-11-01", to: "2026-11-01", calendar: calendar)
            return rows.first.map { $0.finished + $0.failed + $0.cancelled + $0.unknown } ?? 0
        }
        // Whether the bundled rule has the hook yet decides what is checked.
        let inRiyadh = try await count(try zone("Asia/Riyadh")), sliced = try await count(nil)
        let hooked = inRiyadh != sliced
        if hooked {
            #expect(try await count(try zone("Asia/Riyadh")) == 5)      // all four instants and the bare day
            #expect(try await count(try zone("America/New_York")) == 2)  // the one after midnight there, and the bare day
            #expect(try await count(try zone("UTC")) == 3)
        } else {
            // The rule from before the hook: the UTC slice, whatever calendar is passed. Nothing breaks.
            #expect(try await count(try zone("Asia/Riyadh")) == 3)
        }
        // With no dates, no days are worked out and every run counts.
        let all = try await engine.successRates(orders: orders, machines: [], calendar: try zone("Asia/Riyadh"))
        #expect(all.first.map { $0.unknown } == 7)
    }

    @Test("a rate as a whole per cent never rounds a failure away")
    func percent() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.successPercent(0.92) == 92)
        #expect(try await engine.successPercent(1) == 100)
        #expect(try await engine.successPercent(0) == 0)
        #expect(try await engine.successPercent(0.995) == 99, "199 of 200 read as 100%")
        #expect(try await engine.successPercent(0.005) == 1, "1 of 200 read as 0%")
        #expect(try await engine.successPercent(nil) == nil)
        #expect(try await engine.successPercent(1.5) == nil)
        #expect(try await engine.successPercent(-0.1) == nil)
        // The desktop's own vectors, when the fixture carries them.
        let file = try Data(contentsOf: CrossAppFixtureTests.fixture("printer-success-vectors.json"))
        for c in try JSONDecoder().decode(Vectors.self, from: file).percent?.cases ?? [] {
            #expect(try await engine.successPercent(c.rate) == c.want, Comment(rawValue: c.why))
        }
    }

    @Test("what the phone's line is made of: the counts, the rate, and how many runs are needed")
    func line() async throws {
        let engine = try KhaytEngine()
        let needed = try await engine.successRunsNeeded()
        #expect(needed == 5)
        func run(_ result: String?) -> JSONValue {
            var r: [String: JSONValue] = ["machineId": .string("U1"), "at": .string("2026-11-20")]
            if let result { r["result"] = .string(result); r["resultSource"] = .string("printer") }
            return .object(r)
        }
        func rows(_ results: [String?]) async throws -> [KhaytEngine.SuccessRow] {
            try await engine.successRates(orders: [.object(["id": .string("1"), "printRuns": .array(results.map(run))])],
                                          machines: [.object(["id": .string("U1")]), .object(["id": .string("idle")])])
        }
        // "23 finished, 2 failed · 3 cancelled not counted · 92%"
        let busy = try await rows(Array(repeating: "finished", count: 23) + ["failed", "failed", "cancelled", "cancelled", "cancelled", nil])
        let u1 = try #require(busy.first { $0.machineId == "U1" })
        #expect(u1 == .init(machineId: "U1", finished: 23, failed: 2, cancelled: 3, unknown: 1, rate: 0.92, enough: true))
        #expect(u1.decided == 25)
        // A machine with no runs still has a row, last, with no rate.
        #expect(busy.last == .init(machineId: "idle", finished: 0, failed: 0, cancelled: 0, unknown: 0, rate: nil, enough: false))
        // "Not enough prints yet: 3 of 5 needed": three decided runs, however many were cancelled.
        let few = try #require(try await rows(["finished", "finished", "failed", "cancelled", "cancelled", "cancelled"]).first { $0.machineId == "U1" })
        #expect(few.decided == 3 && !few.enough && few.decided < needed)
        // Exactly enough.
        #expect(try #require(try await rows(Array(repeating: "finished", count: 5)).first).enough)
        // A deleted job's runs are nobody's.
        let gone = try await engine.successRates(
            orders: [.object(["id": .string("1"), "deleted": .bool(true), "printRuns": .array([run("failed")])])],
            machines: [.object(["id": .string("U1")])])
        #expect(gone == [.init(machineId: "U1", finished: 0, failed: 0, cancelled: 0, unknown: 0, rate: nil, enough: false)])
    }
}
