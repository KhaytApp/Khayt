import XCTest
import UserNotifications
@testable import KhaytCompanion

/// The lock when Khayt opens, and "Hide job names on the lock screen" (Turki,
/// Nov 22; signed frames 265:2). Sample data only; Face ID is stood in for.
@MainActor
final class AppLockTests: XCTestCase {

    private final class Checker: DeviceOwnerChecking, @unchecked Sendable {
        var biometry: String? = "Face ID"
        var passcode = true
        var answers: [Bool] = []
        private(set) var asked: [Bool] = []
        func biometryName() -> String? { biometry }
        func canCheck() -> Bool { passcode }
        func check(reason: String, biometricsOnly: Bool) async -> Bool {
            asked.append(biometricsOnly)
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "app-lock-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    // MARK: - On by default where there is a book

    func testOnByDefaultForOwnerAndManagerPhonesOnly() {
        XCTAssertTrue(AppLockRule.onByDefault(hasShop: true, sampleShop: false, holdsBook: true), "owner or manager")
        XCTAssertFalse(AppLockRule.onByDefault(hasShop: true, sampleShop: false, holdsBook: false), "a floor phone keeps no book")
        XCTAssertFalse(AppLockRule.onByDefault(hasShop: true, sampleShop: true, holdsBook: true), "the sample shop is made up")
        XCTAssertFalse(AppLockRule.onByDefault(hasShop: false, sampleShop: false, holdsBook: true), "not paired: nothing to lock")
        // The roles, through the same rule the app asks.
        for (role, held) in [("owner", true), ("manager", true), ("operator", false), ("viewer", false)] {
            XCTAssertEqual(AppLockRule.onByDefault(hasShop: true, sampleShop: false, holdsBook: DeviceRole.mayHoldBook(role)), held, role)
        }
    }

    func testThePersonsOwnChoiceWins() {
        XCTAssertFalse(AppLockRule.enabled(choice: false, hasShop: true, sampleShop: false, holdsBook: true), "an owner turned it off")
        XCTAssertTrue(AppLockRule.enabled(choice: true, hasShop: true, sampleShop: false, holdsBook: false))
        XCTAssertTrue(AppLockRule.enabled(choice: nil, hasShop: true, sampleShop: false, holdsBook: true))
    }

    // MARK: - After 1 minute in the background

    func testOneMinuteIsTheDefaultAndTheFourChoices() {
        XCTAssertEqual(AppLockRule.After.standard, .oneMinute)
        XCTAssertEqual(AppLockRule.After.allCases.map(\.rawValue), [0, 60, 300, 900])
        XCTAssertEqual(AppLock(defaults: defaults, checker: Checker()).after, .oneMinute)
    }

    func testItLocksOnlyAfterTheChosenTimeAway() {
        let left = Date(timeIntervalSince1970: 1_795_000_000)
        func locks(_ after: AppLockRule.After, _ seconds: TimeInterval, enabled: Bool = true) -> Bool {
            AppLockRule.locksOnReturn(enabled: enabled, after: after, leftAt: left, now: left.addingTimeInterval(seconds))
        }
        XCTAssertFalse(locks(.oneMinute, 59))
        XCTAssertTrue(locks(.oneMinute, 60))
        XCTAssertTrue(locks(.immediately, 0), "immediately: every return")
        XCTAssertFalse(locks(.fiveMinutes, 299))
        XCTAssertTrue(locks(.fifteenMinutes, 900))
        XCTAssertFalse(locks(.oneMinute, 3600, enabled: false), "the lock is off")
        XCTAssertTrue(locks(.fifteenMinutes, -5), "the clock went back while away: the time cannot be told")
        XCTAssertFalse(AppLockRule.locksOnReturn(enabled: true, after: .immediately, leftAt: nil, now: left), "never left the front")
    }

    // MARK: - The running lock

    func testKhaytStartsLockedAndFaceIDOpensIt() async {
        let checker = Checker()
        checker.answers = [true]
        let lock = AppLock(defaults: defaults, checker: checker)
        lock.start(enabled: true)
        XCTAssertTrue(lock.locked)
        await lock.unlock(biometricsOnly: true)
        XCTAssertFalse(lock.locked)
        XCTAssertFalse(lock.failed)
        XCTAssertEqual(checker.asked, [true])
        lock.start(enabled: true)
        XCTAssertFalse(lock.locked, "starting is once per launch")
    }

    func testAFailedFaceIDStaysLockedAndThePasscodeOpensIt() async {
        let checker = Checker()
        checker.answers = [false, true]
        let lock = AppLock(defaults: defaults, checker: checker)
        lock.start(enabled: true)
        await lock.unlock(biometricsOnly: true)
        XCTAssertTrue(lock.locked)
        XCTAssertTrue(lock.failed, "frame L2")
        await lock.unlock(biometricsOnly: false)
        XCTAssertFalse(lock.locked)
        XCTAssertFalse(lock.failed)
        XCTAssertEqual(checker.asked, [true, false], "Face ID alone, then with the iPhone's passcode")
    }

    func testAwayForAMinuteLocksAndAShortTripDoesNot() async {
        let checker = Checker()
        checker.answers = [true]
        let lock = AppLock(defaults: defaults, checker: checker)
        lock.start(enabled: true)
        await lock.unlock(biometricsOnly: true)
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        lock.wentToBackground(now: t)
        lock.wentToBackground(now: t.addingTimeInterval(30))  // told twice: the first one counts
        lock.cameBack(enabled: true, now: t.addingTimeInterval(45))
        XCTAssertFalse(lock.locked, "45 s away")
        lock.wentToBackground(now: t.addingTimeInterval(100))
        lock.cameBack(enabled: true, now: t.addingTimeInterval(161))
        XCTAssertTrue(lock.locked, "61 s away")
    }

    func testOffNeverLocksAndTurningItOffOpensIt() {
        let lock = AppLock(defaults: defaults, checker: Checker())
        lock.start(enabled: false)
        XCTAssertFalse(lock.locked)
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        lock.wentToBackground(now: t)
        lock.cameBack(enabled: false, now: t.addingTimeInterval(3600))
        XCTAssertFalse(lock.locked)
        let on = AppLock(defaults: defaults, checker: Checker())
        on.start(enabled: true)
        XCTAssertTrue(on.locked)
        on.turnedOffInSettings()
        XCTAssertFalse(on.locked)
        XCTAssertEqual(on.choice, false, "the person's own choice, kept")
    }

    /// The Face ID sheet, Control Centre and Notification Centre make the app
    /// inactive, never background. With "Immediately" that must not lock
    /// Khayt again the moment Face ID succeeds (review of #2691).
    func testTheFaceIDSheetItselfNeverLocksItAgain() async {
        let checker = Checker()
        checker.answers = [true, true]
        let lock = AppLock(defaults: defaults, checker: checker)
        lock.after = .immediately
        lock.start(enabled: true)
        await lock.unlock(biometricsOnly: true)
        // Back to active after the sheet: it never went to the background.
        lock.cameBack(enabled: true)
        XCTAssertFalse(lock.locked)
        // A real trip to the background still locks at once.
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        lock.wentToBackground(now: t)
        lock.cameBack(enabled: true, now: t)
        XCTAssertTrue(lock.locked)
        // Unlocking forgets the trip: the return that follows does not lock again.
        await lock.unlock(biometricsOnly: true)
        lock.cameBack(enabled: true, now: t.addingTimeInterval(5))
        XCTAssertFalse(lock.locked)
    }

    /// Only the switch in Settings (behind the lock) opens Khayt without a
    /// check. The app has no other way to clear `locked`.
    func testNothingButSettingsOrACheckOpensIt() async {
        let checker = Checker()
        let lock = AppLock(defaults: defaults, checker: checker)
        lock.start(enabled: true)
        lock.cameBack(enabled: false)            // the role dropped, or the sign-in went, while locked
        XCTAssertTrue(lock.locked)
        await lock.unlock(biometricsOnly: true)  // the check fails
        XCTAssertTrue(lock.locked)
        let source = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Views/AppLockView.swift"), encoding: .utf8)
        XCTAssertEqual(source?.contains("turnedOffInSettings"), false, "the gate never opens the lock by itself")
        XCTAssertEqual(source?.contains("windowLevel = .alert + 1"), true, "the lock is a window above sheets and alerts")
        XCTAssertEqual(source?.contains("accessibilityViewIsModal = true"), true)
    }

    /// An iPhone with no passcode has nothing to check with: Khayt does not
    /// lock, rather than lock with no way in.
    func testAnIPhoneWithNoPasscodeIsNotLocked() {
        let checker = Checker()
        checker.passcode = false
        checker.biometry = nil
        let lock = AppLock(defaults: defaults, checker: checker)
        lock.start(enabled: true)
        XCTAssertFalse(lock.locked)
        XCTAssertFalse(lock.canLock)
    }

    func testTheChoicesAreKept() {
        let lock = AppLock(defaults: defaults, checker: Checker())
        XCTAssertNil(lock.choice, "no choice yet: the default applies")
        lock.choice = false
        lock.after = .fiveMinutes
        let again = AppLock(defaults: defaults, checker: Checker())
        XCTAssertEqual(again.choice, false)
        XCTAssertEqual(again.after, .fiveMinutes)
        again.choice = nil
        XCTAssertNil(AppLock(defaults: defaults, checker: Checker()).choice)
    }

    // MARK: - Hide job names on the lock screen

    private func alert(hide: Bool, project: String? = "Ahmed's bracket", filename: String? = "Ahmed_bracket.gcode") throws -> UNMutableNotificationContent {
        var fields = [#""id":"e1""#, #""machineId":"M1""#, #""machineName":"Sample MK4""#, #""outcome":"finished""#,
                      #""at":"2026-11-24T09:00:00.000Z""#]
        if let project { fields.append(#""project":"\#(project)""#) }
        if let filename { fields.append(#""filename":"\#(filename)""#) }
        let event = try JSONDecoder().decode(PrintFinished.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
        return PrintAlertText.content(for: event, orderStatus: nil, hideJobNames: hide, tr: { $0 })
    }

    func testOffByDefaultAndTheAlertNamesTheJob() throws {
        XCTAssertFalse(LockScreenPrivacy.hidesJobNames(defaults))
        XCTAssertFalse(LockScreenNames(defaults: defaults).hidden)
        let body = try alert(hide: false).body
        XCTAssertTrue(body.hasPrefix("Ahmed's bracket"), body)
    }

    func testOnTheAlertSaysAPrintAndNeverTheTitleOrTheFileName() throws {
        for (project, filename) in [("Ahmed's bracket", "Ahmed_bracket.gcode"), (nil, "Ahmed_bracket.gcode"), (nil, nil)] as [(String?, String?)] {
            let body = try alert(hide: true, project: project, filename: filename).body
            XCTAssertTrue(body.hasPrefix("alert.print.a_print"), body)
            XCTAssertFalse(body.contains("Ahmed"), body)
            XCTAssertTrue(body.contains("Sample MK4"), "the printer's name stays")
        }
    }

    func testTheSwitchIsWrittenWhereTheExtensionsReadIt() {
        let names = LockScreenNames(defaults: defaults)
        names.hidden = true
        XCTAssertTrue(LockScreenPrivacy.hidesJobNames(defaults))
        XCTAssertTrue(defaults.bool(forKey: "khayt.hideJobNames"), "the key the widget reads")
        XCTAssertTrue(LockScreenNames(defaults: defaults).hidden)
        names.hidden = false
        XCTAssertFalse(LockScreenPrivacy.hidesJobNames(defaults))
        XCTAssertFalse(LockScreenPrivacy.hidesJobNames(nil), "no App Group: off")
    }

    /// The widget extension reads the same key and has the words.
    func testTheLiveActivityHasTheSwitchAndTheWords() throws {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let views = try String(contentsOf: ios.appending(path: "KhaytWidget/PrintActivityViews.swift"), encoding: .utf8)
        XCTAssertTrue(views.contains(#""khayt.hideJobNames""#))
        XCTAssertTrue(views.contains(#"Text("A print", bundle: bundle)"#))
        let island = try String(contentsOf: ios.appending(path: "KhaytWidget/PrintActivityWidget.swift"), encoding: .utf8)
        XCTAssertTrue(island.contains(#"PrintActivityText.hidesJobNames() ? Text("A print")"#), "the Dynamic Island's expanded line too")
        let intake = try String(contentsOf: ios.appending(path: "KhaytCompanion/Views/IntakeView.swift"), encoding: .utf8)
        XCTAssertTrue(intake.contains("LockScreenPrivacy.hidesJobNames() ? L10n.tr(\"intake.remind.alert.hidden\")"),
                      "a request reminder does not name the customer")
        XCTAssertEqual(LockScreenPrivacy.key, "khayt.hideJobNames")
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            for table in ["KhaytWidget/\(lang).lproj/Localizable.strings", "KhaytAlerts/\(lang).lproj/Localizable.strings",
                          "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings"] {
                let t = try XCTUnwrap(NSDictionary(contentsOf: ios.appending(path: table)) as? [String: String], table)
                let word = t["A print"] ?? t["alert.print.a_print"] ?? ""
                XCTAssertFalse(word.isEmpty, table)
            }
        }
    }

    // MARK: - Words and the Settings row

    func testTheLockWordsInEnglish() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertEqual(L10n.format("lock.toggle", "Face ID"), "Lock Khayt with Face ID")
        XCTAssertEqual(L10n.format("lock.unlock_with", "Face ID"), "Unlock with Face ID")
        XCTAssertEqual(L10n.format("lock.try_again", "Face ID"), "Try Face ID again")
        XCTAssertEqual(L10n.format("lock.failed", "Face ID"), "Face ID did not match. Try again, or use this iPhone's passcode.")
        XCTAssertEqual(L10n.tr("lock.use_passcode"), "Use passcode")
        XCTAssertEqual(L10n.tr("lock.locked"), "Locked. Your shop's book is on this phone.")
        XCTAssertEqual(AppLockRule.After.allCases.map { L10n.tr($0.labelKey) },
                       ["Immediately", "After 1 minute", "After 5 minutes", "After 15 minutes"])
        XCTAssertEqual(L10n.tr("lock.hide_names"), "Hide job names on the lock screen")
        XCTAssertEqual(SettingsRoute.security.group, .thisPhone)
        XCTAssertEqual(L10n.tr(SettingsRoute.security.titleKey), "Security")
        XCTAssertTrue(SettingsRoute.security.searchLabels().contains("Hide job names on the lock screen"))
    }

    func testFaceIDHasItsPermissionWords() throws {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: ios.appending(path: "KhaytCompanion/Resources/Info.plist")) as? [String: Any])
        XCTAssertFalse((plist["NSFaceIDUsageDescription"] as? String ?? "").isEmpty, "without it the app is killed at the first Face ID check")
    }
}
