import XCTest
import SwiftUI
@testable import KhaytCompanion

/// The design's foundation (`design/ios-v2/`) is in the app, not only in the doc.
final class DesignV2FoundationTests: XCTestCase {

    func testSpaceGroteskIsBundledAndRegistered() {
        // UIAppFonts names the files; a missing or misnamed one fails silently
        // at runtime, falling back to the system face everywhere.
        for w in [Font.Weight.regular, .medium, .semibold, .bold] {
            XCTAssertNotNil(UIFont(name: KhaytType.postScriptName(w), size: 17), KhaytType.postScriptName(w))
        }
    }

    private func hex(_ c: Color, _ style: UIUserInterfaceStyle) -> String {
        let ui = UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func testThePaletteIsTheDesignsDarkAndLight() {
        // The prototype's own DARK / LIGHT.
        XCTAssertEqual(hex(KhaytDesign.ground, .dark), "16130F")
        XCTAssertEqual(hex(KhaytDesign.ground, .light), "EFEBE3")
        XCTAssertEqual(hex(KhaytDesign.brand, .dark), "4591ED")
        XCTAssertEqual(hex(KhaytDesign.brand, .light), "0B54AD")
        XCTAssertEqual(hex(KhaytDesign.surface, .dark), "201C17")
        XCTAssertEqual(hex(KhaytDesign.text, .dark), "F2EDE4")
    }

    func testStagesTakeTheDesignsTone() {
        // TONE: printing hot, QC attention, done done, pending and post quiet.
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "printing"), .dark), "F0763D")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "qc"), .dark), "E0A73C")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "completed"), .dark), "4FBFA0")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "pending"), .dark), "9EA7B3")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "post"), .dark), "9EA7B3")
        // RAILED: only printing and QC.
        XCTAssertEqual(["pending", "printing", "post", "qc", "completed"].filter(KhaytDesign.isRailed), ["printing", "qc"])
    }
}
