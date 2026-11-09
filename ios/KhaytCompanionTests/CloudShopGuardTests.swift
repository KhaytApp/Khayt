import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * A whole cloud pull REPLACES the phone's book. A phone paired with a Mac
 * signed in to Khayt Cloud with a different account, whose shop was nearly
 * empty, and its first pull swapped the Mac's book — every job, client and
 * connector — for that one. These pin the two guards in `CloudSync.pull`: a
 * shop that is not the book's, and an empty copy over a book that holds
 * something, are refused with nothing on the phone touched.
 */
@MainActor
final class CloudShopGuardTests: XCTestCase {

    private static let sharedEngine = Result { try KhaytEngine() }
    private static let macShop = "shop_282eb707aa11c3"
    private static let otherShop = "shop_77d0e21ec56f"

    private var dir: URL!
    private var book: CompanionBook!
    private var engine: KhaytEngine!
    private var cloud: CloudSyncTests.FakeCloud!
    private var key: Data!
    private var suite: String!
    private var savedDefaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "shop-guard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        engine = try Self.sharedEngine.get()
        key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        cloud = CloudSyncTests.FakeCloud(dek: key)
        suite = "shop-guard-\(UUID().uuidString)"
        savedDefaults = SyncDiagnostics.defaults
        SyncDiagnostics.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        SyncDiagnostics.defaults.removePersistentDomain(forName: suite)
        SyncDiagnostics.defaults = savedDefaults
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private func session(_ shopId: String, seenRev: Int? = nil) -> CloudSession {
        CloudSession(url: "https://cloud.test", shopId: shopId, token: "tok", dek: key, role: "owner", seenRev: seenRev)
    }

    private func sync() -> CloudSync {
        var s = CloudSync(book: book, engine: engine)
        let fake = cloud!
        s.fetch = { try fake.answer($0) }
        return s
    }

    /// A shop with `orders` open jobs and a client; linked to `shopId` when given.
    private func shop(orders: Int, shopId: String? = nil, email: String? = nil) -> [String: JSONValue] {
        var settings: [String: JSONValue] = ["shopName": .string("Ward"),
                                             "plugins": .array([.object(["id": .string("p1")])])]
        if shopId != nil || email != nil {
            var c: [String: JSONValue] = [:]
            if let shopId { c["shopId"] = .string(shopId) }
            if let email { c["email"] = .string(email) }
            settings["cloud"] = .object(c)
        }
        let log: [JSONValue] = (0..<orders).map {
            .object(["id": .string("O-\($0)"), "status": .string("printing"), "project": .string("Job \($0)"),
                     "date": .string("2026-11-01"), "rev": .number(1)])
        }
        let clients: [JSONValue] = orders > 0 ? [.object(["id": .string("C-1"), "name": .string("Sara"),
                                                          "rev": .number(1)])] : []
        return ["settings": .object(settings), "printLog": .array(log), "inventory": .array([]),
                "clients": .array(clients)]
    }

    /// The Mac's book on the phone: book, baseline, scope and library copy.
    private func macBook(shopId: String? = macShop, email: String? = "turki@gmail.com", orders: Int = 3) throws {
        let taken = BookScope.take(from: shop(orders: orders, shopId: shopId, email: email))
        try book.replace(with: taken.store, scope: taken.taken)
        try book.replaceLibrary([.object(["id": .string("F-1"), "name": .string("Vase")])])
    }

    /// Every file a whole pull would replace, byte for byte.
    private func onDisk() -> [String: Data?] {
        [book.url, book.baselineURL, book.scopeURL, book.libraryURL].reduce(into: [:]) {
            $0[$1.lastPathComponent] = try? Data(contentsOf: $1)
        }
    }

    // MARK: A different shop

