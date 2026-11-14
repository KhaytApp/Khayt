import XCTest
@testable import KhaytCompanion

final class JobDueTests: XCTestCase {
    private var today: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15))!
    }

    func testDaysLateCountsGregorianDays() {
        XCTAssertEqual(JobDue.daysLate(due: "2026-11-08", today: today), 3)
        XCTAssertEqual(JobDue.daysLate(due: "2026-11-10", today: today), 1)
        XCTAssertNil(JobDue.daysLate(due: "2026-11-11", today: today))
        XCTAssertNil(JobDue.daysLate(due: "2026-11-20", today: today))
        XCTAssertNil(JobDue.daysLate(due: nil, today: today))
    }

    func testOwingIsRedOnlyWhenOverdue() {
        XCTAssertTrue(JobDue.owingIsOverdue(owed: 90, due: "2026-11-08", today: today))
        XCTAssertFalse(JobDue.owingIsOverdue(owed: 90, due: "2026-11-12", today: today))
        XCTAssertFalse(JobDue.owingIsOverdue(owed: 0, due: "2026-11-08", today: today))
        XCTAssertFalse(JobDue.owingIsOverdue(owed: 90, due: nil, today: today))
    }
}
