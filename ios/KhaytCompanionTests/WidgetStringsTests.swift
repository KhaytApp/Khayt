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
        let source = try ["KhaytQueueWidget.swift", "PrintActivityWidget.swift", "PrintActivityViews.swift",
                          "KhaytMoneyWidget.swift", "MoneyWidgetViews.swift"].map {
            try String(contentsOf: root.appending(path: "KhaytWidget/\($0)"), encoding: .utf8)
        }.joined(separator: "\n")
        let ar = try table("ar")
        let pattern = #"(?:Text|metric)\("([^"\\]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let found = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        let shown = Set(found)
        XCTAssertFalse(shown.isEmpty, "the pattern still finds the widget's words")
        XCTAssertEqual(shown.filter { ar[$0] == nil }.sorted(), [], "shown by the widget, missing from ar.lproj")
        XCTAssertNotNil(ar["LAN connected"])
        XCTAssertNotNil(ar["%lld queued · %lld printing"])
        XCTAssertNotNil(ar["ETA %@"])
        XCTAssertNotNil(ar["Paused at %@"])
        XCTAssertNotNil(ar["Ends %@"])
        XCTAssertNotNil(ar["%lld unpaid"])
    }

    /// The widget ships in nine languages; a key missing from one shows English there.
    func testEveryLanguageHoldsTheSameKeys() throws {
        let en = Set(try table("en").keys)
        for lang in ["ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            XCTAssertEqual(Set(try table(lang).keys).symmetricDifference(en).sorted(), [], "\(lang) widget table")
        }
    }

    /// In Arabic the app's name is خيط in Arabic letters, and "تطبيق خيط" in a
    /// sentence, so it can't be read as the word for filament; the header says خيط.
    /// And the Money widget's figures are net of VAT, so nothing may say VAT is included.
    func testTheAppsNameAndNoVATIncluded() throws {
        XCTAssertEqual(try table("ar")["Khayt"], "خيط")
        for (key, value) in try table("ar") {
            XCTAssertFalse(value.contains("Khayt"), "\(key): the app is خيط in Arabic")
            if key != "Khayt" && key != "Khayt Money" {
                XCTAssertFalse(value.replacingOccurrences(of: "تطبيق خيط", with: "").contains("خيط"), "\(key): a bare خيط")
            }
            XCTAssertFalse(value.contains("شامل الضريبة"), key)
        }
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            for (key, value) in try table(lang) {
                XCTAssertFalse(value.localizedCaseInsensitiveContains("VAT included"), "\(lang) \(key)")
            }
        }
    }
}
