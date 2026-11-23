import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The phone reads a printer's state through the shared closed sets (C2,
/// #2590): `lib/printer-activity.js` from KhaytCore's bundle, the file the Mac
/// and the desktop run, on `test/fixtures/printer-activity-vectors.json`.
final class PrinterActivityTests: XCTestCase {

    private struct Case: Decodable {
        let why: String
        let machine: JSONValue
        let entry: JSONValue?
        let status: Want
        struct Want: Decodable { let link: String; let activity: String? }
    }
    private struct Vectors: Decodable { let cases: [Case] }

    func testEverySharedVectorGivesLibsStatus() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "test/fixtures/printer-activity-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(v.cases.count, 160)
        for c in v.cases {
            guard case .object(let machine) = c.machine else { XCTFail(c.why); continue }
            var entry: [String: JSONValue]?
            if case .object(let e)? = c.entry { entry = e }
            let s = try XCTUnwrap(PrinterActivity.status(machine: machine, entry: entry), "\(c.why): the rule loaded")
            XCTAssertEqual(s.link, c.status.link, c.why)
            XCTAssertEqual(s.activity, c.status.activity, c.why)
        }
    }

    private func reading(_ state: String?, error: String? = nil, progress: Int? = nil,
                         api: String? = "prusalink") -> MachineLiveStatus {
        MachineLiveStatus(id: "M1", name: "MK4", hasPrinterApi: true, state: state, progress: progress, filename: nil,
                          timeRemaining: nil, tempNozzle: nil, tempBed: nil, error: error, lastUpdated: nil,
                          apiType: api)
    }

    /// The faults the substring rule had: a paused printer read as free, a
    /// busy word without "print" read as not printing, and "attention" or
    /// "halted" read as idle.
    func testWhatTheOldSubstringRuleGotWrong() {
        let paused = reading("PAUSED")
        XCTAssertTrue(paused.isPaused)
        XCTAssertFalse(paused.isPrinting)
        XCTAssertTrue(paused.isBusy, "paused is busy, never free")

        XCTAssertTrue(reading("BUSY").isPrinting, "PrusaLink BUSY is working")
        XCTAssertTrue(reading("processing", api: "duet").isPrinting)
        XCTAssertTrue(reading("Printing from SD", api: "octoprint").isPrinting)

        XCTAssertTrue(reading("ATTENTION").needsPerson, "a person is needed")
        XCTAssertTrue(reading("halted", api: "duet").needsPerson)
        XCTAssertFalse(reading("IDLE").needsPerson)

        XCTAssertFalse(reading("complete", progress: 100, api: "moonraker").isPrinting,
                       "a finished print with its progress at 100 is not printing")
        XCTAssertTrue(reading("Offline", api: "octoprint").saysUnlinked)
    }

    /// A reading with no state is one the Mac did not hear: never "stopped".
    func testANotHeardPrinterIsConnectingNotIdle() {
        let unheard = reading(nil)
        XCTAssertTrue(unheard.isUnheard)
        XCTAssertEqual(unheard.status?.link, "connecting")
        XCTAssertNil(unheard.status?.activity)
        XCTAssertFalse(unheard.isPrinting)
        XCTAssertEqual(reading(nil, error: "HTTP 401").status?.link, "unauthorized")
        XCTAssertEqual(reading(nil, error: "timed out").status?.link, "reconnecting")
    }

    /// A word in no table keeps the old reading, so a firmware word nobody
    /// has mapped never reads differently than it did.
    func testAnUnmappedWordKeepsTheOldReading() {
        let odd = reading("printing_layer_7", api: "moonraker")
        XCTAssertEqual(odd.status?.activity, "unknown")
        XCTAssertTrue(odd.isPrinting)
    }

    /// ConnectionHealthState mapped onto C2's link set, and a printer seen
    /// through a phone that cannot reach the shop has no activity.
    func testThePhonesOwnLinkIsInTheSameSet() {
        let links: [ConnectionHealthState: String] = [.unknown: "connecting", .connected: "online", .unreachable: "offline",
                                                      .unauthorized: "unauthorized", .pinTooShort: "unauthorized"]
        let shared = Set(["unpaired", "connecting", "online", "reconnecting", "offline", "unauthorized"])
        for (state, link) in links {
            XCTAssertEqual(state.link, link, state.rawValue)
            XCTAssertTrue(shared.contains(state.link))
        }
        let printing = reading("PRINTING").status!
        XCTAssertEqual(printing.seen(through: .connected), printing)
        XCTAssertEqual(printing.seen(through: .unreachable), PrinterStatus(link: "offline", activity: nil))
    }
}
