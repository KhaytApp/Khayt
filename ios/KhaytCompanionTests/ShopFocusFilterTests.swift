import XCTest
@testable import KhaytCompanion

/// The Focus filter lets through exactly the kinds of news it names — tested on
/// the predicate the system evaluates against each notification's criteria.
final class ShopFocusFilterTests: XCTestCase {
    func testOnlyTheChosenKindsGetThrough() {
        let p = ShopFocusFilter.predicate(allowed: [NotificationKind.print])
        XCTAssertTrue(p.evaluate(with: NotificationKind.print))
        XCTAssertFalse(p.evaluate(with: NotificationKind.intake))
        XCTAssertFalse(p.evaluate(with: NotificationKind.shop))
    }

    func testEveryPushKindIsLabelled() {
        XCTAssertEqual(NotificationKind.of(["k": ["kind": "print-finished"]]), NotificationKind.print)
        XCTAssertEqual(NotificationKind.of(["k": ["kind": "intake"]]), NotificationKind.intake)
        XCTAssertEqual(NotificationKind.of([:]), NotificationKind.shop)
    }

    func testThePrintAlertIsLabelledWhereverItIsBuilt() {
        let event = PrintFinished(at: "2026-10-09T10:00:00Z", machineId: "M", machineName: "X1C", orderId: nil, project: nil,
                                  client: nil, filename: nil, durationS: 60, outcome: .failed)
        XCTAssertEqual(PrintAlertText.content(for: event, orderStatus: nil) { $0 }.filterCriteria, NotificationKind.print)
    }
}
