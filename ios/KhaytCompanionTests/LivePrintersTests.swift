import XCTest
@testable import KhaytCompanion

/// The printers are asked only while somebody is looking, and a Mac that does
/// not answer is said to be not live — never drawn from a stale reading.
@MainActor
final class LivePrintersTests: XCTestCase {

    private final class Counter: @unchecked Sendable { var calls = 0; var fail = false }

    private func reading(_ id: String, progress: Int) -> MachineLiveStatus {
        MachineLiveStatus(id: id, name: id, hasPrinterApi: true, state: "printing", progress: progress,
                          filename: "part.gcode", timeRemaining: 5_400, tempNozzle: 215, tempBed: 60,
                          error: nil, lastUpdated: nil, apiType: "moonraker")
    }

    private func make(_ counter: Counter) -> LivePrinters {
        LivePrinters(interval: .milliseconds(20), backoff: .milliseconds(20)) {
            counter.calls += 1
            if counter.fail { throw URLError(.cannotConnectToHost) }
            return [self.reading("M1", progress: 42)]
        }
    }

    func testNothingIsAskedUntilSomebodyWatches() async throws {
        let counter = Counter()
        _ = make(counter)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(counter.calls, 0)
    }

    func testWatchingPollsAndUnwatchingStops() async throws {
        let counter = Counter()
        let live = make(counter)
        live.watch()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(counter.calls, 1, "it keeps asking while watched")
        XCTAssertEqual(live.reading(for: "M1")?.progress, 42)

        live.unwatch()
        try await Task.sleep(for: .milliseconds(40))
        let after = counter.calls
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.calls, after, "nobody watching, nothing asked")
    }

    func testTheBackgroundStopsItAndTheForegroundResumesIt() async throws {
        let counter = Counter()
        let live = make(counter)
        live.watch()
        live.setActive(false)
        try await Task.sleep(for: .milliseconds(40))
        let asleep = counter.calls
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.calls, asleep, "a phone in a pocket polls nothing")
        live.setActive(true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(counter.calls, asleep)
        live.unwatch()
    }

    func testAMacThatStopsAnsweringIsNotLiveAndItsLastReadingIsNotOffered() async throws {
        let counter = Counter()
        let live = make(counter)
        await live.refresh()
        XCTAssertTrue(live.isLive)
        XCTAssertNotNil(live.reading(for: "M1"))

        counter.fail = true
        await live.refresh()
        XCTAssertFalse(live.isLive)
        XCTAssertNil(live.reading(for: "M1"), "a frozen bar drawn as if it were moving is the thing to avoid")
    }

    func testTheTimeLeftIsSaidInTheReadersLanguageNotAsEnglishLetters() {
        let r = reading("M1", progress: 10)
        let arabic = try? XCTUnwrap(r.eta(in: Locale(identifier: "ar")))
        XCTAssertNotNil(arabic)
        XCTAssertFalse(arabic?.contains("h") ?? true, "the desktop's 1h 30m is English letters on an Arabic screen: \(arabic ?? "")")
        XCTAssertEqual(r.eta(in: Locale(identifier: "en")), "1h 30m")
        XCTAssertEqual(r.finishesAt(from: Date(timeIntervalSince1970: 0)), Date(timeIntervalSince1970: 5_400))
    }
}
