import XCTest
@testable import KhaytCompanion

/// The customer page's messages, as the cloud's owner route answers them.
final class PortalMessagesTests: XCTestCase {
    func testTheThreadReadsWhoSaidWhat() throws {
        let json = #"{"messages":[{"from":"customer","text":"Is it ready?","at":"2026-11-02T10:00:00Z"},{"from":"shop","text":"Tomorrow","at":"2026-11-02T10:05:00Z"}]}"#
        struct Reply: Decodable { let messages: [PortalMessage] }
        let m = try JSONDecoder().decode(Reply.self, from: Data(json.utf8)).messages
        XCTAssertTrue(m[0].fromCustomer)
        XCTAssertFalse(m[1].fromCustomer)
        XCTAssertNotEqual(m[0].id, m[1].id)
    }

    func testATokenIsOneSafePathSegment() {
        XCTAssertEqual(KhaytAPIClient.segment("a/b?c"), "a%2Fb%3Fc")
    }
}
