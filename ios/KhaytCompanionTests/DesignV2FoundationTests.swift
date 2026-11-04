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

    /// The widget extension carries its own copies of the faces it draws in
    /// (a widget cannot use the app's registered fonts). Its UIAppFonts must
    /// name files that are there, and those files must be the faces
    /// `PrintActivityLook` asks for by name, or the Lock Screen falls back
    /// to the system font without a word.
    func testTheWidgetBundlesTheFacesItAsksFor() throws {
        let widget = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // KhaytCompanionTests
            .deletingLastPathComponent()      // ios
            .appendingPathComponent("KhaytWidget")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: widget.appendingPathComponent("Info.plist")))
        let files = try XCTUnwrap(plist["UIAppFonts"] as? [String])
        var names: Set<String> = []
        for file in files {
            let data = try Data(contentsOf: widget.appendingPathComponent("Fonts").appendingPathComponent(file))
            let font = try XCTUnwrap(CGDataProvider(data: data as CFData).flatMap(CGFont.init), file)
            names.insert(try XCTUnwrap(font.postScriptName as String?, file))
        }
        XCTAssertEqual(names, Set(PrintActivityLook.faces))
        // And the app registers every one of them too: the app compiles these
        // views for its own tests and previews.
        for name in PrintActivityLook.faces {
            XCTAssertNotNil(UIFont(name: name, size: 12), name)
        }
    }
}