    func testADifferentShopIsRefusedAndNothingOnThePhoneChanges() async throws {
        try macBook()
        try cloud.setBase(shop(orders: 0), rev: 1)
        let before = onDisk()
        XCTAssertEqual(before.values.filter { $0 != nil }.count, 4, "book, baseline, scope and library are all there")

        let (s, pulled) = try await sync().pull(session(Self.otherShop))
        XCTAssertEqual(pulled, .refused(.wrongShop(macShop: Self.macShop, email: "t***@g***.com")))
        XCTAssertNil(s.seenRev, "a fresh sign-in stays cold, so nothing can be pushed")
        XCTAssertEqual(onDisk(), before, "the refused pull touched the phone")
    }

    func testARefusalLeavesAnEarlierCursorAsItWas() async throws {
        // Warm cursor, but no scope cut → a whole pull; refused, the cursor stays.
        try book.replace(with: shop(orders: 2, shopId: Self.macShop), scope: nil)
        try cloud.setBase(shop(orders: 5), rev: 9)
        let (s, pulled) = try await sync().pull(session(Self.otherShop, seenRev: 4))
        guard case .refused(.wrongShop) = pulled else { return XCTFail("\(pulled)") }
        XCTAssertEqual(s.seenRev, 4)
    }

    func testTheSameShopIsAdopted() async throws {
        try macBook()
        try cloud.setBase(shop(orders: 5, shopId: Self.macShop), rev: 2)
        let (s, pulled) = try await sync().pull(session(Self.macShop))
        guard case .whole(let n) = pulled else { return XCTFail("\(pulled)") }
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(s.seenRev, 2)
        guard case .array(let log)? = try book.read()["printLog"] else { return XCTFail() }
        XCTAssertEqual(log.count, 5)
    }

    func testABookLinkedToNoShopTakesANonEmptyPull() async throws {
        try macBook(shopId: nil, email: nil)
        try cloud.setBase(shop(orders: 4), rev: 3)
        let (s, pulled) = try await sync().pull(session(Self.otherShop))
        guard case .whole = pulled else { return XCTFail("\(pulled)") }
        XCTAssertEqual(s.seenRev, 3)
    }

    func testPushAfterARefusalSendsNothing() async throws {
        try macBook()
        try await BookWriter(book: book).setOrderStatus(orderId: "O-0", to: "qc", engine: engine)
        let waiting = try await BookReader(book: book).pendingChanges()?.count ?? 0
        XCTAssertEqual(waiting, 1)
        try cloud.setBase(shop(orders: 0), rev: 1)

        let (s, pushed) = try await sync().push(session(Self.otherShop))
        XCTAssertEqual(pushed, .refused(.wrongShop(macShop: Self.macShop, email: "t***@g***.com")))
        XCTAssertNil(s.seenRev)
        XCTAssertFalse(cloud.requests.contains { $0.httpMethod != "GET" }, "something was sent to the other shop")
        XCTAssertTrue(cloud.chain.isEmpty)
        let still = try await BookReader(book: book).pendingChanges()?.count ?? 0
        XCTAssertEqual(still, 1, "the edit stays pending for the Mac")
    }

    // MARK: An empty copy

    func testAnEmptyPullOverABookIsRefusedEvenFromTheSameShop() async throws {
        try macBook()
        try cloud.setBase(shop(orders: 0, shopId: Self.macShop), rev: 1)
        let before = onDisk()
        let (s, pulled) = try await sync().pull(session(Self.macShop))
        XCTAssertEqual(pulled, .refused(.emptyShop))
        XCTAssertNil(s.seenRev)
        XCTAssertEqual(onDisk(), before)
    }

    func testAnEmptyPullOverABookLinkedToNoShopIsRefused() async throws {
        try macBook(shopId: nil, email: nil)
        try cloud.setBase(shop(orders: 0), rev: 1)
        let before = onDisk()
        let (_, pulled) = try await sync().pull(session(Self.otherShop))
        XCTAssertEqual(pulled, .refused(.emptyShop))
        XCTAssertEqual(onDisk(), before)
    }

    func testAnEmptyPullOntoNoBookIsAdopted() async throws {
        XCTAssertFalse(book.exists)
        try cloud.setBase(shop(orders: 0), rev: 1)
        let (s, pulled) = try await sync().pull(session(Self.otherShop))
        XCTAssertEqual(pulled, .whole(records: 0))
        XCTAssertEqual(s.seenRev, 1)
        XCTAssertTrue(book.exists)
    }

