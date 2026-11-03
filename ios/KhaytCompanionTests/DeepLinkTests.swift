import XCTest
@testable import KhaytCompanion

/// `khayt://` means on the phone what it means on the Mac, and a Live
/// Activity's button offers the move its alert would.
final class DeepLinkTests: XCTestCase {
    private func link(_ s: String) -> OrdersNavigationState.Link? { OrdersNavigationState.link(URL(string: s)!) }

    func testTheMacsShapes() {
        XCTAssertEqual(link("khayt://job/KH-2026-1"), .job("KH-2026-1"))
        XCTAssertEqual(link("khayt://machine/M-1"), .tab(3))
        XCTAssertEqual(link("khayt://spool/S-1"), .tab(2))
        XCTAssertEqual(link("khayt://screen/jobs"), .orders(nil))
        XCTAssertEqual(link("khayt://screen/jobs:printing"), .orders(.printing))
        XCTAssertEqual(link("khayt://screen/customers"), .tab(4))
    }

    func testAnythingElseIsNothing() {
        XCTAssertNil(link("khayt://screen/reports"), "a screen the phone does not have")
        XCTAssertNil(link("khayt://delete/KH-1"))
        XCTAssertNil(link("https://khaytapp.com/job/1"))
        XCTAssertNil(link("khayt://job/"))
    }

    func testAnEndedPrintOffersItsAlertsMove() {
        XCTAssertEqual(PrintActivityText.move(.finished), "post")
        XCTAssertEqual(PrintActivityText.move(.failed), "reprint")
        XCTAssertEqual(PrintActivityText.move(.cancelled), "reprint")
        XCTAssertNil(PrintActivityText.move(.printing))
        XCTAssertNil(PrintActivityText.move(.paused))
    }
}
