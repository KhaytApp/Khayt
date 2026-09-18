import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * The screens reading the shop's own records.
 *
 * These are not about speed. The native Mac serves `/api/status`, `/api/queue`
 * and `/api/store` and nothing else — no orders, no inventory, no clients, no
 * machines, no waiting list — so against that app these five screens do not load
 * at all. What is tested here is whether they can load from the book instead.
 */
final class BookReaderTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "reader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A book shaped like the desktop's, including the two spellings that differ
    /// from what the LAN server puts on the wire.
    private func shop() -> [String: JSONValue] {
        [
            "settings": .object(["shopName": .string("Ward"), "enableVat": .bool(true),
                                 "vatRate": .number(15)]),
            "printLog": .array([
                // THE TRAP. `priority` is a BOOLEAN in the store and a STRING on
                // the wire. A hand-written queue projection would compile, run,
                // and fail to decode on the first shop that flagged a job urgent.
                .object(["id": .string("O-1"), "status": .string("printing"),
                         "project": .string("Bracket"), "client": .string("Acme"),
                         "date": .string("2026-09-10"), "priority": .bool(true)]),
                .object(["id": .string("O-2"), "status": .string("pending"),
                         "project": .string("Jig"), "client": .string("Acme"),
                         "date": .string("2026-09-12")]),
                .object(["id": .string("O-3"), "status": .string("delivered"),
                         "project": .string("Old"), "client": .string("Sara"),
                         "date": .string("2026-01-02")]),
            ]),
            "inventory": .array([
                // The store spells it `weightRemaining`, not `remaining` — which
                // `InventorySpool` already knows, and which is exactly why the
                // decoding is left to the model rather than re-mapped by hand.
                .object(["id": .string("S-1"), "material": .string("PLA"),
                         "brand": .string("Polymaker"), "weightRemaining": .number(640),
                         "weightTotal": .number(1000)]),
            ]),
            "clients": .array([
                .object(["id": .string("C-1"), "nameEn": .string("Sara"),
                         "phone": .string("0500000000")]),
            ]),
            "machines": .array([
                .object(["id": .string("M-1"), "name": .string("X1C"), "status": .string("idle")]),
            ]),
            "waitingList": .array([
                .object(["id": .string("W-1"), "project": .string("Sign"),
                         "clientName": .string("Nora"), "status": .string("new")]),
                .object(["id": .string("W-2"), "project": .string("Dropped"),
                         "clientName": .string("Nobody"), "status": .string("declined")]),
            ]),
        ]
    }

    func testTheQueueComesFromTheSharedRule_includingAUrgentJob() async throws {
        // The whole reason the queue is not read field by field. If this decodes,
        // the boolean-vs-string `priority` was normalised by the same code the
        // Mac serves, rather than by an opinion invented on the phone.
        try book.replace(with: shop(), scope: nil)
        let queue = try await reader.queue()

        let ids = queue.map(\.id)
        XCTAssertTrue(ids.contains("O-1"), "the printing job is not in the queue")
        XCTAssertTrue(ids.contains("O-2"), "the pending job is not in the queue")
        XCTAssertFalse(ids.contains("O-3"), "a delivered job is history, not queue")
    }

    func testTheMastheadFiguresAreTheMacsOwnCount() async throws {
        try book.replace(with: shop(), scope: nil)
        let status = try await reader.status(today: "2026-09-12")
        // Not recounted here: whatever the shared rule says the queue is, the
        // figure agrees with it by construction.
        let queue = try await reader.queue()
        XCTAssertEqual(status.queued, queue.count,
                       "the masthead and the queue screen disagree about the same shop")
    }

    func testOrdersComeBackNewestFirstAndRespectTheLimit() async throws {
        try book.replace(with: shop(), scope: nil)
        let all = try await reader.recentOrders(limit: 40)
        XCTAssertEqual(all.map(\.id), ["O-2", "O-1", "O-3"], "history is not newest first")

        let one = try await reader.recentOrders(limit: 1)
        XCTAssertEqual(one.map(\.id), ["O-2"])
        let delivered = try await reader.recentOrders(limit: 40, status: "delivered")
        XCTAssertEqual(delivered.map(\.id), ["O-3"])
    }

    func testASpoolKeepsTheStoresSpellingOfWhatIsLeft() async throws {
        try book.replace(with: shop(), scope: nil)
        let spools = try await reader.inventory()
        XCTAssertEqual(spools.count, 1)
        // `weightRemaining` → `remaining`. Read by the model's own decoder, which
        // is why there is no second mapping to keep in step.
        XCTAssertEqual(spools[0].remaining, 640)
        XCTAssertEqual(spools[0].brand, "Polymaker")
    }

    func testClientsAndMachinesAreRecordsAsTheyStand() async throws {
        try book.replace(with: shop(), scope: nil)
        let clients = try await reader.clients()
        let machines = try await reader.machines()
        XCTAssertEqual(clients.map(\.displayName), ["Sara"])
        XCTAssertEqual(machines.map(\.id), ["M-1"])
    }

    func testTriageDoesNotShowRequestsSomebodyAlreadyDeclined() async throws {
        try book.replace(with: shop(), scope: nil)
        let waiting = try await reader.waitingList()
        XCTAssertEqual(waiting.map(\.id), ["W-1"],
                       "a declined request came back — the desktop drops these before sending")
    }

    func testAPhoneWithNoBookSaysSoRatherThanShowingAnEmptyShop() async {
        // An empty screen and a shop with nothing in it must not look the same:
        // one is a setup step nobody did, and telling them apart is the whole
        // reason the book refuses rather than returning [].
        XCTAssertFalse(book.exists)
        do {
            _ = try await reader.inventory()
            XCTFail("a phone with no book reported an empty inventory as fact")
        } catch {}
        do {
            _ = try await reader.recentOrders()
            XCTFail("a phone with no book reported an empty order history as fact")
        } catch {}
    }
}
