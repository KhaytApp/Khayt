import XCTest
@testable import KhaytCompanion

/// The release review's LOWs on the app lock (Nov 26): loosening the lock asks
/// first (L1, security LOW-2), Hide job names redraws what is on the Lock
/// Screen (L2), the first launch of a new build re-indexes Spotlight and Siri
/// names no customer on a guess (L3), the curtain's own scene and key window
/// (L4, L5), one reply-MAC verifier (L6). Sample data; Face ID stood in for.
@MainActor
final class LockReviewLowsTests: XCTestCase {

    private final class Checker: DeviceOwnerChecking, @unchecked Sendable {
        var passcode = true
        var answers: [Bool] = []
        private(set) var asked: [Bool] = []
        func biometryName() -> String? { "Face ID" }
        func canCheck() -> Bool { passcode }
        func check(reason: String, biometricsOnly: Bool) async -> Bool {
            asked.append(biometricsOnly)
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "lock-lows-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    // MARK: L1 / security LOW-2

    func testTurningTheLockOffAsksFirst() async {
        let checker = Checker()
        let lock = AppLock(defaults: defaults, checker: checker)
        lock.choice = true
        let refused = await lock.turnOff()
        XCTAssertFalse(refused)
        XCTAssertEqual(lock.choice, true, "a failed check changes nothing")
        checker.answers = [true]
        let done = await lock.turnOff()
        XCTAssertTrue(done)
        XCTAssertEqual(lock.choice, false)
        XCTAssertEqual(checker.asked, [false, false], "the passcode is allowed")
        XCTAssertFalse(lock.checking)
    }

    func testOnlyALongerTimeAsks() async {
        let checker = Checker()
        let lock = AppLock(defaults: defaults, checker: checker)
        XCTAssertEqual(lock.after, .oneMinute)
        await lock.setAfter(.fifteenMinutes)
        XCTAssertEqual(lock.after, .oneMinute, "refused: kept")
        checker.answers = [true]
        await lock.setAfter(.fiveMinutes)
        XCTAssertEqual(lock.after, .fiveMinutes)
        await lock.setAfter(.immediately)
        XCTAssertEqual(lock.after, .immediately, "stricter: no check")
        XCTAssertEqual(checker.asked.count, 2)
    }

    func testAnIPhoneWithNoPasscodeHasNothingToAsk() async {
        let checker = Checker()
        checker.passcode = false
        let lock = AppLock(defaults: defaults, checker: checker)
        lock.choice = true
        let done = await lock.turnOff()
        XCTAssertTrue(done)
        XCTAssertEqual(checker.asked, [])
    }

    func testTheSecurityPageGoesThroughTheCheck() throws {
        let page = try source("KhaytCompanion/Views/SettingsSecurityPage.swift")
        XCTAssertTrue(page.contains("lock.turnOff()"))
        XCTAssertTrue(page.contains("lock.setAfter("))
        XCTAssertFalse(page.contains("turnedOffInSettings"), "never off without the check")
        XCTAssertFalse(page.contains("lock.after = "), "never longer without the check")
    }

    // MARK: L2

    func testHideJobNamesTellsTheLockScreenOnlyWhenItChanges() {
        var told = 0
        let before = LockScreenNames.changed
        LockScreenNames.changed = { told += 1 }
        defer { LockScreenNames.changed = before }
        let names = LockScreenNames(defaults: defaults)
        names.hidden = !names.hidden
        XCTAssertEqual(told, 1)
        names.hidden = names.hidden
        XCTAssertEqual(told, 1, "the same value: nothing to redraw")
    }

    func testTheAppRedrawsTheRunningLiveActivities() throws {
        let app = try source("KhaytCompanion/KhaytCompanionApp.swift")
        XCTAssertTrue(app.contains("LockScreenNames.changed = { Task { await printActivities.redraw() } }"))
        XCTAssertTrue(try source("KhaytCompanion/Services/PrintActivities.swift").contains("func redraw() async"))
    }

    // MARK: L3

    func testSiriNamesNoCustomerBeforeTheGateHasSaid() {
        let before = JobSearch.defaults
        JobSearch.defaults = defaults
        defer { JobSearch.defaults = before }
        XCTAssertTrue(JobSearch.hidesCustomers, "nothing known: hidden")
        defaults.set(false, forKey: JobSearch.lockChoiceKey)
        XCTAssertFalse(JobSearch.hidesCustomers, "the person turned the lock off")
        defaults.set(true, forKey: JobSearch.lockKey)
        XCTAssertTrue(JobSearch.hidesCustomers, "the gate's word wins")
        XCTAssertEqual(AppLock(defaults: defaults, checker: Checker()).choice, false, "the same key AppLock keeps")
    }

    func testANewBuildReindexesOnceAtLaunch() async {
        let before = JobSearch.defaults
        JobSearch.defaults = defaults
        defer { JobSearch.defaults = before }
        let spotlight = FakeIndex()
        await JobSearch.reindexIfUpdated(build: "202612030900", into: spotlight)
        XCTAssertEqual(spotlight.calls.first, "delete", "what the older build indexed goes")
        let after = spotlight.calls.count
        await JobSearch.reindexIfUpdated(build: "202612030900", into: spotlight)
        XCTAssertEqual(spotlight.calls.count, after, "the same build: nothing")
        await JobSearch.reindexIfUpdated(build: "202612100900", into: spotlight)
        XCTAssertGreaterThan(spotlight.calls.count, after, "the next build: again")
        XCTAssertTrue(try source("KhaytCompanion/KhaytCompanionApp.swift").contains("JobSearch.reindexIfUpdated()"))
    }

    // MARK: L4, L5 (a window needs a running app: source guards)

    func testTheCurtainUsesItsOwnSceneAndGivesTheKeyBack() throws {
        let view = try source("KhaytCompanion/Views/AppLockView.swift")
        XCTAssertTrue(view.contains("guard let scene = ownScene ??"), "the gate's own scene first")
        XCTAssertTrue(view.contains("locked: lock.locked, in: scene)"))
        XCTAssertTrue(view.contains(".background(SceneFinder { scene = $0 })"))
        XCTAssertTrue(view.contains("keyBefore ?? shown.windowScene?.windows.first"), "a key window even when none was kept")
    }

    // MARK: L6

    func testOneReplyMacVerifier() throws {
        XCTAssertFalse(try source("KhaytCompanion/Services/DeviceKey.swift").contains("func replyVerifies"))
        XCTAssertFalse(try source("KhaytCompanion/Services/KhaytAPIClient.swift").contains("replyVerifies("))
    }
}
