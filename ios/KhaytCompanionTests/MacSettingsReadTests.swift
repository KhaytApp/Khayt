import XCTest
import KhaytCore
@testable import KhaytCompanion

/// A phone that syncs through Khayt Cloud never got the Mac's `settings`
/// (cloud changes carry records only), so a connector installed on the Mac
/// never reached it. After each round it now reads `GET /api/store/settings`
/// from its Mac and puts the result in its book AND its baseline.
@MainActor
final class MacSettingsReadTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private static let sharedEngine = Result { try KhaytEngine() }
    private var engine: KhaytEngine!
    private var settings: ConnectionSettings?
    private var saved: (String, Int, String, Bool, Bool)?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "mac-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        engine = try Self.sharedEngine.get()
        SettingsMac.reset()
        UserDefaults.standard.removeObject(forKey: KhaytAPIClient.macSettingsAtKey)
    }

    override func tearDownWithError() throws {
        if let saved, let s = settings { (s.host, s.port, s.pin, s.isPaired, s.isSampleShop) = saved }
        UserDefaults.standard.removeObject(forKey: KhaytAPIClient.macSettingsAtKey)
        SettingsMac.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    private func client() -> KhaytAPIClient {
        let s = ConnectionSettings()
        settings = s
        saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop)
        s.host = SettingsMac.host; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        return KhaytAPIClient(settings: s, protocols: [SettingsMac.self], book: book)
    }

    // MARK: Fixtures

    private func entries() throws -> [JSONValue] {
        guard case .array(let rows) = SampleShop.sampleConnectors else { throw XCTSkip("no sample connectors") }
        return rows
    }

    private func entry(_ id: String) throws -> [String: JSONValue] {
        for case .object(let e) in try entries() where e["id"] == .string(id) { return e }
        throw XCTSkip("no \(id) sample")
    }

    private func macSettings(plugins: [JSONValue]) -> [String: JSONValue] {
        ["shopName": .string("Ward"), "currency": .string("SAR"), "plugins": .array(plugins)]
    }

    /// A book as a cloud-syncing phone has it: settings without the Mac's
    /// connectors (`plugins`), and one job.
    private func shop(plugins: [JSONValue] = []) -> [String: JSONValue] {
        var s: [String: JSONValue] = ["shopName": .string("Ward"), "currency": .string("SAR")]
        if !plugins.isEmpty { s["plugins"] = .array(plugins) }
        return [
            "settings": .object(s),
            "printLog": .array([.object(["id": .string("J-1"), "status": .string("pending"), "project": .string("Vase"),
                                         "date": .string("2026-11-01"), "price": .number(100), "rev": .number(1)])]),
            "wasteLog": .array([]),
        ]
    }

    private func reply(_ settings: [String: JSONValue]) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(["settings": .object(settings),
                                                   "servedAt": .string("2026-11-09T09:00:00.000Z")]))
    }

    private func bytes() throws -> (Data, Data) {
        (try Data(contentsOf: book.url), try Data(contentsOf: book.baselineURL))
    }

    // MARK: Connectors arrive, go, and turn off

    func testAConnectorAddedOnTheMacAppearsAfterASettingsRead() async throws {
        try book.replace(with: shop(), scope: nil)
        SettingsMac.settings = .reply(200, try reply(macSettings(plugins: try entries())))
        let api = client()
        let before = await api.connectors()
        XCTAssertTrue(before.isEmpty)
        XCTAssertNil(api.macSettingsAt)

        let landed = await api.refreshMacSettings(into: book)
        XCTAssertTrue(landed)
        let after = await api.connectors()
        XCTAssertEqual(Set(after.map(\.id)), [SampleShop.lamhaId, "app.khayt.samples.slack"])
        XCTAssertEqual(after.first { $0.id == SampleShop.lamhaId }?.status, .active)
        XCTAssertNotNil(api.macSettingsAt, "a settings read is the Mac's contact")
        XCTAssertNotNil(UserDefaults.standard.object(forKey: KhaytAPIClient.macSettingsAtKey), "kept across launches")
        XCTAssertEqual(SettingsMac.asked, ["/api/store/settings"])
        XCTAssertNotNil(SettingsMac.lastAuth, "the same PIN or signature as /api/store")
        // Records untouched.
        XCTAssertEqual(try book.read()["printLog"], shop()["printLog"])
    }

    func testAConnectorRemovedOnTheMacDisappears() async throws {
        try book.replace(with: shop(plugins: try entries()), scope: nil)
        SettingsMac.settings = .reply(200, try reply(macSettings(plugins: [.object(try entry("app.khayt.samples.slack"))])))
        let api = client()
        let before = await api.connectors()
        XCTAssertEqual(before.count, 2)
        await api.refreshMacSettings(into: book)
        let after = await api.connectors()
        XCTAssertEqual(after.map(\.id), ["app.khayt.samples.slack"])
    }

    func testAConnectorTurnedOffOnTheMacShowsOff() async throws {
        try book.replace(with: shop(plugins: try entries()), scope: nil)
        var lamha = try entry(SampleShop.lamhaId)
        lamha["enabled"] = .bool(false)
        SettingsMac.settings = .reply(200, try reply(macSettings(plugins: [.object(lamha)])))
        let api = client()
        await api.refreshMacSettings(into: book)
        let after = await api.connectors()
        XCTAssertEqual(after.first { $0.id == SampleShop.lamhaId }?.status, .off)
        XCTAssertEqual(after.first { $0.id == SampleShop.lamhaId }?.isActive, false)
    }

    // MARK: Failures leave the book alone

    func testA404A500AndNoAnswerLeaveTheBookByteIdentical() async throws {
        try book.replace(with: shop(plugins: try entries()), scope: nil)
        let api = client()
        let failures: [SettingsMac.Answer] = [
            .reply(404, Data(#"{"error":"Not found"}"#.utf8)),
            .reply(500, Data(#"{"error":"Could not read the settings"}"#.utf8)),
            .fail,
        ]
        for failure in failures {
            let before = try bytes()
            SettingsMac.settings = failure
            let landed = await api.refreshMacSettings(into: book)
            XCTAssertFalse(landed, "\(failure)")
            let after = try bytes()
            XCTAssertEqual(after.0, before.0, "the book changed on \(failure)")
            XCTAssertEqual(after.1, before.1, "the baseline changed on \(failure)")
            XCTAssertNil(api.macSettingsAt, "no contact recorded on \(failure)")
        }
    }

    func testAnEmptySettingsReplyIsIgnored() async throws {
        try book.replace(with: shop(plugins: try entries()), scope: nil)
        let api = client()
        for body in [#"{"settings":{},"servedAt":"2026-11-09T09:00:00.000Z"}"#, #"{}"#, #"{"settings":null}"#] {
            let before = try bytes()
            SettingsMac.settings = .reply(200, Data(body.utf8))
            let landed = await api.refreshMacSettings(into: book)
            XCTAssertFalse(landed, body)
            XCTAssertEqual(try bytes().0, before.0, "nothing replaced something: \(body)")
            XCTAssertEqual(try bytes().1, before.1, body)
        }
        let still = await api.connectors()
        XCTAssertEqual(still.count, 2)
    }

    func testAReplyWithoutServedAtIsRead() async throws {
        try book.replace(with: shop(), scope: nil)
        let body = try JSONEncoder().encode(JSONValue.object(["settings": .object(macSettings(plugins: try entries()))]))
        SettingsMac.settings = .reply(200, body)
        let api = client()
        let fetched = try await api.fetchMacSettings()
        XCTAssertEqual(fetched["currency"], .string("SAR"))
    }

    // MARK: Pending edits, and nothing pending made

    func testPendingEditsSurviveAndTheSettingsWriteIsNotPending() async throws {
        try book.replace(with: shop(), scope: nil)
        try book.appendRecord(collection: "wasteLog",
                              record: ["id": .string("W-1"), "grams": .number(12), "date": .string("2026-11-09")])
        let reader = BookReader(book: book)
        let pendingBefore = try await reader.pendingChanges()
        XCTAssertEqual(pendingBefore?.count, 1)

        SettingsMac.settings = .reply(200, try reply(macSettings(plugins: try entries())))
        let api = client()
        let landed = await api.refreshMacSettings(into: book)
        XCTAssertTrue(landed)

        let pendingAfter = try await reader.pendingChanges()
        XCTAssertEqual(pendingAfter?.count, 1, "the edit is still waiting, and nothing else is")
        guard case .array(let waste)? = try book.read()["wasteLog"] else { return XCTFail("no wasteLog") }
        XCTAssertEqual(waste.count, 1, "the edit survived the write")
        XCTAssertEqual(book.baseline()?["settings"], .object(macSettings(plugins: try entries())),
                       "the baseline holds the Mac's settings too")
        XCTAssertEqual(try book.read()["settings"], book.baseline()?["settings"])
        guard case .array(let base)? = book.baseline()?["wasteLog"] else { return XCTFail("no baseline wasteLog") }
        XCTAssertTrue(base.isEmpty, "the baseline did not swallow the pending edit")
    }

    func testASettingsWriteOnACleanBookLeavesNothingToSend() async throws {
        try book.replace(with: shop(), scope: nil)
        XCTAssertTrue(try book.adoptSettings(macSettings(plugins: try entries())))
        let outbox = try await BookReader.outbox(engine, local: try book.read(), server: try XCTUnwrap(book.baseline()))
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertFalse(outbox.settingsDiffer)
    }

    // MARK: The premise: the phone never sends settings

    /// Both of the phone's senders — `sendPendingChanges` to the Mac's
    /// `/api/store/deltas` and `CloudSync.push` — send `BookReader.outbox`'s
    /// `wire`. Even with the book's settings differing from the baseline's,
    /// that holds no settings and no delta.
    func testNoOutboxThePhoneSendsCarriesSettings() async throws {
        try book.replace(with: shop(), scope: nil)
        try book.adoptSettings(macSettings(plugins: try entries()))
        // Settings that differ between the book and the baseline (as if
        // changed here): still nothing to send.
        try book.replaceBaseline(with: shop())
        let outbox = try await BookReader.outbox(engine, local: try book.read(), server: try XCTUnwrap(book.baseline()))
        XCTAssertTrue(outbox.isEmpty, "a settings difference became a delta")
        XCTAssertEqual(outbox.count, 0)
        XCTAssertTrue(outbox.settingsDiffer, "the engine sees the difference, and has nowhere to put it")
        XCTAssertEqual(Set(outbox.wire.keys), ["deltas", "tombstones", "cursor"])
        XCTAssertNil(outbox.wire["settings"])
        let wire = String(decoding: try JSONEncoder().encode(JSONValue.object(outbox.wire)), as: UTF8.self)
        XCTAssertFalse(wire.contains("\"settings\""), wire)

        // And the Mac send itself: nothing to send means no request at all.
        let api = client()
        let sent = try await api.sendPendingChanges()
        XCTAssertNil(sent)
        XCTAssertFalse(SettingsMac.asked.contains("/api/store/deltas"))
    }

    /// No phone source writes the store's `settings` key except the one place
    /// that takes the Mac's copy (`CompanionBook.adoptSettings`).
    func testOnlyAdoptSettingsWritesTheSettingsKey() throws {
        let services = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Services")
        let files = try FileManager.default.contentsOfDirectory(at: services, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "the scan found the sources")
        let write = try NSRegularExpression(pattern: #"\["settings"\]\s*=[^=]"#)
        var writers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = write.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if hits > 0 { writers.append("\(file.lastPathComponent):\(hits)") }
        }
        XCTAssertEqual(writers, ["CompanionBook.swift:2"],
                       "something on the phone writes settings into the store; it must never travel")
    }

    // MARK: When it is asked

    func testItIsNotAskedWhenTheWholeBookCameDownInTheSameRound() async throws {
        try book.replace(with: shop(), scope: nil)
        let api = client()
        guard api.cloud == nil else { throw XCTSkip("this simulator holds a cloud sign-in") }
        let whole = shop(plugins: try entries())
        let taken = BookScope.take(from: whole)
        let envelope = try JSONEncoder().encode(Pull(whole: false, scope: taken.taken, store: taken.store))
        SettingsMac.store = .reply(200, envelope)
        SettingsMac.settings = .reply(200, try reply(macSettings(plugins: [])))
        await api.refreshEverywhere(book)
        XCTAssertTrue(SettingsMac.asked.contains("/api/store"))
        XCTAssertFalse(SettingsMac.asked.contains("/api/store/settings"), "the pull already brought the settings")
        XCTAssertNotNil(api.macSettingsAt, "a whole pull is the Mac's contact too")
        let after = await api.connectors()
        XCTAssertEqual(after.count, 2)
    }

    func testItIsAskedWhenTheBookDidNotComeFromTheMac() async throws {
        try book.replace(with: shop(), scope: nil)
        let api = client()
        guard api.cloud == nil else { throw XCTSkip("this simulator holds a cloud sign-in") }
        SettingsMac.store = .reply(500, Data(#"{"error":"busy"}"#.utf8))
        SettingsMac.settings = .reply(200, try reply(macSettings(plugins: try entries())))
        await api.refreshEverywhere(book)
        XCTAssertEqual(SettingsMac.asked.filter { $0 == "/api/store/settings" }.count, 1)
        let after = await api.connectors()
        XCTAssertEqual(after.count, 2)
    }

    /// What hid Lamha on a re-paired phone: a WHOLE cloud pull (cold — no
    /// seenRev, no library copy) adopts the cloud's store, whose settings
    /// hold no plugins. The settings read that follows the cloud round in
    /// `refreshEverywhere` puts the Mac's back.
    func testAWholeCloudPullLosesThePluginsAndTheSettingsReadBringsThemBack() async throws {
        try book.replace(with: shop(plugins: try entries()), scope: nil)
        let api = client()
        let had = await api.connectors()
        XCTAssertEqual(had.count, 2)

        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let cloud = CloudSyncTests.FakeCloud(dek: key)
        try cloud.setBase(shop(), rev: 3)
        var sync = CloudSync(book: book, engine: engine)
        sync.fetch = { try cloud.answer($0) }
        let session = CloudSession(url: "https://cloud.test", shopId: "shop_1", token: "tok",
                                   dek: key, role: "owner", seenRev: nil)
        let (_, pulled) = try await sync.pull(session)
        guard case .whole = pulled else { return XCTFail("expected a whole pull, got \(pulled)") }
        let lost = await api.connectors()
        XCTAssertTrue(lost.isEmpty, "the cloud's settings carry no plugins")

        SettingsMac.settings = .reply(200, try reply(macSettings(plugins: try entries())))
        let landed = await api.refreshMacSettings(into: book)
        XCTAssertTrue(landed)
        let back = await api.connectors()
        XCTAssertEqual(Set(back.map(\.id)), [SampleShop.lamhaId, "app.khayt.samples.slack"])
        let outbox = try await BookReader.outbox(engine, local: try book.read(), server: try XCTUnwrap(book.baseline()))
        XCTAssertTrue(outbox.isEmpty, "the Mac's settings read as agreed, not pending")
    }

    private struct Pull: Encodable {
        let whole: Bool
        let scope: BookScope.Taken
        let store: [String: JSONValue]
    }

    // MARK: The hint

    func testTheMacHintShowsOnlyAfterLaunchToACloudPhoneThatNeverReachedItsMac() {
        func shows(_ launched: Bool, _ cloud: Bool, _ at: Date?, _ empty: Bool, _ book: Bool) -> Bool {
            ConnectorLaunch.showsMacHint(launched: launched, cloud: cloud, macSettingsAt: at,
                                         connectorsEmpty: empty, holdsBook: book)
        }
        XCTAssertTrue(shows(true, true, nil, true, true))
        XCTAssertFalse(shows(false, true, nil, true, true), "before launch: nothing connector-related")
        XCTAssertFalse(shows(true, false, nil, true, true), "a phone that reads the Mac's book has its settings")
        XCTAssertFalse(shows(true, true, Date(), true, true), "the Mac's settings were read once")
        XCTAssertFalse(shows(true, true, nil, false, true), "never over a connector list")
        XCTAssertFalse(shows(true, true, nil, true, false), "no book, no Settings section")
        XCTAssertFalse(ConnectorLaunch.showsMacHint(cloud: true, macSettingsAt: nil, connectorsEmpty: true, holdsBook: true),
                       "gated off until launch day, with the shipped switch")
    }
}

/// A Mac answering `/api/store` and `/api/store/settings` as each test says.
final class SettingsMac: URLProtocol, @unchecked Sendable {
    enum Answer: CustomStringConvertible {
        case reply(Int, Data)
        case fail
        var description: String {
            switch self {
            case .reply(let code, _): return "HTTP \(code)"
            case .fail: return "no answer"
            }
        }
    }

    static let host = "khayt-settings.invalid"
    nonisolated(unsafe) static var settings: Answer = .reply(404, Data())
    nonisolated(unsafe) static var store: Answer = .reply(404, Data())
    nonisolated(unsafe) static var asked: [String] = []
    nonisolated(unsafe) static var lastAuth: String?

    static func reset() {
        settings = .reply(404, Data()); store = .reply(404, Data()); asked = []; lastAuth = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.asked.append(path)
        if path == "/api/store/settings" {
            Self.lastAuth = request.value(forHTTPHeaderField: "x-khayt-pin")
                ?? request.value(forHTTPHeaderField: "Authorization")
                ?? request.allHTTPHeaderFields?.first { $0.key.lowercased().hasPrefix("x-khayt") }?.value
        }
        let answer: Answer = path == "/api/store/settings" ? Self.settings
            : path == "/api/store" ? Self.store : .reply(404, Data())
        switch answer {
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .reply(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
