import XCTest
@testable import KhaytCompanion

/// Unpairing takes what the shop left outside the book: the feed, the
/// widget's snapshot, and the papers and model files in the temporary folder.
@MainActor
final class UnpairLeavesNothingTests: XCTestCase {

    func testTheShopsPapersAndQuotedFilesLeaveTheTemporaryFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "traces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["khayt-paper-1", "quote-2", "someone-elses"] {
            let sub = dir.appending(path: name)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: sub.appending(path: "f.pdf"))
        }
        XCTAssertEqual(ShopTraces.removeTempCopies(in: dir), 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        XCTAssertEqual(left, ["someone-elses"], "only the app's own folders go")
    }

    func testTheFeedForgetsItsItemsAndItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "feed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let feed = ShopFeed(url: url)
        feed.add(FeedItem(id: "e1", kind: "print", title: "Done", at: Date(), tone: .done, unread: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        feed.clear()
        XCTAssertTrue(feed.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        XCTAssertTrue(ShopFeed(url: url).items.isEmpty, "nothing comes back on the next launch")
    }

    func testTheWidgetSnapshotIsCleared() {
        WidgetSnapshotStore.save(WidgetSnapshot(shopName: "Shop", queued: 1, printing: 0, post: 0, qc: 0, completedToday: 0,
                                                connected: true, updatedAt: Date(), prints: nil))
        XCTAssertNotNil(WidgetSnapshotStore.load())
        WidgetSnapshotStore.clear()
        XCTAssertNil(WidgetSnapshotStore.load())
    }

    /// The source of `KhaytAPIClient.unpair()` still calls the sweep.
    func testUnpairCallsTheSweep() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Services/KhaytAPIClient.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "    func unpair() {"))
        let body = text[start.lowerBound...].prefix(800)
        XCTAssertTrue(body.contains("ShopTraces.forget()"))
    }
}
