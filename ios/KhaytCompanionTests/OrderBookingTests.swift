import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * Raising an order or a quote on the phone with the Mac switched off.
 *
 * Each assertion is a field `POST /api/orders` in lib/lan-server.js sets, since
 * the Mac folds the record in as it is.
 */
final class OrderBookingTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private let riyadh = TimeZone(identifier: "Asia/Riyadh")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "orders-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        try book.replace(with: [
            "settings": .object(["invPrefix": .string("KH"), "quoteValidityDays": .number(14)]),
            "printLog": .array([
                .object(["id": .string("O-1"), "status": .string("pending"), "rev": .number(1)]),
                .object(["id": .string("O-2"), "status": .string("pending"), "rev": .number(1)]),
                .object(["id": .string("O-3"), "status": .string("printing"), "rev": .number(1)]),
            ]),
            "machines": .array([.object(["id": .string("M-1"), "name": .string("Bambu X1C")])]),
        ], scope: nil)
        try book.markSynced()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var machines: [MachineInfo] {
        [try! JSONDecoder().decode(MachineInfo.self, from: Data(#"{"id":"M-1","name":"Bambu X1C"}"#.utf8))]
    }

    private func draft(_ edit: (inout NewOrderDraft) -> Void = { _ in }) -> NewOrderDraft {
        var d = NewOrderDraft()
        d.project = "Drone frame"
        d.client = "Faisal"
        d.material = "PETG"
        d.price = "120,5"
        d.machineId = "M-1"
        edit(&d)
        return d
    }

    func testAnOrderIsTheRecordTheEndpointWrites() throws {
        // 23:30 UTC on the 22nd is the 23rd in Riyadh.
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T23:30:00Z"))
        let o = try BookWriter.orderRecord(from: draft(), settings: ["invPrefix": .string("KH")],
                                           machines: machines,
                                           existing: [.object(["status": .string("pending")]),
                                                      .object(["status": .string("printing")])],
                                           now: now, zone: riyadh)
        guard case .string(let id)? = o["id"] else { return XCTFail("no id") }
        XCTAssertTrue(id.range(of: #"^KH-2026-\d+-[0-9a-f]{4}$"#, options: .regularExpression) != nil, id)
        XCTAssertEqual(o["date"], .string("2026-09-23"), "the shop's day, not UTC's")
        XCTAssertEqual(o["status"], .string("pending"))
        XCTAssertEqual(o["project"], .string("Drone frame"))
        XCTAssertEqual(o["client"], .string("Faisal"))
        XCTAssertEqual(o["clientId"], .null)
        XCTAssertEqual(o["material"], .string("PETG"))
        XCTAssertEqual(o["price"], .number(120.5), "a comma is a decimal point")
        XCTAssertEqual(o["machineId"], .string("M-1"))
        XCTAssertEqual(o["machine"], .string("Bambu X1C"), "the name as well, as the endpoint looks it up")
        XCTAssertEqual(o["queuePos"], .number(2), "behind the one job already pending")
        XCTAssertEqual(o["paymentStatus"], .string("unpaid"))
        XCTAssertEqual(o["parts"], .array([]))
        XCTAssertEqual(o["notes"], .string(""))
        XCTAssertEqual(o["dueDate"], .null)
        XCTAssertNil(o["quoteExpiresAt"])
        guard case .array(let history)? = o["statusHistory"], case .object(let first)? = history.first else {
            return XCTFail("no status history")
        }
        XCTAssertEqual(first["status"], .string("pending"))
    }

    func testAQuoteTakesTheQuotePrefixAndTheShopsValidity() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-23T09:00:00Z"))
        let q = try BookWriter.orderRecord(from: draft { $0.isQuote = true },
                                           settings: ["quoteValidityDays": .number(14)],
                                           machines: machines, existing: [], now: now, zone: riyadh)
        guard case .string(let id)? = q["id"] else { return XCTFail("no id") }
        XCTAssertTrue(id.hasPrefix("QUO-2026-"), id)
        XCTAssertEqual(q["status"], .string("quote"))
        XCTAssertEqual(q["quoteSentAt"], .string("2026-09-23"))
        XCTAssertEqual(q["quoteExpiresAt"], .string("2026-10-07"))
        XCTAssertEqual(q["quoteVersion"], .number(1))

        let plain = try BookWriter.orderRecord(from: draft { $0.isQuote = true }, settings: [:],
                                               machines: machines, existing: [], now: now, zone: riyadh)
        XCTAssertEqual(plain["quoteExpiresAt"], .string("2026-09-30"), "seven days when the shop set none")
    }

    func testAPrinterTheShopDoesNotHaveIsRefused() {
        XCTAssertThrowsError(try BookWriter.orderRecord(from: draft { $0.machineId = "M-gone" }, settings: [:],
                                                        machines: machines, existing: [])) {
            XCTAssertEqual($0 as? BookWriter.Refusal, .noSuchMachine)
        }
    }

    func testAnOrderNeedsAProject() {
        XCTAssertThrowsError(try BookWriter.orderRecord(from: draft { $0.project = "  " }, settings: [:],
                                                        machines: machines, existing: [])) {
            XCTAssertEqual($0 as? BookWriter.Refusal, .noProject)
        }
    }

    func testRaisedOfflineItLandsFirstAndWaitsForTheMac() async throws {
        let made = try BookWriter(book: book).addOrder(draft(), machines: machines)
        guard case .array(let log)? = try book.read()["printLog"], case .object(let first)? = log.first else {
            return XCTFail("no printLog")
        }
        XCTAssertEqual(log.count, 4)
        XCTAssertEqual(first["id"], made["id"], "at the front, as the endpoint writes it")
        XCTAssertEqual(first["queuePos"], .number(3), "counted inside the write: two pending already")
        XCTAssertNotNil(first["rev"], "stamped, like every record the desk writes")

        let reader = BookReader(book: book)
        let produced = try await reader.pendingChanges()
        XCTAssertEqual(try XCTUnwrap(produced).count, 1, "the new order, and nothing else")
        let queue = try await reader.queue()
        XCTAssertTrue(queue.contains { $0.project == "Drone frame" }, "the queue screen shows it straight away")
    }
}
