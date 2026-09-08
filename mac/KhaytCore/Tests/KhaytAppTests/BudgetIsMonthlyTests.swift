import Testing
import Foundation
import KhaytCore
@testable import KhaytApp

/// A budget is a MONTHLY thing, and the panel that reports it says so.
///
/// `lib/expense-book.js` filters on `date.startsWith(month)` and the toast after
/// an overspend says "this month". The Mac's panel fed it the SHOWN totals
/// instead, which the period picker moves — so on "All time" a shop was told it
/// was over a monthly budget by the sum of every month it had ever recorded.
/// Two of the sample book's three "Over budget" warnings were false.
@MainActor
struct BudgetIsMonthlyTests {

    /// The rule itself, over a book spanning three months. Run through the
    /// engine rather than restated here: the app's panel and Khayt's toast have
    /// to agree about what "over budget" means.
    @Test func onlyThisMonthCountsTowardsAMonthlyBudget() async throws {
        let engine = try KhaytEngine()
        let expenses: [JSONValue] = [
            .object(["category": .string("filament"), "amount": .number(1240),
                     "date": .string("2026-09-02")]),
            .object(["category": .string("filament"), "amount": .number(890),
                     "date": .string("2026-07-21")]),
            .object(["category": .string("tools"), "amount": .number(430),
                     "date": .string("2026-08-12")]),
        ]
        let budgets: [String: JSONValue] = ["filament": .number(1500), "tools": .number(250)]

        // 1,240 spent this month against 1,500 — under, though 2,130 has been
        // spent on filament across the book.
        let filament = try await engine.overBudget(expenses, category: "filament",
                                                   month: "2026-09", budgets: budgets)
        #expect(filament == nil, "1,240 of a 1,500 monthly budget is not over it")

        // Nothing at all this month, though 430 of a 250 budget was spent in August.
        let tools = try await engine.overBudget(expenses, category: "tools",
                                                month: "2026-09", budgets: budgets)
        #expect(tools == nil, "a category untouched this month cannot be over this month")

        // And August really was over, so the rule is not simply answering nil.
        let august = try await engine.overBudget(expenses, category: "tools",
                                                 month: "2026-08", budgets: budgets)
        #expect(august != nil, "430 of a 250 budget in August is over it")
    }
}

@MainActor
struct BudgetTotalsTests {

    static func expense(_ category: String, _ amount: Double, _ date: String) throws -> Expense {
        try JSONDecoder().decode(Expense.self, from: Data("""
        {"id": "E-\(date)-\(category)", "date": "\(date)", "category": "\(category)",
         "amount": \(amount), "note": ""}
        """.utf8))
    }

    /// THE WIRING. The panel is fed `expenseTotalsThisMonth`, and what makes it
    /// right is that it ignores the period picker entirely: the same book must
    /// give the same budget figures whether the shop is looking at this month or
    /// at all time.
    @Test func onlyTheMonthAskedForIsCounted() throws {
        let book = [
            try Self.expense("filament", 1240, "2026-09-02"),
            try Self.expense("filament", 890, "2026-07-21"),
            try Self.expense("tools", 430, "2026-08-12"),
            try Self.expense("electricity", 610, "2026-09-01"),
        ]
        let september = Shop.totals(of: book, inMonth: "2026-09")
        #expect(september["filament"] == 1240, "not 2,130 — July is not this month")
        #expect(september["tools"] == 0, "a category untouched this month is at zero, not 430")
        #expect(september["electricity"] == 610)

        // Every category the shop has is present at zero rather than missing, so
        // a budget with nothing spent against it still draws its row.
        for category in Shop.expenseCategories {
            #expect(september[category] != nil, "\(category) went missing")
        }

        // And it really is filtering — August is a different answer.
        #expect(Shop.totals(of: book, inMonth: "2026-08")["tools"] == 430)
        #expect(Shop.totals(of: book, inMonth: "2026-08")["filament"] == 0)
    }
}
