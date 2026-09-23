import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * Booking a roll in from the phone, with no desk to ask.
 *
 * The record has to be the one `POST /api/inventory` would have written, since
 * the Mac folds it in as-is. Each field below is one the endpoint sets.
 */
final class SpoolBookingTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "spool-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
        try book.replace(with: [
            "settings": .object(["shopName": .string("Ward"), "activeLocationId": .string("riyadh")]),
            "inventory": .array([
                .object(["id": .string("S-1"), "material": .string("PLA"), "weight": .number(640), "rev": .number(1)]),
            ]),
        ], scope: nil)
        try book.markSynced()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func draft() -> SpoolDraft {
        var d = SpoolDraft()
        d.material = "PETG"
        d.weightGrams = 1000
        d.brand = "Sunlu"
        d.colorHex = "#FF0000"
        d.sku = "SL-PETG-R"
        d.lot = "L42"
        d.printTemp = "240"
        d.bedTemp = "80"
        d.cost = "89.50"
        return d
    }

    func testTheRollIsTheRecordTheEndpointWrites() async throws {
        let record = try await reader.newSpool(from: draft())

        XCTAssertEqual(record["material"], .string("PETG"))
        // The whole reason for the price field: a zero here priced every job
        // off this roll at nothing for filament.
        XCTAssertEqual(record["cost"], .number(89.5))
        XCTAssertEqual(record["color"], .string("#FF0000"))
        XCTAssertEqual(record["lot"], .string("L42"))
        XCTAssertEqual(record["brand"], .string("Sunlu"))
        XCTAssertEqual(record["sku"], .string("SL-PETG-R"))
        XCTAssertEqual(record["printTemp"], .number(240))
        XCTAssertEqual(record["bedTemp"], .number(80))
        XCTAssertEqual(record["materialType"], .string("fdm"))
        // The branch the desk is showing, as the endpoint picks it.
        XCTAssertEqual(record["locationId"], .string("riyadh"))
        // All three names for what is left, and what it weighed arriving.
        XCTAssertEqual(record["weight"], .number(1000))
        XCTAssertEqual(record["remaining"], .number(1000))
        XCTAssertEqual(record["weightRemaining"], .number(1000))
        XCTAssertEqual(record["spoolWeight"], .number(1000))
        XCTAssertEqual(record["weightTotal"], .number(1000))
        XCTAssertNotNil(record["addedAt"])
        XCTAssertEqual(record["purchasedAt"], .string(BookWriter.localDay(Date())))
        guard case .string(let id)? = record["id"] else { return XCTFail("no id") }
        XCTAssertTrue(id.range(of: #"^spool-\d+-[0-9a-f]{4}$"#, options: .regularExpression) != nil, id)
    }

    func testNoPriceIsNoPriceNotAGuess() async throws {
        var d = draft()
        d.cost = ""
        let record = try await reader.newSpool(from: d)
        XCTAssertEqual(record["cost"], .number(0))
    }

    func testTheDayIsTheShopsNotUTC() throws {
        // 23:30 UTC on the 22nd is 02:30 on the 23rd in Riyadh — the case the
        // endpoint's comment describes, when this phone used to send UTC.
        let when = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T23:30:00Z"))
        let riyadh = try XCTUnwrap(TimeZone(identifier: "Asia/Riyadh"))
        XCTAssertEqual(BookWriter.localDay(when, in: riyadh), "2026-09-23")
    }

    func testARollWithNoMaterialIsRefused() async throws {
        var d = draft()
        d.material = "   "
        do {
            _ = try await reader.newSpool(from: d)
            XCTFail("a spool with no material cannot be matched to any job")
        } catch let refusal as BookWriter.Refusal {
            XCTAssertEqual(refusal, .noMaterial)
        }
    }

    func testBookingInLandsInTheBookAndIsPendingForTheMac() async throws {
        let record = try await reader.newSpool(from: draft())
        try BookWriter(book: book).addSpool(record)

        guard case .array(let shelf)? = try book.read()["inventory"] else { return XCTFail() }
        XCTAssertEqual(shelf.count, 2)

        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        XCTAssertEqual(outbox.count, 1, "the new roll, and nothing else")

        // The screen that shows it decodes it like any other spool.
        let data = try JSONEncoder().encode(JSONValue.object(record))
        let spool = try JSONDecoder().decode(InventorySpool.self, from: data)
        XCTAssertEqual(spool.cost, 89.5)
    }

    func testTheSameIdTwiceIsRefused() async throws {
        let record = try await reader.newSpool(from: draft())
        try BookWriter(book: book).addSpool(record)
        XCTAssertThrowsError(try BookWriter(book: book).addSpool(record)) {
            XCTAssertEqual($0 as? BookWriter.Refusal, .idTaken)
        }
    }

    func testAPriceIsReadWhateverTheKeypad() {
        XCTAssertEqual(SpoolDraft.price("75.50"), 75.5)
        XCTAssertEqual(SpoolDraft.price("75,50"), 75.5)
        XCTAssertEqual(SpoolDraft.price("٧٥٫٥٠"), 75.5)
        XCTAssertEqual(SpoolDraft.price(" 90 "), 90)
        XCTAssertNil(SpoolDraft.price(""))
        XCTAssertNil(SpoolDraft.price("0"))
        XCTAssertNil(SpoolDraft.price("-5"))
        XCTAssertNil(SpoolDraft.price("SAR 90"))
    }
}