    func testAnEmptyPullOntoAnEmptyBookIsAdopted() async throws {
        try book.replace(with: shop(orders: 0), scope: nil)
        try cloud.setBase(shop(orders: 0), rev: 1)
        let (s, pulled) = try await sync().pull(session(Self.otherShop))
        XCTAssertEqual(pulled, .whole(records: 0))
        XCTAssertEqual(s.seenRev, 1)
    }

    // MARK: "Use this shop instead"

    func testTheOverrideAdoptsOnceAndIsSpent() async throws {
        try macBook()
        try cloud.setBase(shop(orders: 2), rev: 6)
        var chosen = session(Self.otherShop)
        chosen.adoptOtherShop = true
        let (s, pulled) = try await sync().pull(chosen)
        guard case .whole = pulled else { return XCTFail("the override was ignored: \(pulled)") }
        XCTAssertFalse(s.adoptOtherShop, "the override outlived its pull")

        // The same choice is not there for the next sign-in's first pull.
        try macBook()
        var again = s
        again.seenRev = nil
        let (_, second) = try await sync().pull(again)
        guard case .refused(.wrongShop) = second else { return XCTFail("\(second)") }
    }

    func testTheOverrideIsPersistedUntilThePull() {
        let defaults = UserDefaults(suiteName: "shop-guard-session-\(UUID().uuidString)")!
        var s = session(Self.otherShop)
        s.adoptOtherShop = true
        // `save` puts the token and key in the Keychain; keep what is there.
        let held = CloudSession.load()
        defer { CloudSession.forget(); held?.save() }
        s.save(defaults: defaults)
        XCTAssertEqual(CloudSession.load(defaults: defaults)?.adoptOtherShop, true)
        s.adoptOtherShop = false
        s.save(defaults: defaults)
        XCTAssertEqual(CloudSession.load(defaults: defaults)?.adoptOtherShop, false)
    }

    /// Offered only with no Mac paired; a paired phone signs in with the
    /// Mac's account or unpairs.
    func testTheOverrideIsOnlyForAPhoneWithNoMac() {
        let defaults = UserDefaults.standard
        let keys = ["khayt.host", "khayt.port", "khayt.paired", "khayt.sampleShop"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let held = CloudSession.load()
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            CloudSession.forget()
            held?.save()
        }
        session(Self.otherShop).save()

        let paired = ConnectionSettings()
        paired.host = "192.168.1.20"; paired.port = 3219
        let withMac = KhaytAPIClient(settings: paired, withBook: false)
        XCTAssertTrue(paired.isConfigured)
        XCTAssertFalse(withMac.mayAdoptOtherShop)
        XCTAssertFalse(withMac.useThisCloudShop())
        XCTAssertEqual(withMac.cloud?.adoptOtherShop, false)
        XCTAssertEqual(CloudSession.load()?.adoptOtherShop, false)

        let alone = ConnectionSettings()
        alone.host = ""
        let noMac = KhaytAPIClient(settings: alone, withBook: false)
        XCTAssertFalse(alone.isConfigured)
        XCTAssertTrue(noMac.mayAdoptOtherShop)
        XCTAssertTrue(noMac.useThisCloudShop())
        XCTAssertEqual(noMac.cloud?.adoptOtherShop, true)
        XCTAssertEqual(CloudSession.load()?.adoptOtherShop, true, "kept until the next pull")
    }

    // MARK: The sign-in check

    func testSignInSeesTheBooksShop() throws {
        try macBook()
        let api = KhaytAPIClient(settings: ConnectionSettings(), protocols: [], book: book)
        XCTAssertEqual(api.signedInToAnotherShop(session(Self.otherShop)),
                       .wrongShop(macShop: Self.macShop, email: "t***@g***.com"))
        XCTAssertNil(api.signedInToAnotherShop(session(Self.macShop)))
    }

    // MARK: Words

