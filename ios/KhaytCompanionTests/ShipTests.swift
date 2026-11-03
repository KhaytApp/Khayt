import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Shipping from the phone runs the Mac's rule (`lib/shipment.js` through
/// KhaytCore) — so the phone's engine must carry the carriers and the
/// shipment modules, and a waybill's number lands on the job.
final class ShipTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "ship-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testThePhonesEngineShipsAJobAsTheMacDoes() async throws {
        let book = CompanionBook(directory: dir)
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope())
        let engine = try await BookReader(book: book).sharedEngine()
        let carriers = try await engine.carriersToShipWith(settings: .object([:]))
        XCTAssertEqual(carriers.last?.id, "manual", "Manual is always there, last")

        let order: JSONValue = .object(["id": .string("S-1"), "status": .string("completed")])
        let shipped = try await engine.shipmentCreate(order: order, carrier: "manual", service: nil,
                                                      trackingNumber: " 1Z999 ", at: Date())
        guard case .object(let o) = shipped else { return XCTFail("no order") }
        XCTAssertEqual(o["trackingNumber"], .string("1Z999"))
        XCTAssertEqual(o["carrier"], .string("manual"))
        XCTAssertEqual(o["shippingStatus"], .string("label_created"))
        XCTAssertNotNil(o["shippedAt"])
    }

    func testARemindersDayIsTheBooksGregorianDay() {
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        let now = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!
        let when = IntakeReminder.date(inDays: 1, from: now, calendar: hijri)!
        XCTAssertEqual(IntakeReminder.day(when, zone: hijri.timeZone), "2026-11-03")
        XCTAssertEqual(hijri.component(.hour, from: when), 9)
    }
}
