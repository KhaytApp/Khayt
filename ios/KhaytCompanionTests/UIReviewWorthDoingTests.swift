import XCTest
import KhaytCore
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

// MARK: W2 — say it in words, not only colour
extension UIReviewWorthDoingTests {
    func testCompactJobCardSaysLate() throws {
        let card = try code("Views/JobCard.swift")
        XCTAssertTrue(card.contains("if layout == .compact, order.isOverdue { LateBadge() }"),
                      "Home's compact card shows the late word, not only a red outline")
        XCTAssertTrue(card.contains("if layout == .full, order.isOverdue { LateBadge() }"))
    }

    func testLowSpoolsSayLow() throws {
        let inventory = try code("Views/InventoryView.swift")
        XCTAssertTrue(inventory.contains("L10n.tr(\"spool.low\")"))
        try assertInEveryLanguage(["spool.low", "stage.a11y.done"])
    }

    func testSelectedChipsCarryTheSelectedTrait() throws {
        for file in ["Views/OrdersView.swift", "Views/InventoryView.swift", "Views/V2Form.swift"] {
            XCTAssertTrue(try code(file).contains(".accessibilityAddTraits(on ? .isSelected : [])"), file)
        }
    }

    func testPassedStagesSayDone() throws {
        XCTAssertTrue(try code("Views/OrderDetailPage.swift")
            .contains(".accessibilityValue(passed ? L10n.tr(\"stage.a11y.done\") : \"\")"))
    }

    func testWidgetDotHasAWord() throws {
        let widget = try String(contentsOf: Self.iosDir.appending(path: "KhaytWidget/KhaytQueueWidget.swift"), encoding: .utf8)
        let header = try XCTUnwrap(widget.range(of: "private func header("))
        XCTAssertTrue(widget[header.lowerBound...].prefix(700).contains("Text(statusLine(s))"),
                      "the connection dot is said in a word")
    }
}

// MARK: W3 — one reference style: S-1041, never #S-1041
extension UIReviewWorthDoingTests {
    func testNoScreenWritesAHashBeforeAReference() throws {
        let hashed = try NSRegularExpression(pattern: ##"("#\\\(|"#"\s*\+)"##)
        var found: [String] = []
        for dir in ["KhaytCompanion", "KhaytWidget", "KhaytAlerts"] {
            let root = Self.iosDir.appending(path: dir)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for url in files {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let l = String(line)
                    // A colour written as "#rrggbb" is not a reference.
                    if l.lowercased().contains("hex") { continue }
                    if hashed.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil {
                        found.append("\(url.lastPathComponent):\(n + 1)")
                    }
                }
            }
        }
        XCTAssertEqual(found, [], "a job reference is written S-1041, without '#'")
    }
}

// MARK: W4 — the New sheet opens with every choice in view
extension UIReviewWorthDoingTests {
    func testNewSheetOpensLarge() throws {
        let sheet = try code("Views/NewSheet.swift")
        XCTAssertTrue(sheet.contains(".presentationDetents([.large])"))
        XCTAssertFalse(sheet.contains(".medium"), "at medium two of the six tiles sit below the fold")
    }
}

// MARK: W5 — one sheet header: Close on the leading side, an inline title
extension UIReviewWorthDoingTests {
    func testSheetsCloseOnTheLeadingSide() throws {
        for file in ["Views/AddSpoolSheet.swift", "Views/NewOrderSheet.swift", "Views/IntakeView.swift", "Views/NewSheet.swift"] {
            let text = try code(file)
            let close = try XCTUnwrap(text.range(of: "placement: .cancellationAction"), file)
            XCTAssertTrue(text[close.upperBound...].prefix(120).contains("common.close"), "\(file): Close, not Cancel/Done")
            XCTAssertFalse(text.contains(".navigationBarTitleDisplayMode(.large)"), "\(file): inline title")
        }
        XCTAssertFalse(try code("Views/IntakeView.swift").contains("placement: .confirmationAction"))
        // `khaytScreen` sets a large title that wins over an inline mode set after it.
        for file in ["Views/IntakeView.swift", "Views/LibraryView.swift"] {
            XCTAssertFalse(try code(file).contains(".khaytScreen("), "\(file): inline title")
        }
    }
}

