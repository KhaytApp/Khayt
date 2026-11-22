import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The phone's expense categories are the shop's: `ExpenseCategory.known`,
/// which KhaytCore's parity tests hold to `lib/expense-book.js`. The phone
/// once offered resin, parts, rent and power, which none of the readers knew.
final class ExpenseCategoriesTests: XCTestCase {

    /// The engine the phone carries keeps every one of them, rather than
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
