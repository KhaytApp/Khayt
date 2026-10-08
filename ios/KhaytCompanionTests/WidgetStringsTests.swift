import XCTest

/// The Home Screen widget is its own process with its own bundle, so it carries
/// its own words (`KhaytWidget/*.lproj`). Until Oct 2026 it had none, and an
/// Arabic phone showed "Queue", "Offline" and "Open app on shop Wi‑Fi".
final class WidgetStringsTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ lang: String) throws -> [String: String] {
        let url = root.appending(path: "KhaytWidget/\(lang).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(lang) widget table")
    }

    func testEnglishAndArabicHoldTheSameKeys() throws {
        XCTAssertEqual(Set(try table("en").keys), Set(try table("ar").keys))
    }

    /// Every plain `Text("…")` and `metric("…", …)` literal in the widget is a key.
    /// Interpolated ones are listed in the table by hand in their `%lld` form.
    func testEveryLiteralTheWidgetShowsIsTranslated() throws {
        let source = try String(contentsOf: root.appending(path: "KhaytWidget/KhaytQueueWidget.swift"), encoding: .utf8)
        let ar = try table("ar")
        let pattern = #"(?:Text|metric)\("([^"\\]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let found = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        let shown = Set(found).subtracting(["Khayt"])   // the product's name, not a word
        XCTAssertFalse(shown.isEmpty, "the pattern still finds the widget's words")
        XCTAssertEqual(shown.filter { ar[$0] == nil }.sorted(), [], "shown by the widget, missing from ar.lproj")
        XCTAssertNotNil(ar["LAN connected"])
        XCTAssertNotNil(ar["%lld queued · %lld printing"])
        XCTAssertNotNil(ar["ETA %@"])
    }
}
