import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The app icon's number is Home's "Needs you" count (Turki, Nov 13).
@MainActor
final class ShopBadgeTests: XCTestCase {
    private var dir: URL!
    private var settings: ConnectionSettings!
    private var savedSample = false
    private var shown: [Int] = []

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "badge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = ConnectionSettings()
        savedSample = settings.isSampleShop
        settings.isSampleShop = false
        shown = []
        PushRegistration.save(token: nil)
    }

    override func tearDown() {
        settings.isSampleShop = savedSample
        try? FileManager.default.removeItem(at: dir)
    }

    private func badge(for store: [String: JSONValue]) throws -> (ShopBadge, KhaytAPIClient) {
        let book = CompanionBook(directory: dir)
        try book.replace(with: store, scope: nil)
        let api = KhaytAPIClient(settings: settings, book: book)
        let b = ShopBadge()
        b.directory = { [dir] in dir }
        b.apply = { [weak self] n in self?.shown.append(n) }
        b.start(api: api)
        return (b, api)
    }

    func testTheBadgeIsTheNeedsYouCount() async throws {
        let (b, api) = try badge(for: SampleShop.book())
        await b.recompute()
        let queue = try await api.fetchQueue()
        let spools = try await api.fetchInventory()
        let waiting = try await api.fetchWaitingList()
        let quotes = try? await api.fetchRecentOrders(limit: 200, status: OrderStatus.quote.rawValue)
        let expected = NeedsYou.summary(queue: queue, spools: spools, waiting: waiting, quotes: quotes).total
        XCTAssertGreaterThan(expected, 0, "the sample shop has something that needs the owner")
        XCTAssertEqual(b.current, expected)
        XCTAssertEqual(shown.last, expected)
        XCTAssertEqual(AlertIndex.badge(in: dir), expected, "the extension shows the same number")
    }

    func testNothingNeedingYouClearsIt() async throws {
        let (b, api) = try badge(for: ["printLog": .array([]), "inventory": .array([])])
        defer { _ = api }
        await b.set(4)
        await b.recompute()
        XCTAssertEqual(shown, [4, 0])
        XCTAssertEqual(AlertIndex.badge(in: dir), 0)
    }

    func testTheSampleShopShowsNoBadge() async throws {
        let (b, api) = try badge(for: SampleShop.book())
        defer { _ = api }
        settings.isSampleShop = true
        await b.recompute()
        XCTAssertEqual(b.current, 0)
    }

    func testSigningOutClearsIt() async throws {
        let shared = ShopBadge.shared
        let (savedApply, savedDir) = (shared.apply, shared.directory)
        defer { shared.apply = savedApply; shared.directory = savedDir }
        shared.directory = { [dir] in dir }
        shared.apply = { [weak self] n in self?.shown.append(n) }
        await shared.set(3)
        let api = KhaytAPIClient(settings: settings, withBook: false)
        api.setCloudForTesting(CloudSession(url: "https://cloud.test", shopId: "A", token: "t",
                                            dek: Data(count: 32), role: "owner", seenRev: nil))
        api.signOutOfCloud()
        for _ in 0..<20 where shared.current != 0 { await Task.yield() }
        XCTAssertEqual(shared.current, 0)
        XCTAssertEqual(AlertIndex.badge(in: dir), 0)
    }

    /// The job index and the badge share one file; writing one keeps the other.
    func testTheIndexKeepsBothHalves() {
        AlertIndex.write(["A": "printing"], to: dir)
        AlertIndex.setBadge(2, in: dir)
        AlertIndex.write(["A": "post"], to: dir)
        XCTAssertEqual(AlertIndex.badge(in: dir), 2)
        XCTAssertEqual(AlertIndex.status(of: "A", in: dir), "post")
        AlertIndex.setBadge(-1, in: dir)
        XCTAssertEqual(AlertIndex.badge(in: dir), 0, "never negative")
    }

    func testTheRefreshIsAskedForJustAfterMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        let now = ISO8601DateFormatter().date(from: "2026-11-13T15:00:00+03:00")!
        XCTAssertEqual(ShopBadge.nextRefresh(after: now, calendar: cal),
                       ISO8601DateFormatter().date(from: "2026-11-14T00:05:00+03:00")!)
    }

    /// Nothing else may set a badge: no "one more per alert" anywhere.
    func testNothingElseSetsABadge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.path.contains("Tests") } ?? []
        var setters: [String] = []
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            if src.contains("setBadgeCount") || src.contains(".badge = ") || src.contains("applicationIconBadgeNumber") {
                setters.append(f.lastPathComponent)
            }
        }
        XCTAssertEqual(Set(setters), ["ShopBadge.swift", "NotificationService.swift"])
    }
}
