import Foundation
import Testing
@testable import KhaytCore

/// The End of Day Report's figures, including the three desktop sums it
/// corrects (time logged in `hours`, the shop's own day, waste called waste).
@MainActor
struct EndOfDayTests {
    let day = "2026-11-02"
    /// A test day function: an instant's first ten characters, so the tests
    /// do not depend on the machine's time zone.
    let dayOf: (String) -> String = { String($0.prefix(10)) }

    func order(_ id: String, status: String, completedAt: String? = nil, due: String? = nil,
               extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "project": .string("Job \(id)"),
                                      "status": .string(status)]
        if let completedAt { o["completedAt"] = .string(completedAt) }
        if let due { o["dueDate"] = .string(due) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test func countsTheDayAndOnlyTheDay() {
        let orders = [
            order("A", status: "completed", completedAt: "2026-11-02T09:00:00+03:00"),
            order("B", status: "completed", completedAt: "2026-11-01T22:00:00+03:00"),
            order("C", status: "printing", due: "2026-11-02"),
            order("D", status: "pending", due: "2026-10-30"),
            order("E", status: "quote", due: "2026-11-02"),
            order("F", status: "completed", completedAt: "2026-11-02T15:00:00+03:00",
                  extra: ["nonBusiness": .bool(true)]),
        ]
        let facts: [EndOfDay.Facts] = [
            .init(finished: true, open: false, revenue: 100),
            .init(finished: true, open: false, revenue: 50),
            .init(finished: false, open: true, revenue: 0),
            .init(finished: false, open: true, revenue: 0),
            .init(finished: false, open: false, revenue: 0),
            .init(finished: true, open: false, revenue: 30),
        ]
        let r = EndOfDay.report(day: day, orders: orders, facts: facts, waste: [], time: [], dayOf: dayOf)
        #expect(r.finished.map(\.id) == ["F", "A"])          // newest first
        #expect(r.revenue == 100)                             // F is not business
        #expect(r.inProgress == 2)
        #expect(r.dueNotDone.map(\.id) == ["C"])              // a quote is not due work
        #expect(r.overdue == 1)
    }

    @Test func timeIsReadFromHoursAsBothAppsWriteIt() {
        let time: [JSONValue] = [
            .object(["date": .string(day), "hours": .number(1.5)]),
            .object(["date": .string(day), "hours": .string("2")]),
            .object(["date": .string(day), "durationMins": .number(30)]),
            .object(["date": .string("2026-11-01"), "hours": .number(8)]),
        ]
        let r = EndOfDay.report(day: day, orders: [], facts: [], waste: [], time: time, dayOf: dayOf)
        #expect(r.hoursLogged == 4)
    }

    @Test func wasteIsTheDaysGrams() {
        let waste: [JSONValue] = [
            .object(["date": .string(day), "weight": .number(40)]),
            .object(["date": .string(day), "weight": .string("12.5")]),
            .object(["date": .string(day), "weight": .number(-3)]),
            .object(["date": .string("2026-11-01"), "weight": .number(500)]),
        ]
        let r = EndOfDay.report(day: day, orders: [], facts: [], waste: waste, time: [], dayOf: dayOf)
        #expect(r.wasteGrams == 52.5)
        #expect(r.wasteEntries == 3)
    }

    @Test func aRiyadhMorningIsTodayNotYesterday() {
        // 01:30 in Riyadh is 22:30 UTC the day before: the desktop's
        // `startsWith(today)` counted it toward yesterday.
        let orders = [order("A", status: "completed", completedAt: "2026-11-01T22:30:00Z")]
        let riyadh = TimeZone(identifier: "Asia/Riyadh")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = riyadh
        let dayOf: (String) -> String = { stamp in
            Calendar.instant(stamp).map { d in
                let c = cal.dateComponents([.year, .month, .day], from: d)
                return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            } ?? String(stamp.prefix(10))
        }
        let r = EndOfDay.report(day: day, orders: orders,
                                facts: [.init(finished: true, open: false, revenue: 10)],
                                waste: [], time: [], dayOf: dayOf)
        #expect(r.finished.count == 1)
    }

    @Test func theEngineSaysFinishedOpenAndNetRevenue() async throws {
        let engine = try KhaytEngine()
        let orders: [JSONValue] = [
            order("A", status: "completed", extra: ["price": .number(115)]),
            order("B", status: "printing"),
            order("C", status: "cancelled"),
            order("D", status: "quote"),
        ]
        let facts = try await engine.endOfDayFacts(orders: orders, settings: [:], clients: [])
        #expect(facts.map(\.finished) == [true, false, false, false])
        #expect(facts.map(\.open) == [false, true, false, false])
        #expect(facts[0].revenue > 0)
        #expect(facts[1].revenue == 0)
    }
}
