import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The alpha.51 screenshot review, rendered from the shop's real book. One test
/// per finding that can be held in code; the machine band's and the masthead's
/// live in `BandOfflineTests` and `MastheadNetTests` beside the earlier ones.
@MainActor
struct Review51Tests {

    // MARK: - Waste is a P&L line

    @Test("a failed print costing 12 takes 12 off the net and is reported as waste")
    func wasteReachesTheNet() async throws {
        let engine = try KhaytEngine()
        let expenses: [JSONValue] = [
            .object(["id": .string("E1"), "date": .string("2026-09-10"), "category": .string("rent"),
                     "amount": .number(40)]),
        ]
        let waste: [JSONValue] = [
            .object(["id": .string("W1"), "date": .string("2026-09-12"), "cost": .number(12),
                     "grams": .number(80), "material": .string("PLA")]),
        ]
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let without = try await engine.pnlByPeriod(orders: [], expenses: expenses, settings: [:],
                                                    clients: [], currencies: [:], now: now)
        let with = try await engine.pnlByPeriod(orders: [], expenses: expenses, settings: [:],
                                                clients: [], currencies: [:], now: now, wasteLog: waste)
        let before = try #require(without.first { $0.period == "2026-Q3" })
        let after = try #require(with.first { $0.period == "2026-Q3" })
        #expect(after.waste == 12)
        #expect(abs((before.net - after.net) - 12) < 0.001,
                Comment(rawValue: "net \(before.net) → \(after.net)"))
        #expect(after.expenses == before.expenses, "waste was booked as an expense")
    }

    @Test("both P&L callers hand the rule the book's waste log, and Reports draws the line")
    func wasteIsWired() throws {
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        let reports = try QuoteSheetStatusTests.source("Reports.swift")
        #expect(shop.contains("wasteLog: Self.rows(root, \"wasteLog\")"),
                "the dashboard's net leaves failed prints out")
        #expect(reports.contains("wasteLog: shop.wasteRows"), "Reports leaves failed prints out")
        #expect(reports.contains("\"pnl.waste\""), "no waste line in Reports")
    }

    // MARK: - Item 4: the minus sign in Arabic

    @Test("a negative figure is held left-to-right, so the minus stays in front in Arabic")
    func negativesAreIsolated() {
        let said = Money.text(-35.91, "SAR")
        #expect(said.hasPrefix("\u{2066}-35.91\u{2069}"), Comment(rawValue: said.debugDescription))
        #expect(Money.figure(-35.91) == "\u{2066}-35.91\u{2069}")
        // Positive and zero figures are untouched.
        #expect(Money.figure(35.91) == "35.91")
        #expect(Money.figure(-0.001) == "0.00")
        #expect(!Money.text(50, "SAR").contains("\u{2066}"))
    }

    // MARK: - Item 5: one sign for cost lines

    @Test("every cost line in Reports reads negative, table and panel alike")
    func costLinesAreSignedOnce() throws {
        #expect(Money.cost(35.91, "SAR") == Money.text(-35.91, "SAR"))
        #expect(Money.cost(0, "SAR") == Money.text(0, "SAR"), "no cost is an unsigned zero")
        let reports = try QuoteSheetStatusTests.source("Reports.swift")
        // The panel once printed cost of goods as a plain positive beside a
        // table that signed it.
        #expect(!reports.contains("Money.text(rows.reduce(0) { $0 + $1.cogsValue }"),
                "the side panel prints cost of goods unsigned again")
        #expect(!reports.contains("Money.text(-"), "a cost line signs itself instead of Money.cost")
    }

    // MARK: - Item 7: the cash-flow totals fit

    @Test("a one-quarter book gets a one-row table, not an empty second row")
    func tableIsAsTallAsItsRows() {
        #expect(Reports.tableHeight(1) < Reports.tableHeight(2))
        #expect(Reports.tableHeight(0) == Reports.tableHeight(1))
        #expect(Reports.tableHeight(40) == Reports.tableHeight(10))
    }

    // MARK: - Item 8: counted, not "(s)"

    @Test("the board's banners count in English and Arabic, with no (s)")
    func boardCounts() async throws {
        let en = Words()
        #expect(en.counting(20, "mac.board_finished_elsewhere").hasPrefix("20 finished jobs left"))
        #expect(en.counting(1, "mac.board_finished_elsewhere").hasPrefix("1 finished job left"))
        #expect(en.counting(1, "mac.board_unplaced").hasPrefix("1 job is"))
        let ar = Words()
        await ar.load("ar", engine: try KhaytEngine())
        #expect(ar.counting(2, "mac.board_finished_elsewhere").hasPrefix("عملان"))
        #expect(ar.counting(1, "mac.board_finished_elsewhere").contains("واحد"))
        #expect(!ar.counting(1, "mac.board_finished_elsewhere").contains("1 "))
        for key in ["mac.board_finished_elsewhere", "mac.board_unplaced"] {
            for n in [1, 2, 3, 20] {
                #expect(!en.counting(n, key).contains("(s)"))
                #expect(!en.counting(n, key).contains("{n}"))
                #expect(!ar.counting(n, key).contains("{n}"))
            }
        }
        let kanban = try QuoteSheetStatusTests.source("Kanban.swift")
        #expect(kanban.contains("counting(finished, \"mac.board_finished_elsewhere\")"))
        #expect(kanban.contains("counting(shop.unplaced.count, \"mac.board_unplaced\")"))
    }

    // MARK: - Item 9: dark-mode ink

    @Test("an enabled worded action draws in full ink and a disabled one in the third")
    func wellButtonInk() {
        #expect(WellButtonStyle.ink(onNavy: true, enabled: true) == Role.onNavy)
        #expect(WellButtonStyle.ink(onNavy: true, enabled: false) == Role.onNavy3)
        #expect(WellButtonStyle.ink(onNavy: false, enabled: true) == Role.text)
        #expect(WellButtonStyle.ink(onNavy: false, enabled: false) == Role.text3)
    }

    @Test("Spoolman import, Add supplier and the idle search words use the app's own ink")
    func darkModeInkIsOurs() throws {
        let actions = try QuoteSheetStatusTests.source("ScreenActions.swift")
        let suppliers = try QuoteSheetStatusTests.source("SupplierSheet.swift")
        let shell = try QuoteSheetStatusTests.source("Shell.swift")
        #expect(actions.contains(".buttonStyle(WellButtonStyle(onNavy: true))"))
        #expect(suppliers.contains(".buttonStyle(WellButtonStyle())"))
        guard let idle = shell.range(of: "Text(shop.words.callIt(\"mac.search_the_book\"))") else {
            Issue.record("the idle search words moved"); return
        }
        let after = shell[idle.upperBound...].prefix(200)
        #expect(after.contains(".foregroundStyle(Role.onNavy3)"),
                "the idle search words inherit the strip's near-white ink")
    }
}
