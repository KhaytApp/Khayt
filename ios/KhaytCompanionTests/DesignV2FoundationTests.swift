import XCTest
import SwiftUI
@testable import KhaytCompanion

/// The design's foundation (`design/ios-v2/`) is in the app, not only in the doc.
final class DesignV2FoundationTests: XCTestCase {

    func testTheWebsiteFacesAreBundledAndRegistered() {
        // UIAppFonts names the files; a missing or misnamed one fails silently
        // at runtime, falling back to the system face everywhere.
        for name in KhaytType.allNames {
            XCTAssertNotNil(UIFont(name: name, size: 17), name)
        }
        XCTAssertEqual(KhaytType.allNames.count, 8)
    }

    func testBigSizesDrawInTheDisplayFace() {
        XCTAssertEqual(KhaytType.displayName(.bold), "Archivo-ExtraBold")
        XCTAssertEqual(KhaytType.postScriptName(.medium), "HankenGrotesk-Medium")
        XCTAssertEqual(KhaytType.monoName(.regular), "JetBrainsMono-Regular")
    }

    private func hex(_ c: Color, _ style: UIUserInterfaceStyle) -> String {
        let ui = UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func testThePaletteIsTheRedesignsAndTheMacs() {
        // The same numbers as the Mac's Palette.swift / Surface.swift (#2183).
        XCTAssertEqual(hex(KhaytDesign.ground, .dark), "06182F")
        XCTAssertEqual(hex(KhaytDesign.ground, .light), "F6F8F8")
        XCTAssertEqual(hex(KhaytDesign.brand, .dark), "4C97F0")
        XCTAssertEqual(hex(KhaytDesign.brand, .light), "216DCA")
        XCTAssertEqual(hex(KhaytDesign.surface, .dark), "0D2444")
        XCTAssertEqual(hex(KhaytDesign.surface, .light), "FFFFFF")
        XCTAssertEqual(hex(KhaytDesign.text, .dark), "EAF2FB")
        XCTAssertEqual(hex(KhaytDesign.thread, .light), "F2A541")
    }

    func testStagesTakeTheMacsTodayColours() {
        // Printing live green, QC and hold violet, done done, pending and post quiet.
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "printing"), .dark), "34D27A")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "qc"), .dark), "B49CFF")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "on_hold"), .dark), "B49CFF")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "completed"), .dark), "4FBFA0")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "pending"), .dark), "8AA4C2")
        XCTAssertEqual(hex(KhaytDesign.statusColor(for: "post"), .dark), "8AA4C2")
        // Rails stay rare: only printing and QC.
        XCTAssertEqual(["pending", "printing", "post", "qc", "completed"].filter(KhaytDesign.isRailed), ["printing", "qc"])
    }

    func testInitialsTakeTwoLettersInTheNamesOwnScript() {
        XCTAssertEqual(Initials.of("Noura Al-Saud"), "NA")
        XCTAssertEqual(Initials.of("Acme"), "A")
        XCTAssertEqual(Initials.of("  (Studio) Rawa "), "SR")
        XCTAssertEqual(Initials.of("نورة السعود"), "نا")
        XCTAssertEqual(Initials.of(""), "?")
    }
}
