import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * The book the phone keeps has a contract too, and nothing was guarding it.
 *
 * ── THE BUG THIS EXISTS BECAUSE OF ────────────────────────────────────────
 *
 * `QueueOrder.priority` was `String?`. The desktop writes a BOOLEAN — every
 * order, from `order-new.js` — and a `Codable` mismatch throws for the whole
 * array, so the queue screen could not decode a single real shop's queue. It
 * shipped that way.
 *
 * `scripts/ios-contract.sh` exists to catch exactly that, and could not: it
 * captures live responses from `lib/lan-server.js` against a fixture, and the
 * fixture had been written with a shape the product does not produce. A guard
 * measured against invented data is measured against nothing.
 *
 * ── AND WHY THE OLD GUARD WOULD NOT HAVE CAUGHT IT ANYWAY ─────────────────
 *
 * The phone no longer gets its records from the wire. `BookReader` decodes RAW
 * STORE RECORDS out of the book, which is a second contract — the store's own
 * shapes, not the LAN server's projections of them — and it had no guard at all.
 *
 * So this one is measured against the shop's real data: `sample-shop.json`, the
 * same book the Mac app opens for a demo, with a real shop's spread of statuses,
 * absent fields and historical spellings. If a model cannot read that, it cannot
 * read a shop.
 */
final class BookContractTests: XCTestCase {

    /// The sample shop, read from the repo rather than bundled — the test binary
    /// has no business carrying 193 KB of somebody's demo data.
    private func sampleShop() throws -> [String: JSONValue] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // KhaytCompanionTests
            .deletingLastPathComponent()      // ios
            .deletingLastPathComponent()      // repo root
            .appending(path: "mac/KhaytCore/Sources/KhaytApp/Resources/sample-shop.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func decodeAll<T: Decodable>(_ type: T.Type, from store: [String: JSONValue],
                                         _ collection: String) throws -> [T] {
        guard case .array(let rows)? = store[collection] else { return [] }
        let data = try JSONEncoder().encode(JSONValue.array(rows))
        return try JSONDecoder().decode([T].self, from: data)
    }

    func testEveryCollectionTheScreensReadDecodesFromARealShopsBook() throws {
        let shop = try sampleShop()

        // Each of these is a screen. A throw here is that screen showing nothing
        // — not a blank field, the whole list — for every shop with this data.
        let orders = try decodeAll(OrderLogEntry.self, from: shop, "printLog")
        XCTAssertGreaterThan(orders.count, 0, "the sample shop has no orders — the fixture moved")

        let spools = try decodeAll(InventorySpool.self, from: shop, "inventory")
        XCTAssertGreaterThan(spools.count, 0)

        // Every spool must report what is left of it. Asserted through
        // `remainingGrams` — the desktop's own `remaining || weight` — and NOT
        // through `remaining`, which is nil for every spool a real shop's book
        // contains. Asserting the raw field would have demanded a shape the
        // product does not write, which is the mistake the contract fixture
        // made about `priority`.
        for spool in spools {
            XCTAssertNotNil(spool.remainingGrams, "spool \(spool.id) reports no remaining grams")
        }

        // And what it started as is a DIFFERENT number. `weight` is what is
        // left; `spoolWeight` is the full roll. Reading the first as the second
        // made every spool in the shop look unopened.
        let sized = spools.filter { $0.initialWeight != nil }
        XCTAssertGreaterThan(sized.count, 0, "not one spool knows how big it was when it arrived")
        for spool in sized where spool.remainingGrams != nil {
            XCTAssertGreaterThanOrEqual(spool.initialWeight!, spool.remainingGrams!,
                                        "spool \(spool.id) has more left on it than it ever held")
        }
        XCTAssertNotNil(sized.first(where: { $0.initialWeight != $0.remainingGrams }),
                        "every spool reads as untouched — initial and remaining are the same number")

        let clients = try decodeAll(Client.self, from: shop, "clients")
        XCTAssertGreaterThan(clients.count, 0)

        _ = try decodeAll(MachineInfo.self, from: shop, "machines")
        _ = try decodeAll(WaitingListItem.self, from: shop, "waitingList")
    }

