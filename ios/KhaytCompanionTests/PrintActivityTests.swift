import XCTest
@testable import KhaytCompanion

/// The Live Activity's rules — pure, so ActivityKit is not needed to hold them.
final class PrintActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ id: String, _ state: String?, progress: Int? = 40, left: Int? = 3_600,
                         error: String? = nil, file: String? = "bracket.gcode") -> MachineLiveStatus {
        MachineLiveStatus(id: id, name: "X1C", hasPrinterApi: true, state: state, progress: progress,
                          filename: file, timeRemaining: left, tempNozzle: nil, tempBed: nil, error: error,
                          lastUpdated: nil, apiType: nil)
    }

    private func printing(progress: Int = 40, ends: Date? = nil) -> PrintActivityPlan.State {
        .init(phase: .printing, job: "bracket.gcode", progress: progress, startedAt: now.addingTimeInterval(-600),
              endsAt: ends ?? now.addingTimeInterval(3_600))
    }

    func testAPrintTheAppSeesStartsOneActivityThatEndsWhenThePrintDoes() {
        let steps = PrintActivityPlan.steps(readings: ["M": reading("M", "printing")], running: [:], now: now)
        guard case let .start(id, name, state)? = steps.first else { return XCTFail("\(steps)") }
        XCTAssertEqual(id, "M"); XCTAssertEqual(name, "X1C")
        XCTAssertEqual(state.endsAt, now.addingTimeInterval(3_600), "the countdown runs from the end date")
        XCTAssertEqual(state.phase, .printing)
    }

    func testAMachineThatDropsOutOfTheReadingsIsLeftAlone() {
        XCTAssertEqual(PrintActivityPlan.steps(readings: [:], running: ["M": printing()], now: now), [],
                       "not hearing about a printer is not the print ending")
    }

    func testPausedIsStillAPrint() {
        let steps = PrintActivityPlan.steps(readings: ["M": reading("M", "paused")], running: ["M": printing()], now: now)
        guard case let .update(_, state)? = steps.first else { return XCTFail("\(steps)") }
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(PrintActivityPlan.steps(readings: ["M": reading("M", "paused")], running: [:], now: now), [],
                       "a print first seen paused does not start one")
    }

    func testTheOutcomeIsTheAlertsOutcome() {
        func end(_ r: MachineLiveStatus) -> PrintActivityPlan.State.Phase? {
            if case let .end(_, s)? = PrintActivityPlan.steps(readings: ["M": r], running: ["M": printing()], now: now).first { return s.phase }
            return nil
        }
        XCTAssertEqual(end(reading("M", "idle")), .finished)
        XCTAssertEqual(end(reading("M", "standby", error: "Nozzle clog")), .failed)
        XCTAssertEqual(end(reading("M", "cancelled")), .cancelled)
    }

    func testOnlyChangesWorthSeeingAreSent() {
        let a = printing()
        XCTAssertFalse(PrintActivityPlan.worthSending(from: a, to: a))
        XCTAssertFalse(PrintActivityPlan.worthSending(from: a, to: printing(ends: a.endsAt!.addingTimeInterval(30))),
                       "half a minute of drift: the countdown already covers it")
        XCTAssertTrue(PrintActivityPlan.worthSending(from: a, to: printing(ends: a.endsAt!.addingTimeInterval(120))))
        XCTAssertTrue(PrintActivityPlan.worthSending(from: a, to: printing(progress: 41)))
    }

    /// The alert had the same hole: a pause read as "Print finished".
    func testPausingAPrintIsNotAFinishedAlert() {
        var detector = FinishDetector()
        _ = detector.observe(["M": reading("M", "printing")], now: now)
        XCTAssertEqual(detector.observe(["M": reading("M", "paused")], now: now.addingTimeInterval(60)), [])
        XCTAssertEqual(detector.observe(["M": reading("M", "printing")], now: now.addingTimeInterval(120)), [])
        XCTAssertEqual(detector.observe(["M": reading("M", "idle")], now: now.addingTimeInterval(180)).count, 1,
                       "and the real ending still alerts")
    }
}
