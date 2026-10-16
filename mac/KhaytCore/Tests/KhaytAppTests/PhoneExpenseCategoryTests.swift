import Testing
import Foundation
import KhaytCore
@testable import KhaytApp

/// The iPhone saved `power`, `parts`, `rent` and `resin` before its expense
/// sheet was fixed. The Mac reads them as what they meant — in the table, the
/// totals, the monthly budgets and the engine's own budget check — and leaves
/// the book on disk as it was.
@MainActor
struct PhoneExpenseCategoryTests {

    private func decode(_ category: String, _ amount: Double, _ date: String) throws -> Expense {
        let row: [String: Any] = ["id": "E-" + category, "date": date, "category": category, "amount": amount]
        return try JSONDecoder().decode(Expense.self, from: JSONSerialization.data(withJSONObject: row))
    }

    @Test("an old row decodes as the category it meant, so the table and picker name it")
    func decodesAsMeant() throws {
        #expect(try decode("power", 1, "2026-10-01").category == "electricity")
        #expect(try decode("parts", 1, "2026-10-01").category == "maintenance")
        #expect(try decode("rent", 1, "2026-10-01").category == "other")
        #expect(try decode("resin", 1, "2026-10-01").category == "other")
        #expect(try decode(" Filament ", 1, "2026-10-01").category == "filament")
        #expect(try decode("Courier", 1, "2026-10-01").category == "Courier",
                "an unknown category is kept as it was")
        let power = try decode("power", 1, "2026-10-01")
        #expect(Shop.expenseCategories.contains(power.category),
                "an old power row would otherwise be a blank picker")
    }

    @Test("an old power row counts towards the electricity budget, on the Mac and in the rule")
    func countsTowardsTheBudget() async throws {
        let rows = [try decode("power", 300, "2026-10-02"), try decode("electricity", 250, "2026-10-09"),
                    try decode("resin", 80, "2026-10-10")]
        let month = Shop.totals(of: rows, inMonth: "2026-10")
        #expect(month["electricity"] == 550)
        #expect(month["other"] == 80)
        #expect(month["filament"] == 0, "resin is not filament")
        #expect(month["power"] == nil)

        let engine = try KhaytEngine()
        let book: [JSONValue] = [
            .object(["category": .string("power"), "amount": .number(300), "date": .string("2026-10-02")]),
            .object(["category": .string("electricity"), "amount": .number(250), "date": .string("2026-10-09")]),
        ]
        let over = try await engine.overBudget(book, category: "electricity", month: "2026-10",
                                               budgets: ["electricity": .number(500)])
        #expect(over?.spent == 550)
    }
}
