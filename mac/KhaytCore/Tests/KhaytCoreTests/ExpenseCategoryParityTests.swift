import Foundation
import Testing
@testable import KhaytCore

/// `ExpenseCategory` against `lib/expense-book.js`, which it mirrors.
///
/// The Swift map exists because its readers are synchronous and the engine is
/// an actor. A second copy of a rule is only safe while something holds it to
/// the first: so the list, the alias map and the answer for every spelling
/// worth asking about are compared with the JavaScript's own.
@MainActor
struct ExpenseCategoryParityTests {

    private func js() throws -> JSModule { try JSModule(["expense-book"]) }

    @Test("the category list is the book's, in the book's order")
    func listMatches() throws {
        let theirs = try js().value("globalThis.KhaytExpenseBook.CATEGORIES")
        #expect(theirs == .array(ExpenseCategory.known.map { .string($0) }))
    }

    @Test("the alias map is the book's, entry for entry")
    func aliasesMatch() throws {
        let theirs = try js().value("globalThis.KhaytExpenseBook.CATEGORY_ALIASES")
        #expect(theirs == .object(ExpenseCategory.aliases.mapValues { .string($0) }))
    }

    @Test("power is electricity, parts maintenance, rent and resin other — never filament")
    func theFourAliases() {
        #expect(ExpenseCategory.normalise("power") == "electricity")
        #expect(ExpenseCategory.normalise("parts") == "maintenance")
        #expect(ExpenseCategory.normalise("rent") == "other")
        #expect(ExpenseCategory.normalise("resin") == "other")
        #expect(ExpenseCategory.normalise(" Resin ") != "filament")
    }

    @Test("every spelling reads the same on both sides")
    func everySpellingMatches() throws {
        let js = try js()
        let words = [
            "power", "Power", " POWER ", "parts", "Parts\n", "rent", "RENT", "resin", " Resin ",
            "filament", "Filament", " electricity ", "Maintenance", "tools", "equipment",
            "shipping", "other", "courier", "Courier", "", "  ", "constructor", "__proto__",
            "toString",
        ]
        let spellings: [JSONValue] = words.map { .string($0) } + [.number(7), .bool(true), .null]
        for raw in spellings {
            let theirs = try js.value("globalThis.KhaytExpenseBook.categoryOf({ category: ARG0 })", [raw])
            let mine = ExpenseCategory.normalise(raw) ?? .null
            #expect(mine == theirs, "\(raw): swift \(mine), js \(theirs)")
        }
    }
}
