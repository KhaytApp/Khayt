import XCTest
@testable import KhaytCompanion

/**
 * The offline cache, and the line it must not cross.
 *
 * The companion is used away from the desk, which is where Wi-Fi is worst, and
 * until this existed losing the connection meant losing the queue, the orders
 * and the inventory at once. The cache makes those screens survive a walk to the
 * back room.
 *
 * The interesting tests here are not "does it store and load". They are the two
 * rules that decide whether the feature is safe:
 *
 *   - a cached answer must never mask a REAL answer from the desktop. A wrong
 *     PIN or a 500 has to keep surfacing, or the shop reads a broken server as
 *     "fine, just slightly old".
 *   - two different requests must never share a slot. `/api/orders?limit=40`
 *     and `?limit=41` are different questions.
 */
final class CompanionCacheTests: XCTestCase {

    private var dir: URL!
    private var cache: CompanionCache!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("khayt-cache-tests-\(UUID().uuidString)", isDirectory: true)
        cache = CompanionCache(directory: dir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAStoredAnswerComesBack() async throws {
        let orders = [QueueOrder(id: "o1", project: "Bracket", client: "Acme", status: "printing",
                                 machine: nil, machineId: nil, dueDate: nil, priority: nil)]
        await cache.store(orders, for: "/api/queue")

        let loaded = await cache.load([QueueOrder].self, for: "/api/queue")
        XCTAssertEqual(loaded?.value.count, 1)
        XCTAssertEqual(loaded?.value.first?.project, "Bracket")
    }

    func testAnAnswerRemembersWhenItWasTrue() async throws {
        // Without this the UI cannot say "from 20 minutes ago", and a stale
        // number presented as current is worse than no number at all.
        let before = Date()
        await cache.store(ShopStatus(queued: 3, pending: 1, printing: 1, post: 0, qc: 1, completedToday: 2),
                          for: "/api/status")
        let loaded = await cache.load(ShopStatus.self, for: "/api/status")
        let stored = try XCTUnwrap(loaded?.storedAt)
        XCTAssertGreaterThanOrEqual(stored, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(stored, Date().addingTimeInterval(1))
    }

    func testNothingCachedYetIsNotAnError() async {
        let loaded = await cache.load([QueueOrder].self, for: "/api/queue")
        XCTAssertNil(loaded, "a first run has nothing to show, and must not crash saying so")
    }

    func testDifferentQueriesDoNotShareASlot() async throws {
        // Truncating a path instead of hashing it would collide these two.
        await cache.store([QueueOrder(id: "a", project: "A", client: nil, status: "pending",
                                      machine: nil, machineId: nil, dueDate: nil, priority: nil)],
                          for: "/api/orders?limit=40")
        await cache.store([QueueOrder(id: "b", project: "B", client: nil, status: "pending",
                                      machine: nil, machineId: nil, dueDate: nil, priority: nil)],
                          for: "/api/orders?limit=41")

        let first = await cache.load([QueueOrder].self, for: "/api/orders?limit=40")
        let second = await cache.load([QueueOrder].self, for: "/api/orders?limit=41")
        XCTAssertEqual(first?.value.first?.id, "a")
        XCTAssertEqual(second?.value.first?.id, "b", "one question's answer must not be served for another")
    }

    func testTheSameQueryOverwritesRatherThanAccumulates() async throws {
        for n in 1...3 {
            await cache.store(ShopStatus(queued: n, pending: 0, printing: 0, post: 0, qc: 0, completedToday: 0),
                              for: "/api/status")
        }
        let loaded = await cache.load(ShopStatus.self, for: "/api/status")
        XCTAssertEqual(loaded?.value.queued, 3, "the latest answer wins")
    }

    func testClearingLeavesNothingReadable() async throws {
        // Unpairing must not leave the shop's client list on the phone.
        await cache.store([Client(id: "c1", nameEn: "Acme", nameAr: nil, phone: "+966500000000", email: nil)],
                          for: "/api/clients")
        await cache.clear()
        let loaded = await cache.load([Client].self, for: "/api/clients")
        XCTAssertNil(loaded, "after unpairing there must be nothing left to read")
    }

    func testAPathWithSlashesAndQueriesIsAUsableFilename() {
        // Paths carry /, ? and =, none of which can be a filename.
        let key = cache.key(for: "/api/orders?limit=40&status=printing")
        XCTAssertFalse(key.isEmpty)
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains("?"))
        XCTAssertEqual(key, cache.key(for: "/api/orders?limit=40&status=printing"), "and it must be stable")
    }

    // MARK: - The rule that keeps this safe

    func testOnlyUnreachabilityFallsBackToCache() {
        // A cached answer must never mask a real one. Serving stale data over a
        // 401 would have re-hidden exactly the "Wrong LAN PIN" case the banner
        // was fixed to show.
        XCTAssertTrue(KhaytAPIClient.isUnreachable(KhaytAPIError.transport(URLError(.notConnectedToInternet))))
        XCTAssertTrue(KhaytAPIClient.isUnreachable(URLError(.timedOut)))

        XCTAssertFalse(KhaytAPIClient.isUnreachable(KhaytAPIError.unauthorized),
                       "a wrong PIN is the desktop answering — it must keep surfacing")
        XCTAssertFalse(KhaytAPIClient.isUnreachable(KhaytAPIError.server("boom")),
                       "so is a 500")
        XCTAssertFalse(KhaytAPIClient.isUnreachable(KhaytAPIError.notConfigured))
        XCTAssertFalse(KhaytAPIClient.isUnreachable(DecodingError.valueNotFound(
            String.self, .init(codingPath: [], debugDescription: "x"))),
                       "a payload we cannot read is a contract problem; hiding it is how it stays unnoticed")
    }
}
