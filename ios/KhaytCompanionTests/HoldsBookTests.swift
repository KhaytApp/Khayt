import Combine
import XCTest
import KhaytCore
@testable import KhaytCompanion

/// `holdsBook` gates a dozen screens. It was computed from the disk and
/// published nothing, so a book that arrived (a pull, the sample shop) or
/// went (unpair) changed no screen until something else they watched did.
@MainActor
final class HoldsBookTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var settings: ConnectionSettings?
    private var saved: (String, Int, String, String, String, Bool, Bool)?
    private var watching: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "holds-book-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        SettingsMac.reset()
    }

    override func tearDownWithError() throws {
        if let saved, let s = settings {
            (s.host, s.port, s.pin, s.shopLabel, s.serviceName, s.isPaired, s.isSampleShop) = saved
        }
        watching.removeAll()
        UserDefaults.standard.removeObject(forKey: KhaytAPIClient.macSettingsAtKey)
        SyncDiagnostics.forget()
        SettingsMac.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    private func client() -> KhaytAPIClient {
        let s = ConnectionSettings()
        settings = s
        saved = (s.host, s.port, s.pin, s.shopLabel, s.serviceName, s.isPaired, s.isSampleShop)
        s.host = SettingsMac.host; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        return KhaytAPIClient(settings: s, protocols: [SettingsMac.self], book: book)
    }

    /// Every value `$holdsBook` publishes after the subscription's first.
    private func published(_ api: KhaytAPIClient) -> () -> [Bool] {
        var seen: [Bool] = []
        api.$holdsBook.dropFirst().sink { seen.append($0) }.store(in: &watching)
        return { seen }
    }

    private struct Pull: Encodable {
        let whole: Bool
        let scope: BookScope.Taken
        let store: [String: JSONValue]
    }

    private func shop() -> [String: JSONValue] {
        [
            "settings": .object(["shopName": .string("Ward"), "currency": .string("SAR")]),
            "printLog": .array([.object(["id": .string("J-1"), "status": .string("pending"), "project": .string("Vase"),
                                         "date": .string("2026-11-01"), "price": .number(100), "rev": .number(1)])]),
        ]
    }

    func testAPullIntoAnEmptyBookPublishesHoldsBook() async throws {
        let api = client()
        XCTAssertFalse(api.holdsBook)
        let seen = published(api)
        var willChange = 0
        api.objectWillChange.sink { willChange += 1 }.store(in: &watching)

        let taken = BookScope.take(from: shop())
        SettingsMac.store = .reply(200, try JSONEncoder().encode(Pull(whole: false, scope: taken.taken,
                                                                       store: taken.store)))
        let count = try await api.pullBook(into: book)
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(api.holdsBook)
        XCTAssertEqual(seen(), [true], "the change is published once")
        XCTAssertGreaterThan(willChange, 0)
    }

    func testOpeningTheSampleShopPublishesHoldsBook() throws {
        let api = client()
        XCTAssertFalse(api.holdsBook)
        let seen = published(api)
        try api.openSampleShop()
        XCTAssertTrue(api.holdsBook)
        XCTAssertEqual(seen(), [true])
    }

    func testRefreshSeesABookDeletedOnDisk() throws {
        try book.replace(with: shop(), scope: nil)
        let api = client()
        XCTAssertTrue(api.holdsBook, "a book on disk at launch is held from the start")
        let seen = published(api)
        book.forget()
        XCTAssertTrue(api.holdsBook, "nothing has asked yet")
        XCTAssertFalse(api.holdsBookOnDisk)
        api.refreshHoldsBook()
        XCTAssertFalse(api.holdsBook)
        api.refreshHoldsBook()
        XCTAssertEqual(seen(), [false], "a refresh with no change publishes nothing")
    }
}
