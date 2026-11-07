import XCTest
@testable import KhaytCompanion

/// What the phone will and will not do with the PIN, and which machines it
/// offers for new work.
@MainActor
final class LanHardeningTests: XCTestCase {

    // MARK: - The Mac's name answering somewhere new

    func testANewAddressIsOfferedNotFollowed() {
        let health = ConnectionHealth(api: KhaytAPIClient(settings: ConnectionSettings()))
        let there = MacAddress(host: "192.168.68.90", port: 3141)
        health.offerMove(to: there)
        XCTAssertEqual(health.macMoved, there, "the person is asked")
    }

    func testAnAddressTurnedDownIsNotOfferedAgain() {
        let health = ConnectionHealth(api: KhaytAPIClient(settings: ConnectionSettings()))
        let there = MacAddress(host: "192.168.68.90", port: 3141)
        health.offerMove(to: there)
        health.declineMove()
        XCTAssertNil(health.macMoved)
        health.offerMove(to: there)
        XCTAssertNil(health.macMoved, "the strip would ask again every minute")
        let elsewhere = MacAddress(host: "192.168.68.91", port: 3141)
        health.offerMove(to: elsewhere)
        XCTAssertEqual(health.macMoved, elsewhere, "a different address is a different question")
    }

    /// Moving to an address that could not prove it holds the Mac's key
    /// sends no stored PIN there: the person is asked to pair again.
    func testAcceptingAMoveAsksForThePinRatherThanSendingAStoredOne() async {
        let s = ConnectionSettings()
        let saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.needsPairAgain)
        defer { (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.needsPairAgain) = saved }
        s.host = "khayt-refuse.invalid"; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        let health = ConnectionHealth(api: KhaytAPIClient(settings: s, withBook: false), settings: s)
        health.offerMove(to: MacAddress(host: "khayt-moved.invalid", port: 3219))
        await health.acceptMove()
        XCTAssertEqual(s.host, "khayt-moved.invalid")
        XCTAssertEqual(s.pin, "", "no stored PIN goes to an address on trust")
        XCTAssertEqual(ConnectionSettings().pin, "", "nor stays in the Keychain to be sent later")
        XCTAssertTrue(s.needsPairAgain, "the person types it: Pair again")
    }

    // MARK: - Redirects

    func testARedirectIsNeverFollowed() async throws {
        let from = try XCTUnwrap(URL(string: "http://192.168.68.75:3141/api/store"))
        let to = try XCTUnwrap(URL(string: "http://203.0.113.9/collect"))
        let response = try XCTUnwrap(HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil,
                                                     headerFields: ["Location": to.absoluteString]))
        var next = URLRequest(url: to)
        next.setValue("12345678", forHTTPHeaderField: "x-khayt-pin")
        let followed = await NoRedirects().urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: from),
                                                      willPerformHTTPRedirection: response, newRequest: next)
        XCTAssertNil(followed, "the PIN would go to whatever host the Location names")
    }

    // MARK: - Retired and offline machines

    private func machine(_ json: String) throws -> MachineInfo {
        try JSONDecoder().decode(MachineInfo.self, from: Data(json.utf8))
    }

    func testARetiredMachineIsNotOfferedForWork() throws {
        let byStatus = try machine(#"{"id":"m1","name":"Old Ender","status":"retired"}"#)
        XCTAssertTrue(byStatus.isRetired)
        XCTAssertFalse(byStatus.isAssignable)
        let byDate = try machine(#"{"id":"m1","status":"idle","retiredAt":"2026-10-18T09:00:00.000Z"}"#)
        XCTAssertTrue(byDate.isRetired)
        XCTAssertTrue(try machine(#"{"id":"m1","status":"Retired"}"#).isRetired)
    }

    func testAnOfflineMachineIsKeptButNotOfferedForWork() throws {
        let m = try machine(#"{"id":"m2","status":"idle","isOffline":true}"#)
        XCTAssertFalse(m.isRetired, "offline is a pause; the Machines screen still shows it")
        XCTAssertFalse(m.isAssignable)
    }

    func testAnOrdinaryMachineIsOfferedForWork() throws {
        let m = try machine(#"{"id":"m3","status":"printing","isOffline":false}"#)
        XCTAssertTrue(m.isAssignable)
        XCTAssertTrue(try machine(#"{"id":"m4"}"#).isAssignable)
    }

    func testAnOddlyTypedFlagDoesNotLoseTheMachine() throws {
        let m = try machine(#"{"id":"m5","name":"Saturn","isOffline":"yes","retiredAt":0}"#)
        XCTAssertEqual(m.name, "Saturn")
        XCTAssertTrue(m.isAssignable)
    }

    func testMachineStateMatchesTheSharedRule() throws {
        let legacy = try machine(#"{"id":"m6","status":"offline"}"#)
        XCTAssertTrue(legacy.isUnderService, "an older book marks a paused printer by status")
        XCTAssertFalse(legacy.isAssignable)
        let blank = try machine(#"{"id":"m7","status":"idle","retiredAt":"  "}"#)
        XCTAssertFalse(blank.isRetired, "an empty retiredAt is not a retirement")
        XCTAssertTrue(blank.isAssignable)
        let both = try machine(#"{"id":"m8","status":"retired","retiredAt":"2026-10-18","isOffline":true}"#)
        XCTAssertTrue(both.isRetired)
        XCTAssertFalse(both.isUnderService, "retired says it all")
    }
}
