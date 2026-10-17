import XCTest
import SwiftUI
@testable import KhaytCompanion

/// iPhone Duo partly folded like a book: two columns meet at the fold instead
/// of straddling it. Flat, or folded across the screen, they split evenly.
final class FoldColumnsTests: XCTestCase {
    private let size = CGSize(width: 600, height: 900)

    func testAFoldDownTheMiddleSplitsTheColumnsAtIt() {
        let fold = FoldGap.find([CGRect(x: 280, y: 0, width: 40, height: 900)], in: size)
        XCTAssertEqual(fold, FoldGap(lead: 280, gap: 40, trail: 280))
    }

    func testAFoldOffCentreKeepsEachSideItsOwnWidth() {
        // The view sits beside a sidebar, so the fold is not in its middle.
        let fold = FoldGap.find([CGRect(x: 180, y: 0, width: 40, height: 900)], in: size)
        XCTAssertEqual(fold, FoldGap(lead: 180, gap: 40, trail: 380))
    }

    func testAFoldAcrossTheScreenMovesNothing() {
        // Propped on a table: scrolling content does not displace.
        XCTAssertNil(FoldGap.find([CGRect(x: 0, y: 430, width: 600, height: 40)], in: size))
    }

    func testAFoldOutsideTheViewMovesNothing() {
        XCTAssertNil(FoldGap.find([CGRect(x: 620, y: 0, width: 40, height: 900)], in: size))
        XCTAssertNil(FoldGap.find([CGRect(x: 0, y: 0, width: 40, height: 900)], in: size))
        XCTAssertNil(FoldGap.find([], in: size))
    }

    func testAThinFoldTakesTheUsualGapCentredOnIt() {
        let f = FoldGap(lead: 298, gap: 4, trail: 298).widened(to: 10)
        XCTAssertEqual(f, FoldGap(lead: 295, gap: 10, trail: 295))
        XCTAssertEqual(f.lead + f.gap + f.trail, 600)
    }

    func testGridColumns() {
        XCTAssertEqual(FoldGap.columns(nil, regularWidth: false, spacing: 10).count, 1)
        XCTAssertEqual(FoldGap.columns(nil, regularWidth: true, spacing: 10).count, 2, "two across, flat")
        let fold = FoldGap(lead: 180, gap: 40, trail: 380)
        let cols = FoldGap.columns(fold, regularWidth: true, spacing: 10)
        XCTAssertEqual(cols.count, 2)
        guard case .fixed(let a) = cols[0].size, case .fixed(let b) = cols[1].size else {
            return XCTFail("columns at the fold are fixed widths")
        }
        XCTAssertEqual(a, 180); XCTAssertEqual(b, 380); XCTAssertEqual(cols[0].spacing, 40)
        XCTAssertEqual(FoldGap.columns(fold, regularWidth: false, spacing: 10).count, 1,
                       "the folded outer display is compact: one column")
    }
}