    /// THE ONE THAT WOULD HAVE CAUGHT IT.
    func testTheQueueDecodesFromARealShopsBook() async throws {
        let shop = try sampleShop()

        // Through the shared rule, exactly as the phone does it: `lanQueueBody`
        // decides which orders are in the queue and what shape they arrive in.
        let engine = try KhaytEngine()
        let json = try await engine.lanQueueBody(store: .object(shop))
        let queue = try JSONDecoder().decode([QueueOrder].self, from: Data(json.utf8))

        XCTAssertGreaterThan(queue.count, 0, "the sample shop has nothing in its queue")

        // `priority` is a boolean in every order this shop has written. The model
        // reads either spelling now; before it did not, and this line is the one
        // that would have failed — for the whole array, not one field.
        let flagged = queue.filter { $0.priority != nil }
        XCTAssertGreaterThan(flagged.count, 0,
                             "no order carried a priority — the case that broke the queue is untested")
    }

    /// An assigned job must not read as unassigned.
    func testTheQueueNamesThePrinterARealShopAssigned() async throws {
        let shop = try sampleShop()

        // Every job in this shop's queue is on a printer, and not one of them
        // carries the printer's NAME — `order-new.js` writes `machineId` alone.
        guard case .array(let log)? = shop["printLog"] else { return XCTFail("no orders") }
        let live = log.compactMap { row -> [String: JSONValue]? in
            guard case .object(let o) = row, case .string(let s)? = o["status"],
                  ["pending", "printing", "post", "qc"].contains(s) else { return nil }
            return o
        }
        XCTAssertGreaterThan(live.count, 0)
        XCTAssertEqual(live.filter { $0["machine"] != nil }.count, 0,
                       "this shop now records machine names, so the fixture no longer covers the gap")
        XCTAssertEqual(live.filter { $0["machineId"] != nil }.count, live.count,
                       "every queued job should be assigned to a printer by id")

        // Read the way a screen reads it.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "named-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = CompanionBook(directory: dir)
        try book.replace(with: shop, scope: nil)

        let queue = try await BookReader(book: book).queue()
        XCTAssertGreaterThan(queue.count, 0)

        let named = queue.filter { ($0.machine?.isEmpty == false) }
        XCTAssertEqual(named.count, queue.count, """
            \(queue.count - named.count) of \(queue.count) queued jobs have no printer name.
            They are assigned — every one carries a machineId — so the row draws no printer
            and the detail sheet says "Unassigned" for a job that is on a machine.
            """)
        // And it is a real name from the shop's own list, not the id echoed back.
        XCTAssertNotNil(named.first(where: { $0.machine == "Bambu X1C" || $0.machine == "Prusa CORE One" }),
                        "the names do not match the shop's machines")
    }

    /// The statuses a real shop's book actually contains, against what the app
    /// can name. `cancelled` lives in shipping books and is not in the desktop's
    /// own STATUSES list, which is why `status` is a String on the wire and the
    /// enum is display-only.
    func testEveryStatusInARealShopIsEitherNamedOrSafelyUnnamed() throws {
        let shop = try sampleShop()
        let orders = try decodeAll(OrderLogEntry.self, from: shop, "printLog")
        let statuses = Set(orders.map(\.status))
        XCTAssertGreaterThan(statuses.count, 1)

        for status in statuses {
            // Not an assertion that every status is known — an assertion that an
            // unknown one cannot crash or vanish. `OrderStatus` is display-only;
            // anything it does not know falls back rather than throwing.
            let known = OrderStatus(rawValue: status)
            if known == nil {
                XCTAssertFalse(status.isEmpty, "an order carried an empty status")
            } else {
                XCTAssertFalse(known!.localizedLabel.isEmpty,
                               "\(status) is a known status with no label — a blank cell on screen")
            }
        }
    }
}
