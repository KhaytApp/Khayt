import XCTest
@testable import KhaytCompanion

/// A tapped alert opens what it is about — its job, the requests waiting,
/// the late jobs or the low shelf — instead of leaving the person on Home.
final class AlertTapTests: XCTestCase {
    typealias Nav = OrdersNavigationState

    func testAPrintAlertOpensItsJob() {
        XCTAssertEqual(Nav.destination(identifier: "print.M-1.2026", thread: "khayt.prints",
                                       userInfo: ["machineId": "M-1", "orderId": "KH-1"]), .order("KH-1"))
    }

    func testARequestAlertOpensTheRequestsHoweverItCame() {
        XCTAssertEqual(Nav.destination(identifier: "intake.2026", thread: "khayt.intake", userInfo: [:]), .intake)
        XCTAssertEqual(Nav.destination(identifier: "abc", thread: "",
                                       userInfo: ["k": ["kind": "intake"]]), .intake, "Apple's push")
    }

    func testLateAndLowStockOpenTheirLists() {
        XCTAssertEqual(Nav.destination(identifier: "khayt.overdue.123", thread: "", userInfo: [:]), .overdue)
        XCTAssertEqual(Nav.destination(identifier: "khayt.lowstock.123", thread: "", userInfo: [:]), .lowStock)
    }

    func testAnAlertAboutNothingOpenableOpensNothing() {
        XCTAssertNil(Nav.destination(identifier: "khayt.offline.1", thread: "", userInfo: [:]))
        XCTAssertNil(Nav.destination(identifier: "print.M-1.2026", thread: "khayt.prints",
                                     userInfo: ["machineId": "M-1"]), "an ending with no job on it")
    }

    @MainActor
    func testGoingThereAsksTheRightScreen() {
        let nav = Nav()
        nav.go(.order("KH-2"))
        XCTAssertEqual(nav.orderToOpen, "KH-2")
        nav.go(.intake)
        XCTAssertTrue(nav.intakeAsked)
        nav.go(.lowStock)
        XCTAssertTrue(nav.pendingLowStock)
        nav.go(.overdue)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "khayt.orders.filter"), "orders_overdue")
        UserDefaults.standard.removeObject(forKey: "khayt.orders.filter")
    }
}
