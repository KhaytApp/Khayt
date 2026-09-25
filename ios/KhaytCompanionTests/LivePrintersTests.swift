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

    private func make(_ counter: Counter, reportedAt: Date? = nil) -> LivePrinters {
        LivePrinters(interval: .milliseconds(20), cloudInterval: .milliseconds(20), backoff: .milliseconds(20)) {
            counter.calls += 1
            if counter.fail { throw URLError(.cannotConnectToHost) }
            return LiveSnapshot(printers: [self.reading("M1", progress: 42)],
                                source: reportedAt == nil ? .shop : .cloud, reportedAt: reportedAt)
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

    func testARelayedSnapshotTheMacStoppedUpdatingIsNotLive() async {
        let fresh = make(Counter(), reportedAt: Date().addingTimeInterval(-20))
        await fresh.refresh()
        XCTAssertTrue(fresh.isLive)
        XCTAssertEqual(fresh.source, .cloud)

        let quiet = make(Counter(), reportedAt: Date().addingTimeInterval(-600))
        await quiet.refresh()
        XCTAssertFalse(quiet.isLive, "ten minutes of silence is a Mac that is asleep, not a print at 42%")
        XCTAssertNil(quiet.reading(for: "M1"))
        XCTAssertNotNil(quiet.reportedAt, "…and the screen can say how long ago it last spoke")
    }

    /// The cloud's plaintext spells `lastUpdated` as epoch milliseconds, the
    /// LAN as an ISO string, and a field may be missing. None of it may empty
    /// the list.
    func testBothSpellingsOfTheReadingDecode() throws {
        let json = #"""
        [ {"id":"m1","name":"X1C","hasPrinterApi":true,"apiType":"bambu","state":"Printing","progress":42,
           "filename":"b.3mf","timeRemaining":3600,"tempNozzle":220,"tempBed":60,"error":null,
           "lastUpdated":1790331302000},
          {"id":"m2","name":"Voron","hasPrinterApi":true,"state":"Operational",
           "lastUpdated":"2026-09-25T10:15:02Z"},
          {"id":"m3"} ]
        """#
        let rows = try JSONDecoder().decode([MachineLiveStatus].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].progress, 42)
        XCTAssertTrue(rows[0].isPrinting, "the printer's own word, \"Printing\", capitalised")
        XCTAssertNotNil(rows[0].lastUpdated)
        XCTAssertEqual(rows[1].lastUpdated, "2026-09-25T10:15:02Z")
        XCTAssertFalse(rows[2].hasPrinterApi)
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
