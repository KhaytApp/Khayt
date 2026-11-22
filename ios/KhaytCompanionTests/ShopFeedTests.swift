import XCTest
@testable import KhaytCompanion

@MainActor
final class ShopFeedTests: XCTestCase {
    private var url: URL!
    override func setUp() {
        url = FileManager.default.temporaryDirectory.appending(path: "feed-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func item(_ id: String, _ secondsAgo: TimeInterval) -> FeedItem {
        FeedItem(id: id, kind: "x", title: id, at: Date().addingTimeInterval(-secondsAgo), tone: .none,
                 unread: true, orderId: nil)
    }

    func testNewestFirstOnceEachAndItSurvivesARelaunch() {
        let feed = ShopFeed(url: url)
        feed.add(item("old", 600))
        feed.add(item("new", 10))
        feed.add(item("new", 5))
        XCTAssertEqual(feed.items.map(\.id), ["new", "old"])
        XCTAssertEqual(ShopFeed(url: url).items.map(\.id), ["new", "old"], "kept on the phone")
    }

    func testOnlyTheNewestHundredAreKept() {
        let feed = ShopFeed(url: url)
        for i in 0..<120 { feed.add(item("i\(i)", TimeInterval(i))) }
        XCTAssertEqual(feed.items.count, ShopFeed.cap)
        XCTAssertEqual(feed.items.first?.id, "i0")
    }

    func testSeenMeansRead() {
        let feed = ShopFeed(url: url)
        feed.add(item("a", 1)); feed.add(item("b", 2))
        XCTAssertEqual(feed.unreadCount, 2)
        feed.markAllRead()
        XCTAssertEqual(feed.unreadCount, 0)
    }

    /// The cloud's own `intake` carries nothing sealed; a kind the phone does
    /// not describe yet is left out rather than shown as something it is not.
    func testCloudEventsBecomeLinesAndUnknownKindsDoNot() {
        let intake = ShopFeed.item(eventId: "evt:1", kind: "intake", at: "2026-09-26T10:00:00Z",
                                   ciphertext: nil, dek: nil, tr: { $0 })
        XCTAssertEqual(intake?.title, "PUSH_INTAKE")
        XCTAssertEqual(intake?.tone, .attention)
        XCTAssertNil(ShopFeed.item(eventId: "evt:2", kind: "low-stock", at: "2026-09-26T10:00:00Z",
                                   ciphertext: nil, dek: nil, tr: { $0 }))
        XCTAssertNil(ShopFeed.item(eventId: "evt:3", kind: "print-finished", at: "2026-09-26T10:00:00Z",
                                   ciphertext: nil, dek: nil, tr: { $0 }), "no key, no line — not a guessed one")
    }
}
