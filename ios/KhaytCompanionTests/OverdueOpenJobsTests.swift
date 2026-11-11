import XCTest
@testable import KhaytCompanion

/**
 * Late means past its day AND still open.
 *
 * Turki saw a cancelled job marked overdue. The queue never showed one, because
 * it holds only live jobs, but History holds everything, and its cards, the
 * order page and the Overdue chip asked only whether the day had passed. The
 * rule is `lib/attention.js` `isOpenOrder`: completed, legacy delivered, quote,
 * cancelled and voided jobs are never late.
 */
final class OverdueOpenJobsTests: XCTestCase {

    private let longAgo = "2020-01-01"

    private func entry(_ status: String, extra: String = "") throws -> OrderLogEntry {
        let json = #"{"id":"INV-1","project":"Bracket","client":"Sample","status":"\#(status)","material":null,"price":10,"dueDate":"\#(longAgo)","date":"2019-12-20","paymentStatus":null,"quoteExpiresAt":null\#(extra)}"#
        return try JSONDecoder().decode(OrderLogEntry.self, from: Data(json.utf8))
    }

    func testACancelledJobPastItsDayIsNotOverdue() throws {
        let job = try entry("cancelled")
        XCTAssertTrue(DueDateParser.isOverdue(job.dueDate), "the day itself has passed")
        XCTAssertFalse(job.isOverdue, "but a cancelled job is never late")
        XCTAssertFalse(QueueOrder(entry: job).isOverdue, "nor on its order page")
    }

    func testFinishedJobsAreNeverOverdue() throws {
        for status in ["completed", "delivered", "quote"] {
            XCTAssertFalse(try entry(status).isOverdue, "\(status) is not open")
        }
    }

    func testAVoidedJobIsNeverOverdueWhateverItsStatus() throws {
        let job = try entry("pending", extra: #","voidedAt":"2020-01-02T10:00:00.000Z""#)
        XCTAssertTrue(job.isVoided)
        XCTAssertFalse(job.isOverdue)
        XCTAssertFalse(QueueOrder(entry: job).isOverdue, "the order page keeps the void")
    }

    func testAnOddVoidStampStillReadsAndStillCounts() throws {
        // Never let a field no screen prints empty History.
        let job = try entry("printing", extra: #","voidedAt":1700000000"#)
        XCTAssertTrue(job.isVoided)
        XCTAssertFalse(try entry("printing", extra: #","voidedAt":null"#).isVoided)
    }

    func testOpenJobsPastTheirDayAreStillOverdue() throws {
        for status in ["pending", "printing", "post", "qc", "on_hold", "shipped", "someday-new"] {
            XCTAssertTrue(try entry(status).isOverdue, "\(status) is open, so it is late")
        }
        let live = QueueOrder(id: "Q", project: nil, client: nil, status: "printing",
                              machine: nil, machineId: nil, dueDate: longAgo, priority: nil)
        XCTAssertTrue(live.isOverdue)
    }

    func testTheRuleMatchesTheSharedLib() throws {
        // lib/attention.js isOpenOrder, as desktop #2397 leaves it.
        let lib = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/attention.js"), encoding: .utf8)
        guard let start = lib.range(of: "function isOpenOrder(o) {"),
              let end = lib.range(of: "}", range: start.upperBound..<lib.endIndex) else {
            return XCTFail("isOpenOrder moved; keep OrderOpenness in step with it")
        }
        let body = String(lib[start.upperBound..<end.lowerBound])
        let regex = try NSRegularExpression(pattern: #"o\.status !== '([a-z_]+)'"#)
        let libClosed = Set(regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        })
        XCTAssertTrue(body.contains("!o.voidedAt"), "lib still closes voided jobs")
        XCTAssertTrue(libClosed.isSubset(of: OrderOpenness.closedStatuses),
                      "lib closes \(libClosed.subtracting(OrderOpenness.closedStatuses)) too")
    }
}
