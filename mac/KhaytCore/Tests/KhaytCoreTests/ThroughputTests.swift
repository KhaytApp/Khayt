import Foundation
import Testing
@testable import KhaytCore

/// When the shop finishes work, through the engine.
///
/// `test/throughput.test.js` pins the rules. The hour is read in the machine's
/// own zone by design — a shop asking when it is busy means its own clock — so
/// these fix the instant rather than the calendar.
@Suite struct ThroughputTests {

    /// 2023-01-01 was a Sunday, so day 0 lines up with `getDay() == 0`.
    static func finishedAt(_ day: Int, _ hour: Int) -> String {
        var parts = DateComponents()
        parts.year = 2023; parts.month = 1; parts.day = 1 + day
        parts.hour = hour; parts.minute = 0
        let when = Calendar(identifier: .gregorian).date(from: parts) ?? Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: when)
    }

    static func job(_ id: String, day: Int, hour: Int,
                    status: String = "completed", voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "status": .string(status),
            "completedAt": .string(finishedAt(day, hour)),
        ]
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    /// Friday and Saturday closed — the Saudi weekend, which is the shop's.
    static let open = [true, true, true, true, true, false, false]

    static func run(_ engine: KhaytEngine, _ orders: [JSONValue],
                    minimum: Int = 1) async throws -> KhaytEngine.Throughput {
        try await engine.throughput(orders: orders, openDays: open, minimum: minimum)
    }

    @Test("each finished job lands in its own day and hour")
    func itLandsWhereItBelongs() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("a", day: 2, hour: 14), Self.job("b", day: 2, hour: 14),
            Self.job("c", day: 4, hour: 9),
        ])
        #expect(report.matrix[2][14] == 2)
        #expect(report.matrix[4][9] == 1)
        #expect(report.totals.jobs == 3)
        #expect(report.totals.busiestDay == 2)
        #expect(report.totals.busiestHour == 14)
    }

    @Test("delivered work counts; unfinished, voided and untimed do not")
    func onlyRealFinishedWork() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("a", day: 1, hour: 10, status: "delivered"),
            Self.job("b", day: 1, hour: 10, status: "printing"),
            Self.job("c", day: 1, hour: 10, voided: true),
            .object(["id": .string("d"), "status": .string("completed")]),
        ])
        #expect(report.totals.jobs == 1)
    }

    /// Printers running unattended over a weekend, or somebody in on their day
    /// off. Neither app has said it.
    @Test("work finishing on a day the shop is closed is counted and shared")
    func closedDaysAreVisible() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("a", day: 1, hour: 10),
            Self.job("b", day: 5, hour: 23),
            Self.job("c", day: 6, hour: 3),
            Self.job("d", day: 6, hour: 4),
        ])
        #expect(report.totals.onClosedDays == 3)
        #expect(report.totals.closedDayShare == 0.75)
        #expect(report.byDay[5].open == false)
        #expect(report.byDay[1].open == true)
    }

    /// A grid of four marks in 168 cells is not a picture of anything, and a
    /// reader will find a pattern in it regardless.
    @Test("the grid says whether there is enough behind it to read")
    func itKnowsWhenItIsThin() async throws {
        let engine = try KhaytEngine()
        let thin = try await Self.run(engine, [Self.job("a", day: 1, hour: 10)], minimum: 10)
        #expect(thin.totals.enough == false)
        #expect(thin.totals.jobs == 1, "and the figures are still true")
    }

    @Test("the open days come from working-week, so both apps agree on the weekend")
    func openDaysAreShared() async throws {
        let engine = try KhaytEngine()
        let closedFriSat = try await engine.openDays(settings: [
            "workingHours": .object([
                "sun": .number(8), "mon": .number(8), "tue": .number(8),
                "wed": .number(8), "thu": .number(8),
                "fri": .number(0), "sat": .number(0),
            ]),
        ])
        #expect(closedFriSat == [true, true, true, true, true, false, false])
    }

    /// A screen can only have been reviewed against data that reaches it.
    @Test("the sample shop has enough finished work to draw the grid")
    func theSampleReachesIt() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root, case .array(let orders)? = book["printLog"] else {
            Issue.record("could not read the sample shop"); return
        }
        let engine = try KhaytEngine()
        let report = try await engine.throughput(orders: orders, openDays: Self.open, minimum: 10)
        #expect(report.totals.enough, "the sample draws only the thin state")
        #expect(report.totals.onClosedDays > 0,
                "no work finishes on a closed day, so that sentence is undrawn")
    }
}
