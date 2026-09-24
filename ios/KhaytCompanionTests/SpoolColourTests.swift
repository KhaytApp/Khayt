import XCTest
import SwiftUI
@testable import KhaytCompanion

/// A colour picked on the phone is stored as `#RRGGBB` and read back into the
/// swatch the shelf shows. Each preset must come back exactly as it went in,
/// or the picked swatch is never shown as picked.
final class SpoolColourTests: XCTestCase {
    func testEveryPresetSurvivesTheRoundTrip() throws {
        for c in SpoolReviewForm.colours {
            let colour = try XCTUnwrap(Color(hex: c.hex), c.key)
            XCTAssertEqual(colour.hexString, c.hex, c.key)
        }
    }

    func testAPickedColourIsWrittenTheWayTheShelfStoresIt() {
        let hex = Color(red: 1, green: 0.5, blue: 0).hexString
        XCTAssertTrue(hex.range(of: #"^#[0-9A-F]{6}$"#, options: .regularExpression) != nil, hex)
    }

    func testEveryPresetHasANameInBothLanguages() {
        // VoiceOver reads the name; a swatch is otherwise silent.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Resources")
        for lang in ["en", "ar"] {
            let table = NSDictionary(contentsOf: dir.appending(path: "\(lang).lproj/Localizable.strings")) as? [String: String] ?? [:]
            for c in SpoolReviewForm.colours {
                XCTAssertNotNil(table["colour.\(c.key)"], "\(lang): colour.\(c.key)")
            }
        }
    }
}
