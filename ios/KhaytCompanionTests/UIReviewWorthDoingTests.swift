import XCTest
@testable import KhaytCompanion

/// The "worth doing" items of the Nov 11 iPhone UI review
/// (~/Khayt-proposals/ios-ui-review-nov11.md §3–4, Figma page 27:2 of
/// R9W19Jakt19nKs1yM5GEde). Mostly source guards: each one names the screen
/// and the rule, so a later edit that brings the old colour or word back
/// fails here with the reason.
final class UIReviewWorthDoingTests: XCTestCase {
    static let iosDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    static let appDir = iosDir.appending(path: "KhaytCompanion")

    func source(_ path: String) throws -> String {
        try String(contentsOf: Self.appDir.appending(path: path), encoding: .utf8)
    }

    /// The code without its comments, so a comment naming the old colour
    /// does not count as a use of it.
    func code(_ path: String) throws -> String {
        try source(path).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func table(_ language: String) throws -> [String: String] {
        let url = Self.appDir.appending(path: "Resources/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
    }

    static let languages = ["ar", "de", "en", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"]

    func assertInEveryLanguage(_ keys: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        for language in Self.languages {
            let t = try table(language)
            for key in keys {
                XCTAssertFalse((t[key] ?? "").isEmpty, "\(key) missing in \(language)", file: file, line: line)
            }
        }
    }

    // MARK: W1 — one colour, one meaning

    func testWaitingListCardsAreSteelNotAmber() throws {
        let intake = try code("Views/IntakeView.swift")
        XCTAssertTrue(intake.contains("Rectangle().fill(KhaytDesign.pending)"), "the waiting card's edge is steel pending")
        XCTAssertFalse(intake.contains("Rectangle().fill(KhaytDesign.attention)"), "amber/attention is progress, not waiting")
        XCTAssertTrue(intake.contains("L10n.tr(\"intake.waiting\")"), "the card says Waiting in words")
        try assertInEveryLanguage(["intake.waiting"])
    }

    func testLiveStampIsLiveGreen() throws {
        let machines = try code("Views/MachinesView.swift")
        let stamp = try XCTUnwrap(machines.range(of: "struct LiveStamp"))
        let body = String(machines[stamp.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("KhaytDesign.live"))
        XCTAssertFalse(body.contains("KhaytDesign.done"), "done is finished work, not a printer talking")
    }

    func testNewSheetTilesShareOneTint() throws {
        let sheet = try code("Views/NewSheet.swift")
        for borrowed in ["KhaytDesign.live", "KhaytDesign.collect", "KhaytDesign.attention", "KhaytDesign.late"] {
            XCTAssertFalse(sheet.contains(borrowed), "New sheet tile borrows a status colour: \(borrowed)")
        }
    }

    func testOwedRemindIsBrandAndHealthySpoolsAreNotCollect() throws {
        let owed = try code("Views/OwedView.swift")
        XCTAssertFalse(owed.contains("KhaytDesign.done"), "Remind is an action: brand, not done teal")
        let inventory = try code("Views/InventoryView.swift")
        XCTAssertFalse(inventory.contains("KhaytDesign.collect"), "collect means ready to collect, not plenty left")
    }
}
