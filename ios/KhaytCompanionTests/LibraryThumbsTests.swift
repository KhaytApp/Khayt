import XCTest
@testable import KhaytCompanion

/// Library pictures kept on the phone for away from the shop.
@MainActor
final class LibraryThumbsTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        ThumbMac.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        ThumbMac.reset()
    }

    func testAPictureIsKeptWithTheTimeTheMacSentIt() async {
        let shelf = LibraryThumbs(directory: dir)
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        await shelf.put("PF/1 with:odd?chars", Data([1, 2, 3]), now: sent)
        let got = await shelf.get("PF/1 with:odd?chars", now: sent.addingTimeInterval(3600))
        XCTAssertEqual(got?.data, Data([1, 2, 3]))
        XCTAssertEqual(got?.age ?? 0, 3600, accuracy: 1)
        let again = await shelf.get("PF/1 with:odd?chars", now: sent.addingTimeInterval(7200))
        XCTAssertEqual(again?.age ?? 0, 7200, accuracy: 1, "looking at it does not make it newer")
        let kept = await shelf.kept(["PF/1 with:odd?chars", "PF-2"])
        XCTAssertEqual(kept, ["PF/1 with:odd?chars"])
        await shelf.remove("PF/1 with:odd?chars")
        let gone = await shelf.get("PF/1 with:odd?chars")
        XCTAssertNil(gone)
    }

    func testOverTheBudgetTheLeastRecentlySeenGoFirst() async {
        let shelf = LibraryThumbs(directory: dir, budget: 1000)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 { await shelf.put("m\(i)", Data(repeating: 7, count: 300), now: t0.addingTimeInterval(Double(i))) }
        // m0 is looked at again, so m1 is the least recently seen when m3 tips it over.
        _ = await shelf.get("m0", now: t0.addingTimeInterval(10))
        await shelf.put("m3", Data(repeating: 7, count: 300), now: t0.addingTimeInterval(11))
        let kept = await shelf.kept(["m0", "m1", "m2", "m3"])
        XCTAssertEqual(kept, ["m0", "m2", "m3"])
        await shelf.clear()
        let none = await shelf.kept(["m0", "m2", "m3"])
        XCTAssertTrue(none.isEmpty)
    }

    func testAwayFromTheShopTheKeptPictureIsShown() async {
        let s = ConnectionSettings()
        let saved = (s.host, s.port, s.isPaired, s.isSampleShop)
        defer { s.host = saved.0; s.port = saved.1; s.isPaired = saved.2; s.isSampleShop = saved.3 }
        s.host = "khayt-thumbs.invalid"; s.port = 3219; s.isPaired = true; s.isSampleShop = false
        let api = KhaytAPIClient(settings: s, protocols: [ThumbMac.self])
        api.thumbShelf = LibraryThumbs(directory: dir)

        let first = await api.libraryThumb(id: "PF-1")
        XCTAssertEqual(first, Data("jpeg".utf8))
        XCTAssertEqual(ThumbMac.asked, 1)

        // A new session, away from the shop.
        ThumbMac.reachable = false
        let away = KhaytAPIClient(settings: s, protocols: [ThumbMac.self])
        away.thumbShelf = api.thumbShelf
        let shown = await away.libraryThumb(id: "PF-1")
        XCTAssertEqual(shown, Data("jpeg".utf8))
        XCTAssertEqual(ThumbMac.asked, 1, "sent within the day: not asked again")

        // The Mac says the model has no picture any more.
        ThumbMac.reachable = true
        ThumbMac.hasPicture = false
        await away.thumbShelf.put("PF-1", Data("jpeg".utf8), now: Date().addingTimeInterval(-90_000))
        let fresh = KhaytAPIClient(settings: s, protocols: [ThumbMac.self])
        fresh.thumbShelf = away.thumbShelf
        let none = await fresh.libraryThumb(id: "PF-1")
        XCTAssertNil(none)
        let kept = await fresh.thumbShelf.kept(["PF-1"])
        XCTAssertTrue(kept.isEmpty)
    }
}

/// A Mac serving `GET /api/library/{id}/thumb`, or out of reach.
final class ThumbMac: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reachable = true
    nonisolated(unsafe) static var hasPicture = true
    nonisolated(unsafe) static var asked = 0

    static func reset() { reachable = true; hasPicture = true; asked = 0 }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "khayt-thumbs.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard Self.reachable else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Self.asked += 1
        let ok = Self.hasPicture && request.url?.path() == "/api/library/PF-1/thumb"
        let response = HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": ok ? "image/jpeg" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ok ? Data("jpeg".utf8) : Data(#"{"error":"not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
