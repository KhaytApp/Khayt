import XCTest
@testable import KhaytCompanion

/**
 * Every screen in both languages, or a test that says which one is not.
 *
 * The companion ships in English and Arabic, and a shop that picks Arabic in
 * Settings reads whatever this file lets through. Before this existed the
 * pairing wizard — the first screen a new shop sees — had no Arabic at all,
 * and nothing anywhere could have noticed.
 *
 * Read from the source tree (`#filePath`), the way `UnpairTellsTheTruthTests`
 * reads the strings files: the simulator shares the Mac's disk.
 */
final class LocalizationCompletenessTests: XCTestCase {

    private static let appDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "KhaytCompanion")

    private func table(_ language: String) throws -> [String: String] {
        let url = Self.appDir.appending(path: "Resources/\(language).lproj/Localizable.strings")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String],
                                 "\(language).lproj/Localizable.strings did not parse")
        return dict
    }

    private func swiftSources() throws -> [(name: String, text: String)] {
        let files = FileManager.default.enumerator(at: Self.appDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testEnglishAndArabicHoldTheSameKeys() throws {
        let en = Set(try table("en").keys), ar = Set(try table("ar").keys)
        XCTAssertEqual(en.subtracting(ar).sorted(), [], "in English, missing from Arabic")
        XCTAssertEqual(ar.subtracting(en).sorted(), [], "in Arabic, missing from English")
    }

    func testEveryKeyTheAppAsksForExists() throws {
        // A missing key does not crash — NSLocalizedString hands back the key,
        // and the screen shows `pair.verify.ok` to a customer.
        let en = try table("en")
        let pattern = try NSRegularExpression(pattern: #"L10n\.tr\("([a-z0-9_.]+)"\)"#)
        var missing: [String] = []
        for (name, text) in try swiftSources() {
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let key = String(text[Range(match.range(at: 1), in: text)!])
                if en[key] == nil { missing.append("\(name): \(key)") }
            }
        }
        XCTAssertEqual(missing, [])
    }

    func testTheTwoLanguagesTakeTheSameArguments() throws {
        // `String(format:)` with a translation that expects different
        // arguments is not a wrong word, it is a crash or a garbage number.
        let en = try table("en"), ar = try table("ar")
        let spec = try NSRegularExpression(pattern: #"%(\d+\$)?[@dfs]"#)
        func specs(_ s: String) -> [String] {
            spec.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
                .sorted()
        }
        var mismatched: [String] = []
        for (key, english) in en {
            guard let arabic = ar[key] else { continue }
            if specs(english) != specs(arabic) { mismatched.append(key) }
        }
        XCTAssertEqual(mismatched.sorted(), [])
    }

    /// Screens that are fully translated, and must stay so. A literal English
    /// label added to one of these fails here, by file and by line. Add a
    /// screen to the list when it is done; never take one off.
    static let translatedScreens: Set<String> = [
        "PairingView.swift",
        "OrdersView.swift",
        "NewOrderSheet.swift",
        "OrderDetailSheet.swift",
        "SpoolDetailSheet.swift",
        "QueueView.swift",
        "IntakeView.swift",
        "ClientsView.swift",
        "MachinesView.swift",
        "AddSpoolSheet.swift",
        "ProductBarcodeScanner.swift",
        "BarcodeScannerView.swift",
        "DashboardView.swift",
        "QuoteSheet.swift",
        "ExpenseSheet.swift",
        "WriteNFCTagSheet.swift",
        "ConnectionBanner.swift",
    ]

    func testTranslatedScreensHaveNoEnglishLeftInThem() throws {
        let literal = try NSRegularExpression(pattern:
            #"\b(Text|Label|Button|TextField|SecureField|Toggle|Stepper|DisclosureGroup|Section|Picker|ContentUnavailableView|navigationTitle)\("[A-Za-z]"#)
        var found: [String] = []
        for (name, text) in try swiftSources() where Self.translatedScreens.contains(name) {
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                if literal.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil {
                    found.append("\(name):\(number + 1): \(l.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(found, [], "hard-coded English on a translated screen")
    }

    func testArabicCountsTakeTheirOwnForms() {
        // Arabic has a form for two and another for eleven and up; "%d بكرات"
        // is right only from three to ten. The rules live in
        // Localizable.stringsdict, and the LOCALE picks which one applies — so
        // with the device in English and the app in Arabic, formatting with
        // the device's locale gave "إضافة 2 بكرة". `L10n.count` is the fix.
        L10n.setLanguage(.ar)
        defer { L10n.setLanguage(.system) }
        func add(_ n: Int) -> String { L10n.count("spool.add.n", n) }
        XCTAssertEqual(add(1), "إضافة بكرة واحدة")
        XCTAssertEqual(add(2), "إضافة بكرتين")
        // The digits are the locale's too, so the word is what is checked.
        XCTAssertTrue(add(5).hasSuffix(" بكرات"), add(5))
        XCTAssertTrue(add(11).hasSuffix(" بكرة"), add(11))
        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.count("spool.add.n", 1), "Add 1 spool")
        XCTAssertEqual(L10n.count("spool.add.n", 3), "Add 3 spools")
    }
}