// MARK: W6 — hints that don't look like data
extension UIReviewWorthDoingTests {
    func testNewOrderHintsAreTranslatedNotSampleData() throws {
        let sheet = try code("Views/NewOrderSheet.swift")
        for fake in ["Acme Robotics", "Falcon hood", "PLA · Ink"] {
            XCTAssertFalse(sheet.contains(fake), "\(fake) reads as a filled value")
        }
        let keys = ["order.new.hint.client", "order.new.hint.project", "order.new.hint.material"]
        for key in keys { XCTAssertTrue(sheet.contains("L10n.tr(\"\(key)\")"), key) }
        try assertInEveryLanguage(keys)
        // Arabic hints are Arabic (PLA stays as the material's own name).
        let ar = try table("ar")
        XCTAssertNotEqual(ar["order.new.hint.client"], try table("en")["order.new.hint.client"])
    }
}

// MARK: W7 — swatches carry a ring that shows on navy and on paper
extension UIReviewWorthDoingTests {
    func testSwatchRingIsVisibleWeight() {
        XCTAssertEqual(SpoolSwatch.ring(for: 48), 2)
        XCTAssertEqual(SpoolSwatch.ring(for: 14), 1.5)
    }
}

// MARK: W10 — WhatsApp opens in the customer's language, else the app's
extension UIReviewWorthDoingTests {
    func testWhatsAppStartsInTheCustomersLanguageElseTheApps() {
        let pick = KhaytAPIClient.whatsAppStartLanguage
        XCTAssertEqual(pick(["messageLang": .string("en")], "ar"), "en", "the customer's own language wins")
        XCTAssertEqual(pick(["messageLang": .string("ar")], "en"), "ar")
        // Written down only in English, no language set: the app's language.
        XCTAssertEqual(pick(["nameEn": .string("Jordan Lee")], "ar"), "ar")
        XCTAssertEqual(pick(nil, "en"), "en")
        XCTAssertEqual(pick(["messageLang": .string("fr")], "en"), "en", "only ar/en messages exist")
    }

    func testTheSheetAsksForTheStartLanguage() throws {
        XCTAssertTrue(try code("Views/WhatsAppSheet.swift").contains("fill(lang: api.whatsAppStartLanguage(orderId: orderId))"))
    }
}

// MARK: P7 — the views nothing drew are gone
extension UIReviewWorthDoingTests {
    func testTheUncalledViewsStayRemoved() throws {
        let gone = ["KhaytSectionHeader", "KhaytCard", "KhaytStatBlock", "KhaytPill", "KhaytMetric",
                    "KhaytPrimaryButton", "KhaytGhostButton", "KhaytLogoMark", "KhaytListRow",
                    "CompanionStatusBadge", "QueueView", "KanbanStripView"]
        let files = FileManager.default.enumerator(at: Self.appDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var found: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for name in gone where text.range(of: "struct \(name)\\b", options: .regularExpression) != nil {
                found.append("\(url.lastPathComponent): \(name)")
            }
        }
        XCTAssertEqual(found, [], "a view with no caller came back; draw with the screens' own pieces")
        for file in ["Views/QueueView.swift", "Views/KanbanStripView.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: Self.appDir.appending(path: file).path()), file)
        }
    }
}

// MARK: P8 — the unread badge sits on the bell's trailing corner in Arabic too
extension UIReviewWorthDoingTests {
    func testUnreadBadgeOffsetMirrors() throws {
        let home = try code("Views/DashboardView.swift")
        XCTAssertFalse(home.contains(".offset(x: 2, y: -2)"), "an x offset does not flip in right-to-left")
    }
}

// MARK: P4 — Inventory's filter chips are Orders' chips
extension UIReviewWorthDoingTests {
    func testInventoryChipsMatchOrders() throws {
        let inventory = try code("Views/InventoryView.swift")
        XCTAssertTrue(inventory.contains("Circle().fill(tone).frame(width: 7, height: 7)"), "the dot")
        XCTAssertTrue(inventory.contains(".font(.khayt(13.5, .semibold, relativeTo: .subheadline))"), "13.5 as in Orders")
        XCTAssertTrue(inventory.contains("count.formatted(.number.locale(L10n.locale))"), "the count")
    }
}
