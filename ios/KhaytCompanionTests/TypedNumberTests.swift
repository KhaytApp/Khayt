import XCTest
@testable import KhaytCompanion

/// The one reader for a figure typed on the phone, and the order-status write
/// that must not swallow a refusal.
@MainActor
final class TypedNumberTests: XCTestCase {
    func testWesternArabicIndicAndExtendedDigitsAllRead() {
        XCTAssertEqual(PhoneCalculator.parse("75"), 75)
        XCTAssertEqual(PhoneCalculator.parse("٧٥"), 75)
        XCTAssertEqual(PhoneCalculator.parse("۷۵"), 75)
        XCTAssertEqual(PhoneCalculator.parse("٧٥٫٥٠"), 75.5)
    }

    func testDecimalPointsRead() {
        XCTAssertEqual(PhoneCalculator.parse("1.5"), 1.5)
        XCTAssertEqual(PhoneCalculator.parse("75,50"), 75.5, "a European keypad's decimal comma")
        XCTAssertEqual(PhoneCalculator.parse("0,500"), 0.5)
    }

    func testAThousandsMarkIsNotADecimal() {
        XCTAssertEqual(PhoneCalculator.parse("1,500"), 1500)
        XCTAssertEqual(PhoneCalculator.parse("١٬٥٠٠"), 1500)
        XCTAssertEqual(PhoneCalculator.parse("1,500,000"), 1_500_000)
        XCTAssertEqual(PhoneCalculator.parse("1,500.25"), 1500.25)
        XCTAssertEqual(SpoolDraft.price("1,500"), 1500)
    }

    func testEmptyAndGarbageReadAsNothing() {
        XCTAssertNil(PhoneCalculator.parse(""))
        XCTAssertNil(PhoneCalculator.parse("  "))
        XCTAssertNil(PhoneCalculator.parse("abc"))
        XCTAssertNil(PhoneCalculator.parse("1.2.3"))
        XCTAssertEqual(PhoneCalculator.number("abc"), 0)
        XCTAssertEqual(PhoneCalculator.wholeNumber("٢٥٠"), 250)
        XCTAssertNil(PhoneCalculator.wholeNumber("2.5"))
        XCTAssertNil(PhoneCalculator.wholeNumber("-3"))
    }

    // MARK: - PATCH /api/orders/:id

    override func setUp() { RefusingMac.reset() }

    func testAnOrderStatusRefusedByTheMacThrows() async throws {
        let s = ConnectionSettings()
        let saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop)
        defer { (s.host, s.port, s.pin, s.isPaired, s.isSampleShop) = saved }
        s.host = "khayt-refuse.invalid"; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        let api = KhaytAPIClient(settings: s, protocols: [RefusingMac.self], withBook: false)
        do {
            try await api.updateOrderStatus(orderId: "O-1", status: "printing")
            XCTFail("a 400 must not look saved")
        } catch {
            XCTAssertEqual(RefusingMac.patches, 1)
        }
    }

    func testTheFallbackMessagesAreLocalised() {
        XCTAssertFalse(L10n.format("api.request_failed", 500).hasPrefix("api."))
        XCTAssertFalse(L10n.format("order.untitled", "O-1").hasPrefix("order."))
    }
}

final class RefusingMac: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var patches = 0
    static func reset() { patches = 0 }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "khayt-refuse.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if request.httpMethod == "PATCH" { Self.patches += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"bad stage"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
