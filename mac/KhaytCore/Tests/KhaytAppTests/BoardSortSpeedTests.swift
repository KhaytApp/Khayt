import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The board sorted each column by parsing two dates per comparison through
/// `DateFormatter`, and built the whole board once per column: most of the
/// time the Board and the Jobs screen took to draw (Nov 2026). A plain day is
/// now read by hand and each job's days once per sort. Same answers.
@MainActor
struct BoardSortSpeedTests {
    /// What `Order.day` answered before, for a plain day.
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = .book
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @Test("a plain day reads as the formatter read it, and an impossible one is left to it")
    func plainDayMatchesTheFormatter() {
        for s in ["2026-11-02", "2024-02-29", "2026-01-01", "2026-12-31", "1999-07-15"] {
            #expect(Order.plainDay(Substring(s)) == Self.formatter.date(from: s), "\(s)")
            #expect(Order.day(s) == Self.formatter.date(from: s), "\(s)")
        }
        for s in ["2026-02-31", "2025-02-29", "2026-13-01", "2026-00-10", "2026-1-02", "26-11-02", "2026/11/02", "abcd-ef-gh", ""] {
            #expect(Order.plainDay(Substring(s)) == nil, "\(s) is not a plain day")
        }
        // A full timestamp still goes the instant's way.
        #expect(Order.day("2026-11-02T22:30:00Z") != nil)
    }

    @Test("the board's order is the comparison's order")
    func boardSortedMatchesBoardOrder() {
        func job(_ id: String, priority: Bool = false, due: String = "", date: String) -> Order {
            let row: JSONValue = .object(["id": .string(id), "date": .string(date), "status": .string("pending"),
                                          "project": .string(id), "priority": .bool(priority),
                                          "dueDate": .string(due)])
            return try! JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
        }
        let jobs = [job("A", due: "2026-11-09", date: "2026-11-01"),
                    job("B", priority: true, date: "2026-10-01"),
                    job("C", due: "2026-11-03", date: "2026-10-20"),
                    job("D", date: "2026-09-01"),
                    job("E", due: "2026-11-03", date: "2026-10-01")]
        #expect(Shop.boardSorted(jobs).map(\.id) == jobs.sorted(by: Shop.boardOrder).map(\.id))
        #expect(Shop.boardSorted(jobs).map(\.id) == ["B", "E", "C", "A", "D"])
    }
}
