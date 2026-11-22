import XCTest
import CryptoKit
import KhaytCore
@testable import KhaytCompanion

/// The shop's other alerts — late jobs, low filament, due today, and the
/// cloud's own about a customer's page — open where they are about.
final class ShopPushTests: XCTestCase {
    typealias Nav = OrdersNavigationState

    private func push(_ k: [String: Any]) -> Nav.Destination? {
        Nav.destination(identifier: "x", thread: "", userInfo: ["k": k])
    }

    func testEachKindOpensItsList() {
        XCTAssertEqual(push(["kind": "overdue"]), .overdue)
        XCTAssertEqual(push(["kind": "low-stock"]), .lowStock)
        XCTAssertEqual(push(["kind": "due-today"]), .orders)
        XCTAssertEqual(push(["kind": "payment", "ref": ["item": "ABCDEF0123456789"]]), .published("abcdef0123456789"))
        XCTAssertEqual(push(["kind": "message"]), .orders, "no page named: the jobs")
    }

    /// The cloud names a page by the first 16 hex of SHA-256 of its token.
    func testACustomerPageIsFoundByItsTokensHash() {
        let token = "tok-abc"
        let item = String(SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        let store: [String: JSONValue] = ["printLog": .array([
            .object(["id": .string("A"), "trackingToken": .string("other")]),
            .object(["id": .string("B"), "trackingToken": .string(token)]),
        ])]
        XCTAssertEqual(KhaytAPIClient.orderId(publishedItem: item, in: store), "B")
        XCTAssertNil(KhaytAPIClient.orderId(publishedItem: "0000000000000000", in: store))
    }

    func testEveryStreamKindHasWords() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        for key in PrintAlertCenter.shopAlertKeys.values { XCTAssertNotEqual(L10n.tr(key), key, key) }
    }
}
