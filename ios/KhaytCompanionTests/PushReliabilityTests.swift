import KhaytCore
import UserNotifications
import XCTest
@testable import KhaytCompanion

/// The push review's iPhone fixes (Nov 13): alerts that arrived late, or said
/// the wrong thing, on Turki's phone.
@MainActor
final class PushReliabilityTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "push-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        PushCloud.reset()
        PushRegistration.save(token: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        PushCloud.reset()
        PushRegistration.save(token: nil)
    }

    // MARK: P1 — the extension reads a small index, never the book

    private func job(_ id: String, _ status: String, voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status),
                                      "project": .string(String(repeating: "x", count: 900))]
        if voided { o["voidedAt"] = .string("2026-11-01T00:00:00Z") }
        return .object(o)
    }

    func testTheBookWritesAnIndexOnEveryChange() throws {
        let book = CompanionBook(directory: dir)
        try book.replace(with: ["printLog": .array([job("A", "printing"), job("V", "pending", voided: true)])], scope: nil)
        XCTAssertEqual(AlertIndex.status(of: "A", in: dir), "printing")
        XCTAssertNil(AlertIndex.status(of: "V", in: dir), "a voided job is no one's to act on")

        try book.update { root in root["printLog"] = .array([self.job("A", "post")]) }
        XCTAssertEqual(AlertIndex.status(of: "A", in: dir), "post", "an edit on the phone")

        let now = try book.read()
        var next = now; next["printLog"] = .array([job("A", "completed"), job("B", "pending")])
        XCTAssertTrue(try book.swap(from: now, to: next))
        XCTAssertEqual(AlertIndex.status(of: "A", in: dir), "completed", "a merged sync")
        XCTAssertEqual(AlertIndex.status(of: "B", in: dir), "pending")
    }

    /// A real shop's book is 26 MB; a notification service extension may use
    /// about 24. The index for a book of that size must be a small fraction.
    func testTheIndexStaysSmallForABigBook() throws {
        let rows = (0..<20_000).map { job("job-\($0)", "completed") }
        let book = CompanionBook(directory: dir)
        try book.replace(with: ["printLog": .array(rows)], scope: nil)
        let bookSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dir.appending(path: "khayt-store.json").path)[.size] as? Int)
        let indexSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: AlertIndex.url(in: dir).path)[.size] as? Int)
        XCTAssertGreaterThan(bookSize, 15_000_000, "the fixture is the size of a real book")
        XCTAssertLessThan(indexSize, 200_000, "the extension reads a few KB, not the book")
        XCTAssertEqual(AlertIndex.status(of: "job-19999", in: dir), "completed", "the newest jobs are kept")
        XCTAssertNil(AlertIndex.status(of: "job-0", in: dir), "beyond the cap")
    }

    /// The extension must never open the book itself again.
    func testTheExtensionDoesNotReadTheBook() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "KhaytAlerts/NotificationService.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("khayt-store.json"))
        XCTAssertTrue(src.contains("AlertIndex.status"))
    }

    // MARK: Words, digits, interruption level

    private func event(_ outcome: PrintFinished.Outcome, duration: Double? = 8100) -> PrintFinished {
        var e = PrintFinished(at: "2026-11-13T10:20:00Z", machineId: "m1", outcome: outcome)
        e.durationS = duration
        e.machineName = "U1"
        return e
    }

    func testDurationsUseWesternDigitsInArabic() {
        let c = PrintAlertText.content(for: event(.finished), orderStatus: nil,
                                       locale: Locale(identifier: "ar@numbers=latn")) { $0 }
        XCTAssertNil(c.body.range(of: "[٠-٩]", options: .regularExpression), c.body)
        XCTAssertNotNil(c.body.range(of: "2"), c.body)
    }

    /// An ending that arrives late says when the print ended (the Mac now
    /// sends endings noticed while it slept, with `at` the real end).
    func testALateEndingSaysWhenItEnded() {
        let utc = TimeZone(identifier: "UTC")!
        let ended = ISO8601DateFormatter().date(from: "2026-11-13T03:10:00Z")!
        let en = Locale(identifier: "en_US@numbers=latn")
        func body(_ now: Date, _ locale: Locale = en) -> String {
            var e = event(.finished, duration: nil); e.at = "2026-11-13T03:10:00Z"
            return PrintAlertText.content(for: e, orderStatus: nil, locale: locale, now: now, timeZone: utc) { $0 }.body
        }
        XCTAssertEqual(body(ended.addingTimeInterval(60)), "alert.print.a_job · U1", "just now: no time")
        XCTAssertTrue(body(ended.addingTimeInterval(3 * 3600)).hasSuffix("· 3:10\u{202F}AM"), body(ended.addingTimeInterval(3 * 3600)))
        let nextDay = body(ended.addingTimeInterval(22 * 3600))
        XCTAssertTrue(nextDay.contains("Nov 13"), nextDay)
        let ar = body(ended.addingTimeInterval(3 * 3600), Locale(identifier: "ar@numbers=latn"))
        XCTAssertNil(ar.range(of: "[٠-٩]", options: .regularExpression), ar)
        XCTAssertTrue(ar.contains("3:10"), ar)
    }

    func testOnlyAFailedOrCancelledPrintIsTimeSensitive() {
        XCTAssertEqual(PrintAlertText.content(for: event(.finished), orderStatus: nil) { $0 }.interruptionLevel, .active)
        XCTAssertEqual(PrintAlertText.content(for: event(.failed), orderStatus: nil) { $0 }.interruptionLevel, .timeSensitive)
        XCTAssertTrue(KnownPush.isTimeSensitive(kind: "payment"))
        XCTAssertFalse(KnownPush.isTimeSensitive(kind: "overdue"))
    }

    func testARewrittenAlertCarriesItsShop() {
        let c = PrintAlertText.content(for: event(.finished), orderStatus: nil, shopId: "shop_A") { $0 }
        XCTAssertEqual(c.userInfo["shopId"] as? String, "shop_A")
    }

    // MARK: C8 — never a raw key

    func testARawKeyIsRecognisedAndTheGenericLineHasWordsEverywhere() {
        XCTAssertTrue(KnownPush.isRawKey("PUSH_REFUND_ISSUED"))
        XCTAssertFalse(KnownPush.isRawKey("A payment came in"))
        XCTAssertFalse(KnownPush.isRawKey("OK"))
        for lang in AppLanguage.allCases where lang != .system {
            L10n.setLanguage(lang)
            XCTAssertFalse(KnownPush.isRawKey(L10n.tr("PUSH_GENERIC")), "\(lang)")
            XCTAssertNotEqual(L10n.tr("push.not_connected"), "push.not_connected", "\(lang)")
        }
        L10n.setLanguage(.system)
    }

    // MARK: P8 — which pushes the open stream may hold back

    func testOnlyKindsTheStreamSaysAreHeldBack() {
        for kind in ["print-finished", "intake", "overdue", "low-stock", "due-today"] {
            XCTAssertTrue(PrintAlertCenter.streamSays(kind: kind), kind)
        }
        for kind in ["quote-decision", "message", "payment", "something-new"] {
            XCTAssertFalse(PrintAlertCenter.streamSays(kind: kind), kind)
        }
        XCTAssertFalse(PrintAlertCenter.streamSays(kind: nil))
        XCTAssertEqual(PrintAlertCenter.pushKind(["k": ["kind": "payment"]]), "payment")
        XCTAssertEqual(PrintAlertCenter.pushKind(["outcome": "finished", "machineId": "m1"]), "print-finished")
        XCTAssertEqual(PrintAlertCenter.alwaysPushed, ["quote-decision", "message", "payment"])
    }

    // MARK: P2 — a tap never acts on another shop

    func testATapOnAnotherShopsAlertIsRefused() {
        XCTAssertTrue(PrintAlertCenter.belongsHere(["shopId": "A"], signedInShop: "A"))
        XCTAssertFalse(PrintAlertCenter.belongsHere(["shopId": "B"], signedInShop: "A"))
        XCTAssertFalse(PrintAlertCenter.belongsHere(["k": ["shopId": "B"]], signedInShop: "A"))
        XCTAssertFalse(PrintAlertCenter.belongsHere(["k": ["shopId": "B"]], signedInShop: nil), "signed out")
        XCTAssertTrue(PrintAlertCenter.belongsHere(["orderId": "x"], signedInShop: "A"), "a local alert names no shop")
    }

    // MARK: Live Activity stale date

    func testALiveActivityAlwaysHasAStaleTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PrintActivityPlan.staleDate(endsAt: nil, now: now), now.addingTimeInterval(300), "no estimate")
        XCTAssertEqual(PrintActivityPlan.staleDate(endsAt: now.addingTimeInterval(-60), now: now),
                       now.addingTimeInterval(300), "an estimate already passed")
        XCTAssertEqual(PrintActivityPlan.staleDate(endsAt: now.addingTimeInterval(3600), now: now),
                       now.addingTimeInterval(3600))
    }

    // MARK: Registration

    private func client() -> KhaytAPIClient {
        let api = KhaytAPIClient(settings: ConnectionSettings(), withBook: false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushCloud.self]
        api.pushSession = URLSession(configuration: config)
        return api
    }

    private func session(_ shop: String) -> CloudSession {
        CloudSession(url: "https://cloud.test", shopId: shop, token: "tok-" + shop,
                     dek: Data(count: 32), role: "owner", seenRev: nil)
    }

    func testARegistrationIsRepeatedOnOpeningUnlessFresh() async {
        let api = client()
        api.setCloudForTesting(session("A"))
        defer { api.setCloudForTesting(nil) }
        let t0 = Date()
        await api.didReceivePushToken(Data([1, 2, 3]))
        XCTAssertEqual(PushCloud.posts, ["/v1/shops/A/push/apns"])
        XCTAssertTrue(api.receivesPush)
        await api.refreshPushRegistration(now: t0.addingTimeInterval(60))
        XCTAssertEqual(PushCloud.posts.count, 1, "fresh: not again within minutes")
        await api.refreshPushRegistration(force: true, now: t0.addingTimeInterval(61))
        XCTAssertEqual(PushCloud.posts.count, 2, "alerts allowed again: at once")
        await api.refreshPushRegistration(now: t0.addingTimeInterval(PushRegistration.fresh + 120))
        XCTAssertEqual(PushCloud.posts.count, 3, "stale: again")
    }

    func testARefusedRegistrationIsSaidQuietly() async {
        PushCloud.status = 500
        let api = client()
        api.setCloudForTesting(session("A"))
        defer { api.setCloudForTesting(nil) }
        await api.didReceivePushToken(Data([1, 2, 3]))
        XCTAssertNotNil(api.pushProblem)
        XCTAssertFalse(api.receivesPush)
        PushCloud.status = 201
        await api.refreshPushRegistration()
        XCTAssertNil(api.pushProblem, "the next opening that works clears it")
    }

    func testTheTokenIsKeptForASignOutBeforeIOSHandsItOverAgain() async {
        let first = client()
        first.setCloudForTesting(session("A"))
        await first.didReceivePushToken(Data([0xAB, 0xCD]))
        first.setCloudForTesting(nil)
        // A new launch: iOS has not handed the token over yet.
        let api = client()
        await api.unregisterForPush(session("A"))
        XCTAssertEqual(PushCloud.deletes, ["/v1/shops/A/push/apns/abcd"])
    }
}

/// Khayt Cloud's push routes, counting what the phone asked.
final class PushCloud: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var posts: [String] = []
    nonisolated(unsafe) static var deletes: [String] = []

    static func reset() { status = 201; posts = []; deletes = [] }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cloud.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        if request.httpMethod == "DELETE" { Self.deletes.append(path) } else { Self.posts.append(path) }
        let code = request.httpMethod == "DELETE" ? 204 : Self.status
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
