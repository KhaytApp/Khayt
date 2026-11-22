import XCTest
@testable import KhaytCompanion

/**
 * DueDateParser turns whatever the desktop put in `dueDate` into a Date, and
 * decides whether an order is overdue.
 *
 * It drives the overdue badge and the overdue filter, so a slip here does not
 * throw — it quietly tells a shop an order is late when it is not, or hides one
 * that is. The desktop writes plain `yyyy-MM-dd`; older and imported orders
 * carry full ISO timestamps, and the parser also accepts three slash formats.
 *
 * The calendar-day cases are the ones worth pinning. The desktop side of this
 * codebase has already shipped a whole class of bug from deriving "today" in UTC
 * instead of the shop's own calendar (see test/local-dates.test.js); the same
 * mistake here would be just as invisible.
 */
final class DueDateParserTests: XCTestCase {

    private func day(_ d: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.dateComponents([.year, .month, .day], from: d)
    }

    func testParsesThePlainDateTheDesktopWrites() throws {
        let parts = day(try XCTUnwrap(DueDateParser.parse("2026-08-01")))
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 1, "the day must be the one written, not shifted by a timezone")
    }

    func testParsesAnISOTimestamp() {
        XCTAssertNotNil(DueDateParser.parse("2026-08-01T14:30:00.000Z"),
                        "imported and older orders carry full timestamps")
        XCTAssertNotNil(DueDateParser.parse("2026-08-01T14:30:00Z"),
                        "and some carry no fractional seconds")
    }

    func testParsesTheSlashFormatsItAdvertises() throws {
        XCTAssertEqual(day(try XCTUnwrap(DueDateParser.parse("2026/08/01"))).day, 1)
        XCTAssertEqual(day(try XCTUnwrap(DueDateParser.parse("01/08/2026"))).month, 8,
                       "dd/MM/yyyy is tried before MM/dd/yyyy")
    }

    func testSurroundingWhitespaceIsTolerated() {
        XCTAssertNotNil(DueDateParser.parse("  2026-08-01  "),
                        "a stray space in the store must not hide a real deadline")
    }

    func testEmptyIsNotADate() {
        // An order with no due date must not become "due 1 Jan 1970" and sit in
        // the overdue filter forever.
        XCTAssertNil(DueDateParser.parse(""))
        XCTAssertNil(DueDateParser.parse("   "))
    }

    func testGarbageIsNotCoercedIntoADate() {
        for junk in ["not a date", "//", "2026", "tomorrow", "T14:30:00Z"] {
            XCTAssertNil(DueDateParser.parse(junk), "\(junk) is not a due date")
        }
    }

    // MARK: - isOverdue, which is what the UI actually calls

    func testAMissingDueDateIsNeverOverdue() {
        // The nil path exists only here — parse() takes a non-optional.
        XCTAssertFalse(DueDateParser.isOverdue(nil))
        XCTAssertFalse(DueDateParser.isOverdue(""))
        XCTAssertFalse(DueDateParser.isOverdue("   "))
        XCTAssertFalse(DueDateParser.isOverdue("not a date"),
                       "an unparseable date must not brand an order late")
    }

    func testYesterdayIsOverdueAndTomorrowIsNot() {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let yesterday = df.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        let tomorrow = df.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)

        XCTAssertTrue(DueDateParser.isOverdue(yesterday))
        XCTAssertFalse(DueDateParser.isOverdue(tomorrow))
    }

    func testTodayIsNotYetOverdue() {
        // The comparison is against the START of today, so an order due today has
        // until the end of the day. Getting this wrong would mark a shop's whole
        // day's work late every morning.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        XCTAssertFalse(DueDateParser.isOverdue(df.string(from: Date())))
    }
}
