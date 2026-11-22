import XCTest
import SwiftUI
@testable import KhaytCompanion

final class ListBesidePageTests: XCTestCase {
    func testFlatTheListTakesAboutTwoFifthsWithinBounds() {
        // iPhone Duo unfolded (~669 pt) and the iPad mini (744 pt) in portrait.
        XCTAssertEqual(ListBesidePage<EmptyView, EmptyView>.split(total: 669, fold: nil).list, 300)
        XCTAssertEqual(ListBesidePage<EmptyView, EmptyView>.split(total: 744, fold: nil).list, 744 * 0.42, accuracy: 0.01)
        XCTAssertEqual(ListBesidePage<EmptyView, EmptyView>.split(total: 1200, fold: nil).list, 400)
        XCTAssertEqual(ListBesidePage<EmptyView, EmptyView>.split(total: 669, fold: nil).divide, 1)
    }

    func testPartlyFoldedTheDivideIsTheFold() {
        let fold = FoldGap(lead: 314, gap: 40, trail: 315)
        let s = ListBesidePage<EmptyView, EmptyView>.split(total: 669, fold: fold)
        XCTAssertEqual(s.list, 314)
        XCTAssertEqual(s.divide, 40)
    }

    func testAFoldThatLeavesNoRoomOnOneSideIsIgnored() {
        let fold = FoldGap(lead: 120, gap: 40, trail: 509)
        XCTAssertEqual(ListBesidePage<EmptyView, EmptyView>.split(total: 669, fold: fold).list, 300)
    }
}
