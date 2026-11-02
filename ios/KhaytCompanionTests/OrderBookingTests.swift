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
        try book.markSynced(try book.read())
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

    // MARK: - The saved customer, and the currency the price is in

    private let saved: [JSONValue] = [
        .object(["id": .string("C-1"), "name": .string("Faisal"), "currency": .string("USD")]),
        .object(["id": .string("C-2"), "name": .string("Noura")]),
        .object(["id": .string("C-3"), "nameEn": .string("Noura")]),
    ]

    /// A picked customer is linked, and since the price was typed in the
    /// shop's riyals, the order says so — or the shared rule would read 120.5
    /// as dollars, the customer's currency.
    func testAPickedCustomerIsLinkedAndThePriceKeepsTheShopsCurrency() throws {
        let o = try BookWriter.orderRecord(from: draft { $0.clientId = "C-1" },
                                           settings: ["currency": .string("SAR")],
                                           machines: machines, existing: [], clients: saved)
        XCTAssertEqual(o["clientId"], .string("C-1"))
        XCTAssertEqual(o["currency"], .string("SAR"))
    }

    /// A name typed exactly is linked when one saved customer has it, and
    /// never guessed when two do. A customer in the shop's currency adds none.
    func testATypedNameLinksOnlyWhenItIsUnambiguous() throws {
        let faisal = try BookWriter.orderRecord(from: draft { $0.client = "faisal" }, settings: [:],
                                                machines: machines, existing: [], clients: saved)
        XCTAssertEqual(faisal["clientId"], .string("C-1"))
        XCTAssertEqual(faisal["currency"], .string("SAR"), "no shop setting reads as SAR, as lib does")
        let noura = try BookWriter.orderRecord(from: draft { $0.client = "Noura" }, settings: [:],
                                               machines: machines, existing: [], clients: saved)
        XCTAssertEqual(noura["clientId"], .null)
        XCTAssertNil(noura["currency"])
        let gone = try BookWriter.orderRecord(from: draft { $0.client = "Someone"; $0.clientId = "C-9" },
                                              settings: [:], machines: machines, existing: [], clients: saved)
        XCTAssertEqual(gone["clientId"], .null, "a customer no longer in the book is not linked")
    }

    /// The order page's currency: the order's own, then its customer's, then the shop's.
    func testAnOrdersCurrencyFollowsTheSharedRule() async throws {
        try book.replace(with: [
            "settings": .object(["currency": .string("SAR")]),
            "clients": .array(saved),
            "printLog": .array([
                .object(["id": .string("A"), "currency": .string("EUR"), "clientId": .string("C-1")]),
                .object(["id": .string("B"), "clientId": .string("C-1")]),
                .object(["id": .string("C"), "clientId": .string("C-2")]),
            ]),
        ], scope: nil)
        let reader = BookReader(book: book)
        let a = try await reader.orderCurrency(orderId: "A")
        let b = try await reader.orderCurrency(orderId: "B")
        let c = try await reader.orderCurrency(orderId: "C")
        XCTAssertEqual(a, "EUR")
        XCTAssertEqual(b, "USD")
        XCTAssertEqual(c, "SAR")
    }
}
