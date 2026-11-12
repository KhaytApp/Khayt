import XCTest
@testable import KhaytCompanion

/// The job page's ONE next step (`JobNextStep`, a temporary stand-in for the
/// shared lib rule), for every stage.
final class JobNextStepTests: XCTestCase {
    func testAQuoteIsApproved() {
        XCTAssertEqual(JobNextStep.next(status: "quote"), .approveQuote)
        XCTAssertEqual(JobNextStep.approveQuote.verbKey, "quote.approve")
    }

    func testEachWorkingStageMovesOneOn() {
        XCTAssertEqual(JobNextStep.next(status: "pending"), .advance(to: .printing))
        XCTAssertEqual(JobNextStep.next(status: "printing"), .advance(to: .post))
        XCTAssertEqual(JobNextStep.next(status: "post"), .advance(to: .qc))
        XCTAssertEqual(JobNextStep.next(status: "qc"), .advance(to: .completed))
    }

    func testTheVerbs() {
        XCTAssertEqual(JobNextStep.advance(to: .printing).verbKey, "job.next.start_printing")
        XCTAssertEqual(JobNextStep.advance(to: .post).verbKey, "job.next.mark_printed")
        XCTAssertEqual(JobNextStep.advance(to: .qc).verbKey, "job.next.send_to_qc")
        XCTAssertEqual(JobNextStep.advance(to: .completed).verbKey, "job.next.mark_ready")
        XCTAssertEqual(JobNextStep.handOver.verbKey, "job.next.hand_over")
        XCTAssertEqual(JobNextStep.recordPayment.verbKey, "pay.modal_title")
        XCTAssertEqual(JobNextStep.resume(to: .post).verbKey, "job.next.resume")
    }

    /// Owing money on a working job does not jump the queue: the work does.
    func testOwingDoesNotReplaceTheWorkStep() {
        XCTAssertEqual(JobNextStep.next(status: "printing", owed: 90), .advance(to: .post))
    }

    func testAFinishedJobNotSentIsHandedOverFirst() {
        XCTAssertEqual(JobNextStep.next(status: "completed", owed: 90, canHandOver: true), .handOver)
        XCTAssertEqual(JobNextStep.next(status: "completed", canHandOver: true), .handOver)
    }

    func testAFinishedJobWithABalanceRecordsAPayment() {
        XCTAssertEqual(JobNextStep.next(status: "completed", owed: 90), .recordPayment)
        XCTAssertEqual(JobNextStep.next(status: "delivered", owed: 0.5), .recordPayment)
        XCTAssertEqual(JobNextStep.next(status: "shipped", owed: 12), .recordPayment)
    }

    func testAFinishedPaidJobHasNoNextStep() {
        XCTAssertNil(JobNextStep.next(status: "completed", owed: 0))
        XCTAssertNil(JobNextStep.next(status: "delivered"))
        // A rounding crumb is not a balance.
        XCTAssertNil(JobNextStep.next(status: "completed", owed: 0.001))
    }

    /// On hold resumes to the stage it was in, or Pending when that is unknown.
    func testAHeldJobResumes() {
        XCTAssertEqual(JobNextStep.next(status: "on_hold"), .resume(to: .pending))
        XCTAssertEqual(JobNextStep.next(status: "on_hold", heldFrom: .printing), .resume(to: .printing))
        XCTAssertEqual(JobNextStep.next(status: "on_hold", heldFrom: .qc), .resume(to: .qc))
        // Not a stage to resume into: Pending.
        XCTAssertEqual(JobNextStep.next(status: "on_hold", heldFrom: .completed), .resume(to: .pending))
        XCTAssertNil(JobNextStep.next(status: "on_hold", voided: true))
    }

    func testTheStageBeforeHoldComesFromTheHistory() {
        XCTAssertEqual(JobNextStep.stageBeforeHold(history: ["pending", "printing", "on_hold"]), .printing)
        XCTAssertEqual(JobNextStep.stageBeforeHold(history: ["pending", "on_hold", "post", "on_hold"]), .post)
        XCTAssertEqual(JobNextStep.stageBeforeHold(history: ["quote", "pending", "on_hold", "on_hold"]), .pending)
        XCTAssertNil(JobNextStep.stageBeforeHold(history: ["on_hold"]))
        XCTAssertNil(JobNextStep.stageBeforeHold(history: ["pending", "printing"]))
        XCTAssertNil(JobNextStep.stageBeforeHold(history: []))
    }

    func testCancelledAndVoidedJobsHaveNoNextStep() {
        XCTAssertNil(JobNextStep.next(status: "cancelled"))
        XCTAssertNil(JobNextStep.next(status: "printing", voided: true))
        XCTAssertNil(JobNextStep.next(status: "completed", voided: true, owed: 50))
        XCTAssertNil(JobNextStep.next(status: "something-new"))
    }

    func testEveryVerbIsInEveryLanguage() {
        let steps: [JobNextStep] = [.approveQuote, .advance(to: .printing), .advance(to: .post),
                                    .advance(to: .qc), .advance(to: .completed), .handOver, .recordPayment,
                                    .resume(to: .pending)]
        let before = L10n.currentLanguage
        defer { L10n.setLanguage(before) }
        for lang in AppLanguage.allCases where lang != .system {
            L10n.setLanguage(lang)
            for step in steps {
                XCTAssertNotEqual(L10n.tr(step.verbKey), step.verbKey, "\(lang) \(step)")
            }
        }
    }

    func testDaysLateCountsGregorianDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15))!
        XCTAssertEqual(JobNextStep.daysLate(due: "2026-11-08", today: today), 3)
        XCTAssertEqual(JobNextStep.daysLate(due: "2026-11-10", today: today), 1)
        XCTAssertNil(JobNextStep.daysLate(due: "2026-11-11", today: today))
        XCTAssertNil(JobNextStep.daysLate(due: "2026-11-20", today: today))
        XCTAssertNil(JobNextStep.daysLate(due: nil, today: today))
    }

    func testOwingIsRedOnlyWhenOverdue() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
        XCTAssertTrue(JobNextStep.owingIsOverdue(owed: 90, due: "2026-11-08", today: today))
        XCTAssertFalse(JobNextStep.owingIsOverdue(owed: 90, due: "2026-11-12", today: today))
        XCTAssertFalse(JobNextStep.owingIsOverdue(owed: 0, due: "2026-11-08", today: today))
        XCTAssertFalse(JobNextStep.owingIsOverdue(owed: 90, due: nil, today: today))
    }
}
