import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Settings ▸ long-press the version ▸ Diagnostics: where the book last came
/// from, how the last Mac settings read went, and when the Mac last answered.
@MainActor
final class SyncDiagnosticsTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var suite: String!
    private var savedDefaults: UserDefaults!
    private var settings: ConnectionSettings?
    private var saved: (String, Int, String, Bool, Bool)?
    private static let sharedEngine = Result { try KhaytEngine() }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "diag-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        suite = "diag-tests-\(UUID().uuidString)"
        savedDefaults = SyncDiagnostics.defaults
        SyncDiagnostics.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SettingsMac.reset()
        UserDefaults.standard.removeObject(forKey: KhaytAPIClient.macSettingsAtKey)
    }

    override func tearDownWithError() throws {
        if let saved, let s = settings { (s.host, s.port, s.pin, s.isPaired, s.isSampleShop) = saved }
        SyncDiagnostics.defaults.removePersistentDomain(forName: suite)
        SyncDiagnostics.defaults = savedDefaults
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

    private func plugins() throws -> [JSONValue] {
        guard case .array(let rows) = SampleShop.sampleConnectors else { throw XCTSkip("no sample connectors") }
        return rows
    }

    private func shop(plugins: [JSONValue] = []) -> [String: JSONValue] {
        var s: [String: JSONValue] = ["shopName": .string("Ward")]
        if !plugins.isEmpty { s["plugins"] = .array(plugins) }
        return ["settings": .object(s),
                "printLog": .array([.object(["id": .string("O-1"), "status": .string("printing"),
                                             "date": .string("2026-11-01"), "rev": .number(1)])]),
                "inventory": .array([]), "clients": .array([])]
    }

    private func settingsReply(_ plugins: [JSONValue]) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(["servedAt": .string("2026-11-09T09:00:00.000Z"),
                                                   "settings": .object(["shopName": .string("Ward"),
                                                                        "plugins": .array(plugins)])]))
    }

    private struct Pull: Encodable {
        let whole: Bool
        let scope: BookScope.Taken
        let store: [String: JSONValue]
    }

    // MARK: Where the book came from

    func testAMacPullRecordsItself() async throws {
        let taken = BookScope.take(from: shop(plugins: try plugins()))
        SettingsMac.store = .reply(200, try JSONEncoder().encode(Pull(whole: false, scope: taken.taken, store: taken.store)))
        let api = client()
        try await api.pullBook(into: book)
        let r = SyncDiagnostics.recorded()
        XCTAssertEqual(r.last, .macStore)
        XCTAssertNotNil(r.sources[.macStore])
        XCTAssertNotNil(r.lastAt)
        XCTAssertNotNil(r.macAnsweredAt, "the Mac answered")
        XCTAssertNil(r.macFailedAt)
    }

    func testAColdAndAWarmCloudPullRecordThemselves() async throws {
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let cloud = CloudSyncTests.FakeCloud(dek: key)
        try cloud.setBase(shop(), rev: 1)
        var sync = CloudSync(book: book, engine: try Self.sharedEngine.get())
        sync.fetch = { try cloud.answer($0) }
        let session = CloudSession(url: "https://cloud.test", shopId: "shop_1", token: "tok",
                                   dek: key, role: "owner", seenRev: nil)
        let (warm, cold) = try await sync.pull(session)
        guard case .whole = cold else { return XCTFail("\(cold)") }
        XCTAssertEqual(SyncDiagnostics.recorded().last, .cloudWhole)
        XCTAssertNil(SyncDiagnostics.recorded().sources[.cloudDelta])

        let (_, changes) = try await sync.pull(warm)
        guard case .changes = changes else { return XCTFail("\(changes)") }
        let r = SyncDiagnostics.recorded()
        XCTAssertEqual(r.last, .cloudDelta, "a warm pull with nothing new still records itself")
        XCTAssertNotNil(r.sources[.cloudWhole], "the last of each kind is kept")
        XCTAssertNotNil(r.sources[.cloudDelta])
    }

    // MARK: The settings read

    func testASettingsReadRecordsItsOutcome() async throws {
        try book.replace(with: shop(), scope: nil)
        let api = client()

        SettingsMac.settings = .reply(404, Data(#"{"error":"Not found"}"#.utf8))
        await api.refreshMacSettings(into: book)
        XCTAssertEqual(SyncDiagnostics.recorded().macSettings, .http(404))

        SettingsMac.settings = .reply(500, Data(#"{"error":"No settings"}"#.utf8))
        await api.refreshMacSettings(into: book)
        XCTAssertEqual(SyncDiagnostics.recorded().macSettings, .http(500))
        XCTAssertNil(SyncDiagnostics.recorded().macFailedAt, "an HTTP error is an answer")
        XCTAssertNotNil(SyncDiagnostics.recorded().macAnsweredAt)

        SettingsMac.settings = .fail
        await api.refreshMacSettings(into: book)
        XCTAssertEqual(SyncDiagnostics.recorded().macSettings, .transport)
        XCTAssertNotNil(SyncDiagnostics.recorded().macFailedAt)

        SettingsMac.settings = .reply(200, Data(#"{"settings":{}}"#.utf8))
        await api.refreshMacSettings(into: book)
        XCTAssertEqual(SyncDiagnostics.recorded().macSettings, .empty)
        XCTAssertNil(SyncDiagnostics.recorded().sources[.macSettings], "no source until settings landed")

        SettingsMac.settings = .reply(200, try settingsReply(try plugins()))
        await api.refreshMacSettings(into: book)
        let r = SyncDiagnostics.recorded()
        XCTAssertEqual(r.macSettings, .ok)
        XCTAssertNotNil(r.macSettingsAt)
        XCTAssertEqual(r.last, .macSettings)
    }

    func testASettingsReadSkippedAfterAWholeMacPullSaysSo() async throws {
        try book.replace(with: shop(), scope: nil)
        let api = client()
        guard api.cloud == nil else { throw XCTSkip("this simulator holds a cloud sign-in") }
        let taken = BookScope.take(from: shop(plugins: try plugins()))
        SettingsMac.store = .reply(200, try JSONEncoder().encode(Pull(whole: false, scope: taken.taken, store: taken.store)))
        await api.refreshNow()
        XCTAssertEqual(SyncDiagnostics.recorded().macSettings, .skipped(.pulled))
        XCTAssertEqual(SyncDiagnostics.recorded().last, .macStore)
    }

    func testOutcomesSurviveTheirStoredForm() {
        let all: [SyncDiagnostics.SettingsOutcome] = [.ok, .http(404), .http(500), .transport, .empty, .unwritten,
                                                       .skipped(.pulled), .skipped(.notConfigured),
                                                       .skipped(.sampleShop), .skipped(.noBook)]
        for o in all { XCTAssertEqual(SyncDiagnostics.SettingsOutcome(stored: o.stored), o, o.stored) }
        XCTAssertNil(SyncDiagnostics.SettingsOutcome(stored: "nonsense"))
    }

    // MARK: Unpair

    func testForgetClearsEverythingRecorded() {
        SyncDiagnostics.record(.macStore)
        SyncDiagnostics.record(.cloudDelta)
        SyncDiagnostics.record(.http(404))
        SyncDiagnostics.macAnswered()
        SyncDiagnostics.macFailed()
        XCTAssertNotEqual(SyncDiagnostics.recorded(), SyncDiagnostics.Recorded())
        SyncDiagnostics.forget()
        XCTAssertEqual(SyncDiagnostics.recorded(), SyncDiagnostics.Recorded())
        for k in SyncDiagnostics.Keys.all { XCTAssertNil(SyncDiagnostics.defaults.object(forKey: k), k) }
    }

    /// Unpair is not run here (it forgets the simulator's own book and
    /// keys), so its source is read, as `UnpairLeavesNothingTests` does.
    func testUnpairForgetsTheDiagnosticsAndTheMacContact() throws {
        let services = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Services")
        let settingsSrc = try String(contentsOf: services.appending(path: "ConnectionSettings.swift"), encoding: .utf8)
        let start = try XCTUnwrap(settingsSrc.range(of: "    func unpair() {"))
        let body = settingsSrc[start.lowerBound...].prefix(2500)
        XCTAssertTrue(body.contains("SyncDiagnostics.forget()"))
        XCTAssertTrue(body.contains("KhaytAPIClient.macSettingsAtKey"))
        let clientSrc = try String(contentsOf: services.appending(path: "KhaytAPIClient.swift"), encoding: .utf8)
        let cStart = try XCTUnwrap(clientSrc.range(of: "    func unpair() {"))
        let cBody = clientSrc[cStart.lowerBound...].prefix(800)
        XCTAssertTrue(cBody.contains("settings.unpair()"))
        XCTAssertTrue(cBody.contains("macSettingsAt = nil"))
    }

    // MARK: The model

    func testTheModelIsCountsAndStatesBuiltFromTheBook() async throws {
        try book.replace(with: shop(plugins: try plugins()), scope: nil)
        let api = client()
        SyncDiagnostics.record(.cloudWhole)
        let d = await api.diagnostics()
        XCTAssertTrue(d.holdsBook)
        XCTAssertTrue(d.bookExists)
        XCTAssertEqual(d.baseline, .held)
        XCTAssertTrue(d.settingsPresent)
        XCTAssertEqual(d.pluginEntries, 2)
        XCTAssertEqual(d.connectorCount, 2)
        XCTAssertEqual(d.byStatus[.active], 1)
        XCTAssertEqual(d.byStatus[.paused], 1)
        XCTAssertEqual(d.recorded.last, .cloudWhole)
        XCTAssertTrue(d.isPaired)
        XCTAssertTrue(d.isConfigured)
        XCTAssertFalse(d.isSampleShop)

        // Built purely, from what it is handed.
        let empty = BookDiagnostics.make(holdsBook: false, book: nil, connectors: [], recorded: .init(),
                                         isPaired: false, isConfigured: false, cloudSignedIn: true, isSampleShop: false,
                                         info: ["CFBundleShortVersionString": "4.1", "CFBundleVersion": "202611091200"])
        XCTAssertFalse(empty.bookExists)
        XCTAssertEqual(empty.baseline, .absent)
        XCTAssertFalse(empty.settingsPresent)
        XCTAssertEqual(empty.pluginEntries, 0)
        XCTAssertTrue(empty.byStatus.isEmpty)
        XCTAssertTrue(empty.cloudSignedIn)
        XCTAssertEqual(empty.version, "4.1")
        XCTAssertEqual(empty.build, "202611091200")
    }

    func testABaselineThatIsMissingSaysSo() throws {
        try book.replace(with: shop(), scope: nil)
        try FileManager.default.removeItem(at: book.baselineURL)
        XCTAssertEqual(BookDiagnostics.book(book).baseline, .absent)
        XCTAssertTrue(BookDiagnostics.book(book).settings)
        XCTAssertEqual(BookDiagnostics.book(book).plugins, 0)
    }
}
