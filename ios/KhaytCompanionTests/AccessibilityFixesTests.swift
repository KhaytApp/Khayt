import XCTest
@testable import KhaytCompanion

/**
 * UI review Nov 11, F6–F9: things VoiceOver and a thumb could not do.
 *
 * - F6: Settings opened from Home is a sheet; it has a Close button.
 * - F7: every text field and date picker carries its caption as its
 *   accessibility label, not "" (19 fields read as "0" or as nothing).
 * - F8: small controls take a 44 pt tap (`tapTarget()`).
 * - F9: the banner's buttons write in `onBrand` on amber and red, not white
 *   (white on dark-mode amber was 2.15:1).
 */
final class AccessibilityFixesTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("KhaytCompanion/Views/\(name).swift"), encoding: .utf8)
    }

    private var views: [URL] {
        get throws {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("KhaytCompanion/Views")
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
        }
    }

    func testNoFieldIsUnlabelled() throws {
        for file in try views {
            let s = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(s.contains("TextField(\"\""), "\(file.lastPathComponent): a TextField with no label")
            XCTAssertFalse(s.contains("DatePicker(\"\""), "\(file.lastPathComponent): a DatePicker with no label")
        }
    }

    func testSettingsAsASheetCanBeClosed() throws {
        XCTAssertTrue(try source("DashboardView").contains("SettingsView(showsClose: true)"))
        XCTAssertTrue(try source("SettingsView").contains("if showsClose"))
    }

    func testTheBannerNeverWritesWhiteOnAmber() throws {
        let s = try source("ConnectionBanner")
        XCTAssertFalse(s.contains("Color.white"), "white on dark-mode amber reads at 2:1")
        XCTAssertGreaterThanOrEqual(s.components(separatedBy: ".tapTarget()").count - 1, 4)
    }

    func testTheSmallControlsTake44Points() throws {
        for (name, count) in [("CalculatorView", 2), ("KhaytListStyle", 1), ("InventoryView", 1), ("NewOrderSheet", 1),
                              ("ConnectorsViews", 1), ("PortalCard", 1), ("AddSpoolSheet", 1), ("PrinterCareViews", 1)] {
            XCTAssertGreaterThanOrEqual(try source(name).components(separatedBy: ".tapTarget()").count - 1, count, name)
        }
        XCTAssertFalse(try source("SettingsView").contains("minHeight: 32"))
        XCTAssertFalse(try source("MachinesView").contains("minHeight: 40"))
    }
}
