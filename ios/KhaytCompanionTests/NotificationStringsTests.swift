import XCTest
@testable import KhaytCompanion

/// The notification service extension carries its own copy of the alert's
/// words (`KhaytAlerts/*.lproj`), because it cannot read the app's. The two
/// copies must say the same thing, or a push and an in-app alert about the
/// same print would disagree.
final class NotificationStringsTests: XCTestCase {
    private func table(_ path: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: path)
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], path)
    }

    func testTheExtensionSaysWhatTheAppSays() throws {
        for lang in ["en", "ar"] {
            let app = try table("KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let ext = try table("KhaytAlerts/\(lang).lproj/Localizable.strings")
            for key in PrintAlertText.keys {
                XCTAssertNotNil(ext[key], "\(lang): \(key) missing from the extension")
                XCTAssertEqual(ext[key], app[key], "\(lang): \(key)")
            }
        }
    }
}

/// The extension leaves a push it does not open exactly as Apple delivered it.
final class NotificationPassThroughTests: XCTestCase {
    func testTheExtensionOnlyReadsPrintFinished() {
        // `intake` has no `k.ct`; nothing here may try to open or fetch it.
        let src = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "KhaytAlerts/NotificationService.swift"), encoding: .utf8)
        XCTAssertTrue(src?.contains(#"kind == "print-finished""#) ?? false)
    }
}
