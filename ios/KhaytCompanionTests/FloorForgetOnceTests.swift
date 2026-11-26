import XCTest
import KhaytCore
@testable import KhaytCompanion

/// A phone moved to the floor with edits still unsent keeps its book for
/// them, and the refresh round asks to forget it every time (up to once a
/// minute). The shop's traces outside the book go ONCE per demotion: the
/// forget also deletes the print alerts and reminders posted since, and a
/// floor phone's edits can wait forever (`/api/store/deltas` needs
/// `book:write`, so the Mac refuses them).
@MainActor
final class FloorForgetOnceTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var settings: ConnectionSettings?
    private var saved: (String, Int, String, Bool, Bool, String?, Bool)?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "floor-once-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        UserDefaults.standard.removeObject(forKey: KhaytAPIClient.floorTracesForgottenKey)
    }

    override func tearDownWithError() throws {
        if let saved, let s = settings {
            (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.deviceRole, s.pairedByCode) = saved
        }
        UserDefaults.standard.removeObject(forKey: KhaytAPIClient.floorTracesForgottenKey)
        try? FileManager.default.removeItem(at: dir)
    }

    /// A code-paired operator phone that still holds a book with one unsent edit,
    /// paired to a Mac that refuses everything with 403.
    private func client() async throws -> KhaytAPIClient {
        try book.replace(with: ["settings": .object(["currency": .string("SAR")]), "wasteLog": .array([])], scope: nil)
        try book.appendRecord(collection: "wasteLog",
                              record: ["id": .string("W-1"), "grams": .number(12), "date": .string("2026-11-26")])
        let s = ConnectionSettings()
        settings = s
        saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.deviceRole, s.pairedByCode)
        s.host = FloorRefusingMac.host; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        s.pairedByCode = true
        s.deviceRole = "operator"
        let api = KhaytAPIClient(settings: s, protocols: [FloorRefusingMac.self], book: book)
        await api.refreshPendingCount()
        return api
    }

    func testTwoRoundsWithEditsWaitingForgetTheTracesOnce() async throws {
        let api = try await client()
        var forgets = 0
        api.forgetTraces = { forgets += 1 }
        XCTAssertEqual(api.pendingCount, 1)

        await api.refreshEverywhere(book)
        await api.refreshEverywhere(book)

        XCTAssertEqual(forgets, 1, "the traces go once per demotion, not every round")
        XCTAssertEqual(api.pendingCount, 1, "the Mac refused the edit: still waiting")
        XCTAssertTrue(api.holdsBookOnDisk, "the book stays for its unsent edits")
    }

    func testARaisedPhoneDemotedAgainForgetsAgain() async throws {
        let api = try await client()
        var forgets = 0
        api.forgetTraces = { forgets += 1 }
        api.followRole()
        api.followRole()
        XCTAssertEqual(forgets, 1)
        // Back to manager: it may keep the book, and the next demotion is a new one.
        settings?.deviceRole = "manager"
        api.followRole()
        XCTAssertFalse(api.floorTracesForgotten)
        settings?.deviceRole = "viewer"
        api.followRole()
        api.followRole()
        XCTAssertEqual(forgets, 2)
    }

    /// Unpairing and pairing again start over: a phone paired as floor to
    /// another shop gets its first forget (#2718 review). Source guard, as
    /// pairing needs a real Mac's offer.
    func testUnpairAndPairingClearTheFlag() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Services/KhaytAPIClient.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        for head in ["    func unpair() {", "    func finishCodePairing("] {
            let start = try XCTUnwrap(text.range(of: head), head)
            XCTAssertTrue(text[start.lowerBound...].prefix(1600).contains("floorTracesForgotten = false"), head)
        }
    }
}

/// A Mac that answers 403 to everything: a floor phone's send is refused.
final class FloorRefusingMac: URLProtocol, @unchecked Sendable {
    static let host = "khayt-refusing.invalid"
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"role-scope","required":"book:write"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
