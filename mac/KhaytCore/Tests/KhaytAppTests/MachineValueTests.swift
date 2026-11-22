import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac's side of machine depreciation and the learned failure allowance.
///
/// The arithmetic is `lib/depreciation.js` and `lib/failure-rate.js`, pinned in
/// Node and through the engine in `DepreciationTests`. What is held here is the
/// wiring a rule cannot see: the period the machine P&L pro-rates over, the
/// record the sheet reads back, and that every word it draws exists in both
/// languages.
@MainActor
struct MachineValueTests {

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.book.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test("the P&L period as book days, cut to today while it is running")
    func periodSpan() {
        let now = Self.day(2026, 5, 12)
        #expect(Shop.periodSpan(.month, now: now) == ("2026-05-01", "2026-05-12"))
        #expect(Shop.periodSpan(.last_month, now: now) == ("2026-04-01", "2026-04-30"))
        #expect(Shop.periodSpan(.quarter, now: now) == ("2026-04-01", "2026-05-12"))
        #expect(Shop.periodSpan(.year, now: now) == ("2026-01-01", "2026-05-12"))
        #expect(Shop.periodSpan(.all, now: now) == ("1970-01-01", "2026-05-12"))
        // January's last month is the previous December.
        #expect(Shop.periodSpan(.last_month, now: Self.day(2026, 1, 3)) == ("2025-12-01", "2025-12-31"))
    }

    @Test("All time starts at the book's first order, as the other app's analyticsRangeSpan does")
    func allTimeFromFirstOrder() {
        let now = Self.day(2026, 5, 12)
        let dates = ["2026-03-04", "", "not a day", "2025-11-20T10:00:00Z", "2026-01-01"]
        #expect(Shop.periodSpan(.all, now: now, dates: dates) == ("2025-11-20", "2026-05-12"))
        // Only All time reads the dates.
        #expect(Shop.periodSpan(.month, now: now, dates: dates) == ("2026-05-01", "2026-05-12"))
        // And Reports hands it the book's dates.
        let reports = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Reports.swift"), encoding: .utf8)) ?? ""
        #expect(reports.contains("range: Shop.periodSpan(shop.period, dates: shop.orderRows"))
        #expect(reports.contains("inventory: shop.inventoryRows,\n"))
        #expect(reports.contains("orders: shop.orderRows)"))
    }

    @Test("a machine reads its depreciation and target hours back, leniently")
    func decodes() throws {
        let json = """
        {"id":"M1","name":"U1","targetHoursPerDay":8,
         "depreciation":{"price":6000,"purchaseDate":"2026-01-01","life":"lots",
                         "lifeUnit":"hours","residual":1000,"method":"perHour","monthlyHours":null}}
        """
        let m = try JSONDecoder().decode(Machine.self, from: Data(json.utf8))
        #expect(m.targetHoursPerDay == 8)
        #expect(m.depreciation?.price == 6000)
        // One field of the wrong type costs that field, never the machine.
        #expect(m.depreciation?.life == nil)
        #expect(m.depreciation?.method == "perHour")
    }

    @Test("every word the depreciation and failure screens draw exists in English and Arabic")
    func words() {
        let keys = [
            "mac.pane_value", "mac.dep_title", "mac.dep_price", "mac.dep_bought", "mac.dep_life",
            "mac.dep_unit_hours", "mac.dep_unit_years", "mac.dep_residual", "mac.dep_method",
            "mac.dep_per_hour", "mac.dep_straight", "mac.dep_monthly_hours", "mac.dep_per_hour_hint",
            "mac.dep_straight_hint", "mac.dep_rate_line", "mac.dep_rate_missing", "mac.dep_value",
            "mac.dep_book_value", "mac.dep_to_date", "mac.dep_left", "mac.dep_hours_left",
            "mac.dep_months_left", "mac.dep_rate", "mac.dep_per_hour_amount", "mac.dep_fully",
            "mac.dep_needs_life", "mac.dep_needs_purchaseDate", "mac.dep_needs_monthlyHours",
            "mac.pnl_depreciation", "mac.fail_suggest", "mac.fail_use",
            "mac.fail_scope_machine_material", "mac.fail_scope_machine", "mac.fail_scope_material",
            "mac.fail_scope_shop", "mac.fail_too_few",
        ]
        for key in keys {
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) has no English")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) has no Arabic")
        }
        // Every `needs` the rule can answer has a sentence.
        for need in ["life", "purchaseDate", "monthlyHours"] {
            #expect(Words.own["mac.dep_needs_" + need] != nil)
        }
        // And every scope.
        for scope in ["machine_material", "machine", "material", "shop"] {
            #expect(Words.own["mac.fail_scope_" + scope] != nil)
        }
    }

    @Test("the machine sheet sends depreciation through the shared rule, and never sets a failure % itself")
    func wiring() throws {
        let sheet = MenuCoverageTests.source("MachineSheet.swift")
        #expect(sheet.contains("\"depreciation\": depreciationInput"))
        // The suggestion is only applied from its button's closure.
        let hint = MenuCoverageTests.source("MachineValue.swift")
        #expect(hint.contains("Button(shop.words.callIt(\"mac.fail_use\")) { use(pct) }"))
        for file in ["Calculator.swift", "ProductSheet.swift", "OnlinePane.swift"] {
            #expect(MenuCoverageTests.source(file).contains("FailureHint("), "\(file) offers no suggestion")
        }
    }
}
