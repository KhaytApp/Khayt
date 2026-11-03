import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Editing a job on the phone is the Mac's edit: only what moved is sent,
/// and the shared rule writes it down and carries the money.
final class EditOrderTests: XCTestCase {
    private let start = KhaytAPIClient.OrderEditState(dueDate: "2026-11-10", priorityLevel: "normal", price: 100)

    func testOnlyWhatMovedIsSent() {
        XCTAssertTrue(EditOrderSheet.fields(start: start, due: "2026-11-10", level: "normal", price: 100).isEmpty,
                      "opened and closed: no edit, no revision")
        let moved = EditOrderSheet.fields(start: start, due: nil, level: "urgent", price: 80)
        XCTAssertEqual(moved["dueDate"], .null, "cleared, which is an answer")
        XCTAssertEqual(moved["priorityLevel"], .string("urgent"))
        XCTAssertEqual(moved["price"], .number(80))
        XCTAssertNil(EditOrderSheet.fields(start: start, due: "2026-11-10", level: "normal", price: nil)["price"],
                     "an unreadable price leaves the price alone")
    }

    func testThePhonesEngineRunsTheSharedEdit() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "edit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = CompanionBook(directory: dir)
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope())
        let engine = try await BookReader(book: book).sharedEngine()
        let order: JSONValue = .object(["id": .string("A"), "status": .string("pending"), "price": .number(100),
                                        "paidAmount": .number(100), "priority": .bool(false)])
        let edited = try await engine.editJob(order: order, fields: ["priorityLevel": .string("urgent"), "price": .number(80)],
                                              now: Date(), editId: "edit-1")
        XCTAssertTrue(edited.changed)
        guard case .object(let o) = edited.order else { return XCTFail() }
        XCTAssertEqual(o["priorityLevel"], .string("urgent"))
        XCTAssertEqual(o["priority"], .bool(true))
        XCTAssertEqual(o["price"], .number(80))
        XCTAssertEqual(o["paidAmount"], .number(80), "paid never exceeds the new price")
    }
}
