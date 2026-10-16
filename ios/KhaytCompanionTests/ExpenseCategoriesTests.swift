import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The phone's expense categories are the shop's: `lib/expense-book.js`
/// CATEGORIES, the list every report, budget and Mac picker uses. The phone
/// once offered resin, parts, rent and power, which none of them knew.
final class ExpenseCategoriesTests: XCTestCase {

    /// The list in `lib/`, read from the source the Mac and desktop run.
    private func libCategories() throws -> [String] {
        let lib = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "lib/expense-book.js")
        let source = try String(contentsOf: lib, encoding: .utf8)
        let line = try XCTUnwrap(source.split(separator: "\n").first { $0.contains("const CATEGORIES = [") })
        return line.split(separator: "'").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    func testThePhoneOffersExactlyTheShopsCategories() throws {
        XCTAssertEqual(ExpenseSheet.categories, try libCategories())
    }

    /// And the engine the phone carries keeps every one of them, rather than
    /// filing it as `other`.
    func testTheEngineKeepsEveryCategoryThePhoneOffers() async throws {
        let engine = try KhaytEngine()
        for category in ExpenseSheet.categories {
            let written = try await engine.newExpense(["amount": .number(10), "category": .string(category)],
                                                      id: "e-\(category)", today: "2026-10-16")
            guard case .object(let row)? = written.expense else { return XCTFail("no record for \(category)") }
            XCTAssertEqual(row["category"], .string(category))
        }
    }

    func testEveryCategoryHasWordsInBothLanguages() throws {
        for lang in ["en", "ar"] {
            let path = try XCTUnwrap(Bundle(for: PhoneCalculator.self).path(forResource: "Localizable", ofType: "strings",
                                                                          inDirectory: nil, forLocalization: lang))
            let strings = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
            for category in ExpenseSheet.categories {
                XCTAssertNotNil(strings["exp.cat.\(category)"], "\(lang) has no words for \(category)")
            }
        }
    }
}
