import XCTest
@testable import KhaytCompanion

/// The native Mac serves no `POST /api/expense` or `POST /api/quote` yet (only
/// the Windows/Linux app does; Mac's full review, Nov 10). Its 404 body is
/// `{"error":"Not found"}`, and the phone used to show exactly that, in
/// English. It must say this Mac can't take it yet, and never look saved:
/// the expense sheet closes only when `addExpense` returns.
@MainActor
final class MacWithoutRouteTests: XCTestCase {
    override func setUp() { RouteLessMac.reset() }

    private func client() -> (KhaytAPIClient, () -> Void) {
        let s = ConnectionSettings()
        let saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop)
        s.host = "khayt-routeless.invalid"; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        let api = KhaytAPIClient(settings: s, protocols: [RouteLessMac.self], withBook: false)
        return (api, { (s.host, s.port, s.pin, s.isPaired, s.isSampleShop) = saved })
    }

    func testAnExpenseWithAReceiptSaysThisMacCantTakeItYet() async throws {
        let (api, restore) = client()
        defer { restore() }
        let draft = ExpenseDraft(amount: 42, category: "materials", note: "PLA", receiptBase64: "aGVsbG8=")
        do {
            try await api.addExpense(draft)
            XCTFail("a 404 must not look saved")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.tr("expense.needs_mac"))
            XCTAssertNotEqual(error.localizedDescription, "Not found")
        }
        XCTAssertEqual(RouteLessMac.paths, ["/api/expense"])
    }

    func testAQuoteSaysThisMacCantPriceItYet() async throws {
        let (api, restore) = client()
        defer { restore() }
        let input = QuoteRequest(printWeight: 50, printTime: 2, qty: 1, margin: 30, spoolCost: 90, spoolWeight: 1000,
                                 laborRate: 0, prepTime: 0, postTime: 0, rush: false)
        do {
            _ = try await api.requestQuote(input)
            XCTFail("a 404 is not a price")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.tr("quote.needs_mac"))
        }
        XCTAssertEqual(RouteLessMac.paths, ["/api/quote"])
    }

    func testTheWordsAreInEveryLanguage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let url = root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in ["expense.needs_mac", "quote.needs_mac"] {
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang): \(key)")
            }
        }
    }
}

/// A Mac that has no such route: every request is its 404.
final class RouteLessMac: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var paths: [String] = []
    static func reset() { paths = [] }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "khayt-routeless.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.paths.append(request.url?.path ?? "")
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"Not found","endpoints":["/api/status"]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
