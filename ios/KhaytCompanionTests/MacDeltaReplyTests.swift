import XCTest
import KhaytCore
@testable import KhaytCompanion

/// A send the Mac answered 200 is delivered only if the Mac says it took it
/// all. The Mac's `POST /api/store/deltas` counts a change to a collection it
/// does not take from a phone as skipped, with a 200 — and the phone marked it
/// synced, so the edit was lost without a word.
@MainActor
final class MacDeltaReplyTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "delta-reply-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        DeltaMac.reply = #"{"applied":1,"skipped":0,"removed":0}"#
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTheReplyIsReadForWhatTheMacDidNotTake() {
        XCTAssertEqual(KhaytAPIClient.refusedByMac(Data(#"{"applied":2,"skipped":0,"removed":0}"#.utf8)), 0)
        XCTAssertEqual(KhaytAPIClient.refusedByMac(Data(#"{"applied":0,"skipped":3,"removed":0}"#.utf8)), 3)
        XCTAssertEqual(KhaytAPIClient.refusedByMac(Data(#"{"applied":1,"skipped":2,"dropped":1}"#.utf8)), 1,
                       "a Mac that names what it dropped is taken at its word")
        XCTAssertEqual(KhaytAPIClient.refusedByMac(Data("not json".utf8)), 0)
    }

    private var settings: ConnectionSettings?
    private var saved: (String, Int, String, Bool, Bool)?

    private func client() -> KhaytAPIClient {
        let s = ConnectionSettings()
        settings = s
        saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop)
        s.host = "khayt-deltas.invalid"; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        return KhaytAPIClient(settings: s, protocols: [DeltaMac.self], book: book)
    }

    private func restore() {
        if let saved, let s = settings { (s.host, s.port, s.pin, s.isPaired, s.isSampleShop) = saved }
    }

    private func bookWithOneEdit() throws {
        let shop: [String: JSONValue] = [
            "settings": .object(["currency": .string("SAR")]),
            "wasteLog": .array([]),
        ]
        try book.replace(with: shop, scope: nil)
        try book.appendRecord(collection: "wasteLog",
                              record: ["id": .string("W-1"), "grams": .number(12), "date": .string("2026-11-07")])
    }

    func testChangesTheMacSkippedStayPending() async throws {
        try bookWithOneEdit()
        DeltaMac.reply = #"{"applied":0,"skipped":1,"removed":0}"#
        let api = client()
        defer { restore() }
        do {
            try await api.sendPendingChanges()
            XCTFail("a send the Mac did not take must not read as delivered")
        } catch {}
        XCTAssertEqual(api.pendingCount, 1, "the edit was marked synced although the Mac dropped it")
        XCTAssertNotNil(api.macRefused, "the phone must say the Mac did not take it")
        guard case .array(let rows)? = book.baseline()?["wasteLog"] else { return XCTFail("no baseline") }
        XCTAssertTrue(rows.isEmpty, "the baseline moved past an edit the Mac never took")
    }

    func testChangesTheMacTookAreMarkedSynced() async throws {
        try bookWithOneEdit()
        let api = client()
        defer { restore() }
        let sent = try await api.sendPendingChanges()
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(api.pendingCount, 0)
        XCTAssertNil(api.macRefused)
    }
}

final class DeltaMac: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply = ""
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "khayt-deltas.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
