import XCTest
@testable import KhaytCompanion

/// A rush job shows as one: the desk writes `priority` as a boolean (and the
/// word in `priorityLevel`), older books as a word.
final class RushTests: XCTestCase {
    private func order(_ priority: String) throws -> QueueOrder {
        try JSONDecoder().decode(QueueOrder.self,
                                 from: Data(#"{"id":"A","status":"pending","priority":\#(priority)}"#.utf8))
    }

    func testEitherSpellingOfRushIsRush() throws {
        XCTAssertTrue(try order("true").isRush)
        XCTAssertTrue(try order(#""high""#).isRush)
        XCTAssertTrue(try order(#""urgent""#).isRush)
    }

    func testAnOrdinaryJobIsNot() throws {
        XCTAssertFalse(try order("false").isRush)
        XCTAssertFalse(try order(#""normal""#).isRush)
        XCTAssertFalse(try order("null").isRush)
    }
}
