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

    private func picture(_ side: Int) -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return r.pngData { ctx in UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side)) }
    }

    func testAKeptPictureIsASmallCopy() throws {
        let big = picture(1024)
        let small = try XCTUnwrap(LibraryThumbs.shrink(big))
        let image = try XCTUnwrap(UIImage(data: small))
        XCTAssertEqual(max(image.size.width * image.scale, image.size.height * image.scale), 320)
        XCTAssertLessThan(small.count, big.count)
        XCTAssertNil(LibraryThumbs.shrink(Data("not a picture".utf8)))
    }

    func testOnTheShopsWiFiEveryPictureIsKeptOnce() async {
        let s = ConnectionSettings()
        let saved = (s.host, s.port, s.isPaired, s.isSampleShop)
        defer { s.host = saved.0; s.port = saved.1; s.isPaired = saved.2; s.isSampleShop = saved.3 }
        s.host = "khayt-thumbs.invalid"; s.port = 3219; s.isPaired = true; s.isSampleShop = false
        let defaults = UserDefaults(suiteName: "pics-\(UUID().uuidString)")!
        ThumbMac.library = (1...5).map { "PF-\($0)" }
        ThumbMac.withPicture = ["PF-1", "PF-2", "PF-4"]
        ThumbMac.image = picture(600)
        let api = KhaytAPIClient(settings: s, protocols: [ThumbMac.self])
        api.thumbShelf = LibraryThumbs(directory: dir)

        let now = Date()
        let fetched = await api.keepAllLibraryPictures(now: now, defaults: defaults)
        XCTAssertEqual(fetched, 3)
        let kept = await api.thumbShelf.kept(ThumbMac.library)
        XCTAssertEqual(kept, ["PF-1", "PF-2", "PF-4"])
        let one = await api.thumbShelf.get("PF-1")
        XCTAssertLessThan(one?.data.count ?? .max, ThumbMac.image.count, "kept small")

        let asked = ThumbMac.asked
        let again = await api.keepAllLibraryPictures(now: now.addingTimeInterval(3600), defaults: defaults)
        XCTAssertEqual(again, 0)
        XCTAssertEqual(ThumbMac.asked, asked, "not again within twelve hours")
    }

    func testEveryFolderIsWalkedAndPicturesTheMacNoLongerListsGo() async {
        let s = ConnectionSettings()
        let saved = (s.host, s.port, s.isPaired, s.isSampleShop)
        defer { s.host = saved.0; s.port = saved.1; s.isPaired = saved.2; s.isSampleShop = saved.3 }
        s.host = "khayt-thumbs.invalid"; s.port = 3219; s.isPaired = true; s.isSampleShop = false
        let defaults = UserDefaults(suiteName: "pics-\(UUID().uuidString)")!
        ThumbMac.library = ["PF-top", "PF-toy", "PF-car", "PF-deep"]
        ThumbMac.folderOf = ["PF-toy": "Toys", "PF-car": "Toys/Cars", "PF-deep": "Home/Kitchen/Hooks"]
        ThumbMac.withPicture = Set(ThumbMac.library)
        ThumbMac.image = picture(400)
        let api = KhaytAPIClient(settings: s, protocols: [ThumbMac.self], withBook: false)
        api.thumbShelf = LibraryThumbs(directory: dir)
        // Kept before the model was archived on the Mac, which lists it no more.
        await api.thumbShelf.put("PF-archived", Data([1, 2, 3]))

        let fetched = await api.keepAllLibraryPictures(now: Date(), defaults: defaults)
        XCTAssertEqual(fetched, 4, "the models in folders too, not only the top folder's")
        let kept = await api.thumbShelf.kept(ThumbMac.library + ["PF-archived"])
        XCTAssertEqual(kept, Set(ThumbMac.library))
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
    /// A library to page through, and which of it has a picture.
    nonisolated(unsafe) static var library: [String] = []
    nonisolated(unsafe) static var withPicture: Set<String> = []
    /// Each model's folder; none is the top folder.
    nonisolated(unsafe) static var folderOf: [String: String] = [:]
    nonisolated(unsafe) static var image = Data("jpeg".utf8)

    static func reset() { reachable = true; hasPicture = true; asked = 0; library = []; withPicture = []; folderOf = [:]; image = Data("jpeg".utf8) }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "khayt-thumbs.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard Self.reachable else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Self.asked += 1
        let path = request.url?.path() ?? ""
        if path == "/api/library" {
            // As the Mac answers with no search: one folder's models, and the
            // folders directly under it (`Shop.libraryPage`).
            let here = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "folder" }?.value ?? ""
            let models = Self.library.filter { (Self.folderOf[$0] ?? "") == here }
            let prefix = here.isEmpty ? "" : here + "/"
            let under = Set(Self.library.compactMap { id -> String? in
                let f = Self.folderOf[id] ?? ""
                guard !f.isEmpty, f != here, f.hasPrefix(prefix) else { return nil }
                return prefix + (f.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? "")
            }).sorted()
            let folders = under.map { #"{"path":"\#($0)","name":"\#($0.split(separator: "/").last ?? "")","count":1}"# }
            let items = models.map { #"{"id":"\#($0)","name":"\#($0)","thumb":\#(Self.withPicture.contains($0))}"# }
            let body = #"{"total":\#(models.count),"offset":0,"folders":[\#(folders.joined(separator: ","))],"items":[\#(items.joined(separator: ","))]}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if !Self.library.isEmpty {
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            let has = Self.withPicture.contains(id)
            let response = HTTPURLResponse(url: request.url!, statusCode: has ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: has ? Self.image : Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let ok = Self.hasPicture && path == "/api/library/PF-1/thumb"
        let response = HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": ok ? "image/jpeg" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ok ? Data("jpeg".utf8) : Data(#"{"error":"not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