    func testTheEmailIsOnlyAHint() {
        XCTAssertEqual(CloudSync.maskedEmail("turki@gmail.com"), "t***@g***.com")
        XCTAssertEqual(CloudSync.maskedEmail("a.b@mail.example.co.uk"), "a***@m***.uk")
        XCTAssertEqual(CloudSync.maskedEmail("  x@y.io "), "x***@y***.io")
        XCTAssertNil(CloudSync.maskedEmail(nil))
        XCTAssertNil(CloudSync.maskedEmail(""))
        XCTAssertNil(CloudSync.maskedEmail("__KHAYT_MASKED__"))
        XCTAssertNil(CloudSync.maskedEmail("not-an-address"))
        XCTAssertNil(CloudSync.maskedEmail("x@localhost"))
        XCTAssertNil(CloudSync.maskedEmail("@gmail.com"))
    }

    func testAMaskedOrAbsentEmailNamesNoAccount() {
        let masked = shop(orders: 1, shopId: Self.macShop, email: "__KHAYT_MASKED__")
        XCTAssertEqual(CloudSync.shopRefusal(book: masked, cloudShop: Self.otherShop),
                       .wrongShop(macShop: Self.macShop, email: nil))
        let absent = shop(orders: 1, shopId: Self.macShop)
        XCTAssertEqual(CloudSync.shopRefusal(book: absent, cloudShop: Self.otherShop),
                       .wrongShop(macShop: Self.macShop, email: nil))
        XCTAssertNil(CloudSync.shopRefusal(book: absent, cloudShop: Self.macShop))
        XCTAssertNil(CloudSync.shopRefusal(book: shop(orders: 1), cloudShop: Self.otherShop))
    }

    func testARefusalIsSaidWithTheAccountWhenThereIsOne() {
        let named = KhaytAPIClient.refusalText(.wrongShop(macShop: Self.macShop, email: "t***@g***.com"))
        XCTAssertEqual(named, L10n.format("cloud.wrong_shop.as", "t***@g***.com"))
        XCTAssertTrue(named.contains("t***@g***.com"))
        XCTAssertFalse(named.contains(Self.macShop), "the shop id is not for the screen")
        XCTAssertEqual(KhaytAPIClient.refusalText(.wrongShop(macShop: Self.macShop, email: nil)),
                       L10n.tr("cloud.wrong_shop"))
        XCTAssertEqual(KhaytAPIClient.refusalText(.emptyShop), L10n.tr("cloud.empty_shop"))
        for key in ["cloud.wrong_shop.as", "cloud.wrong_shop", "cloud.empty_shop"] {
            XCTAssertNotEqual(L10n.tr(key), key, "\(key) is missing")
        }
    }

    // MARK: Diagnostics

    func testARefusalIsRecordedAndIsNotASource() async throws {
        try macBook()
        try cloud.setBase(shop(orders: 0), rev: 1)
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        _ = try await sync().pull(session(Self.otherShop), now: at)
        var r = SyncDiagnostics.recorded()
        XCTAssertEqual(r.refused, .wrongShop)
        XCTAssertEqual(r.refusedAt, at)
        XCTAssertEqual(r.refusedShopTail, "1ec56f", "the cloud shop's last 6, never the id")
        XCTAssertNil(r.sources[.cloudWhole], "nothing was adopted")
        XCTAssertNil(r.last)

        try macBook(shopId: nil, email: nil)
        _ = try await sync().pull(session(Self.macShop), now: at.addingTimeInterval(60))
        r = SyncDiagnostics.recorded()
        XCTAssertEqual(r.refused, .empty)
        XCTAssertEqual(r.refusedAt, at.addingTimeInterval(60))
        XCTAssertEqual(r.refusedShopTail, "aa11c3")

        let line = DiagnosticsSheet.refusedValue(.wrongShop, when: "now", shopTail: "1ec56f")
        XCTAssertTrue(line.hasPrefix(L10n.tr("diag.refused.wrong_shop")), line)
        XCTAssertTrue(line.hasSuffix("…1ec56f"), line)

        SyncDiagnostics.forget()
        XCTAssertNil(SyncDiagnostics.recorded().refused, "unpair forgets it")
    }
}
