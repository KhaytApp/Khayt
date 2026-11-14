import UserNotifications
import XCTest
@testable import KhaytCompanion

/// Every way a tapped or arriving alert reaches the app ends by calling
/// UIKit's completion ON THE MAIN THREAD. Calling it anywhere else aborts the
/// app: TestFlight 202611131908 crashed when Turki tapped the Mac's test alert
/// (a print ending linked to no job), which returned early from an `async`
/// delegate method on a background thread (Nov 14).
///
/// Each test drives the real delegate method from a background thread, as
/// iOS may, and checks where the completion ran.
@MainActor
final class AlertTapThreadTests: XCTestCase {
    private var center: PrintAlertCenter!
    private var nav: OrdersNavigationState!
    private var api: KhaytAPIClient!
    private var savedDelegate: UNUserNotificationCenterDelegate?

    override func setUp() {
        // The app under test already holds the notification centre's
        // delegate; a test centre takes it, so it is given back.
        savedDelegate = UNUserNotificationCenter.current().delegate
        api = KhaytAPIClient(settings: ConnectionSettings(), withBook: false)
        center = PrintAlertCenter(api: api, settings: ConnectionSettings(), printers: LivePrinters { throw URLError(.notConnectedToInternet) })
        nav = OrdersNavigationState()
        center.navigation = nav
    }

    override func tearDown() {
        UNUserNotificationCenter.current().delegate = savedDelegate
        api.setCloudForTesting(nil)
    }

    // MARK: Building what iOS hands over

    /// A delivered notification and a response to it. Apple gives these no
    /// public initialisers; the class methods UIKit itself uses are called.
    private func notification(id: String = "n1", thread: String = "", info: [AnyHashable: Any],
                              trigger: UNNotificationTrigger? = nil) throws -> UNNotification {
        let content = UNMutableNotificationContent()
        content.userInfo = info
        content.threadIdentifier = thread
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        let sel = NSSelectorFromString("notificationWithRequest:date:")
        guard UNNotification.responds(to: sel),
              let made = (UNNotification.self as AnyObject).perform(sel, with: request, with: Date())?
                .takeUnretainedValue() as? UNNotification else {
            throw XCTSkip("this SDK cannot build a UNNotification in a test")
        }
        return made
    }

    private func response(_ n: UNNotification, action: String = UNNotificationDefaultActionIdentifier) throws -> UNNotificationResponse {
        let sel = NSSelectorFromString("responseWithNotification:actionIdentifier:")
        guard UNNotificationResponse.responds(to: sel),
              let made = (UNNotificationResponse.self as AnyObject).perform(sel, with: n, with: action)?
                .takeUnretainedValue() as? UNNotificationResponse else {
            throw XCTSkip("this SDK cannot build a UNNotificationResponse in a test")
        }
        return made
    }

    /// Tap, from a background thread; true when the completion ran on main.
    private func tap(_ r: UNNotificationResponse) async -> Bool {
        let done = expectation(description: "completion")
        nonisolated(unsafe) var onMain = false
        let c = center!
        nonisolated(unsafe) let resp = r
        DispatchQueue.global().async {
            c.userNotificationCenter(.current(), didReceive: resp) {
                onMain = Thread.isMainThread
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 10)
        return onMain
    }

    // MARK: The paths

    func testTheMacsTestAlertWithNoJobAndNoShop() async throws {
        // What the Mac's "Send a test alert" sends: a print ending, no job.
        let n = try notification(id: "print.test.2026", thread: "khayt.prints",
                                 info: ["machineId": "test", "outcome": "finished"])
        let onMain = await tap(try response(n))
        XCTAssertTrue(onMain)
        XCTAssertNil(nav.orderToOpen, "linked to no job: opens nothing")
    }

    func testAJobsAlertOpensItsJob() async throws {
        let n = try notification(id: "print.M-1.2026", thread: "khayt.prints",
                                 info: ["machineId": "M-1", "outcome": "finished", "orderId": "KH-7"])
        let onMain = await tap(try response(n))
        XCTAssertTrue(onMain)
        XCTAssertEqual(nav.orderToOpen, "KH-7")
    }

    func testAnotherShopsAlertIsRefused() async throws {
        api.setCloudForTesting(CloudSession(url: "https://cloud.test", shopId: "A", token: "t",
                                            dek: Data(count: 32), role: "owner", seenRev: nil))
        let n = try notification(info: ["machineId": "M-1", "outcome": "finished", "orderId": "KH-7", "shopId": "B"])
        let onMain = await tap(try response(n))
        XCTAssertTrue(onMain)
        XCTAssertNil(nav.orderToOpen, "another shop's job is not opened")
    }

    func testAnUnknownKindOpensNothing() async throws {
        let n = try notification(info: ["k": ["kind": "something-new", "at": "2026-11-14T04:30:00Z"]])
        let onMain = await tap(try response(n))
        XCTAssertTrue(onMain)
        XCTAssertNil(nav.orderToOpen)
    }

    func testAButtonOnAnAlertWithNoJob() async throws {
        let n = try notification(info: ["machineId": "test", "outcome": "finished"])
        let onMain = await tap(try response(n, action: PrintAlertAction.moveToPost.rawValue))
        XCTAssertTrue(onMain, "a button with no job to move")
    }

    func testAnAlertArrivingWithTheAppOpen() async throws {
        let n = try notification(info: ["k": ["kind": "payment"]], trigger: nil)
        let done = expectation(description: "willPresent")
        nonisolated(unsafe) var onMain = false
        nonisolated(unsafe) var shown: UNNotificationPresentationOptions = []
        let c = center!
        nonisolated(unsafe) let note = n
        DispatchQueue.global().async {
            c.userNotificationCenter(.current(), willPresent: note) { options in
                onMain = Thread.isMainThread
                shown = options
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertTrue(onMain)
        XCTAssertTrue(shown.contains(.banner))
    }

    /// No delegate method may come back in its `async` form: that form is
    /// what finished off the main thread.
    func testTheDelegateUsesOnlyTheCompletionHandlerForms() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "KhaytCompanion/Services/PrintAlerts.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("didReceive response: UNNotificationResponse) async"))
        XCTAssertFalse(src.contains("willPresent notification: UNNotification) async"))
    }
}
