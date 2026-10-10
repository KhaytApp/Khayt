import XCTest
@testable import KhaytCompanion

/// "Quote this file": the types the app accepts, and a sentence for every
/// refusal the Mac's estimate route gives (`LanServer.estimate`).
final class QuoteFileTests: XCTestCase {
    func testEveryModelTypeTheMacReadsIsAccepted() {
        XCTAssertEqual(QuoteFileSheet.types.count, 4, "STL, OBJ, the Mac's 3MF type and G-code, all resolvable")
        XCTAssertEqual(KhaytAPIClient.modelExtensions, ["stl", "obj", "3mf", "gcode", "gco"],
                       "the Mac's readableUploads")
    }

    func testEveryRefusalHasItsOwnSentence() {
        for r in ["off", "unsupported", "too-large", "no-numbers", "no-price", "busy"] {
            XCTAssertEqual(QuoteFileSheet.reason(r), L10n.tr("quote.file.reason.\(r)"))
            XCTAssertNotEqual(L10n.tr("quote.file.reason.\(r)"), "quote.file.reason.\(r)", "\(r) has no words")
        }
        XCTAssertEqual(QuoteFileSheet.reason("something-new"), L10n.tr("quote.file.reason.no-price"))
    }
}
