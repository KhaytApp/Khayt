import XCTest
@testable import KhaytCompanion

/// What the phone hands Khayt Cloud for Live Activity pushes, and what it can
/// read back from one (khayt-cloud "Live Activities", #112).
final class LiveActivityPushTests: XCTestCase {
    typealias State = PrintActivityAttributes.ContentState

    func testTheContractsExamplePayloadDecodes() throws {
        // The `content-state` from docs/api-contract.md, decoded the way the
        // system does it: a plain JSONDecoder, default strategies.
        let json = #"{ "phase": "printing", "progress": 42.5, "job": "Bracket ×4", "startedAt": 781776000, "endsAt": 781785000 }"#
        let s = try JSONDecoder().decode(State.self, from: Data(json.utf8))
        XCTAssertEqual(s.phase, .printing)
        XCTAssertEqual(s.progress, 43, "a fractional percent rounds instead of failing the whole update")
        XCTAssertEqual(s.job, "Bracket ×4")
        XCTAssertEqual(s.startedAt, Date(timeIntervalSinceReferenceDate: 781_776_000), "seconds since 2001")
        XCTAssertEqual(s.endsAt, Date(timeIntervalSince1970: 781_785_000 + 978_307_200))
    }

    func testOptionalKeysMayBeLeftOutAndAWholePercentStaysWhole() throws {
        let s = try JSONDecoder().decode(State.self, from: Data(#"{ "phase": "finished", "progress": 100 }"#.utf8))
        XCTAssertEqual(s.phase, .finished); XCTAssertEqual(s.progress, 100)
        XCTAssertNil(s.job); XCTAssertNil(s.startedAt); XCTAssertNil(s.endsAt)
    }

    func testWhatTheAppEncodesItReadsBack() throws {
        let s = State(phase: .paused, job: "a.gcode", progress: 7,
                      startedAt: Date(timeIntervalSinceReferenceDate: 100), endsAt: nil)
        XCTAssertEqual(try JSONDecoder().decode(State.self, from: JSONEncoder().encode(s)), s)
    }

    func testAnUpdateTokenCarriesItsMachineAndAStartTokenDoesNot() {
        let update = KhaytAPIClient.liveActivityTokenBody(kind: .update, hex: "ab01", machineId: "M1",
                                                          bundleId: "com.khaytapp.companion", env: "sandbox")
        XCTAssertEqual(update, ["kind": "update", "token": "ab01", "machineId": "M1",
                                "bundleId": "com.khaytapp.companion", "env": "sandbox"])
        let start = KhaytAPIClient.liveActivityTokenBody(kind: .start, hex: "ab01", machineId: "M1",
                                                         bundleId: "com.khaytapp.companion", env: "production")
        XCTAssertNil(start["machineId"])
        XCTAssertEqual(start["kind"], "start")
    }

    func testTokensAreLowercaseHex() {
        XCTAssertEqual(LiveActivityPush.hex(Data([0x00, 0xAB, 0x0F, 0xFF])), "00ab0fff")
    }
}
