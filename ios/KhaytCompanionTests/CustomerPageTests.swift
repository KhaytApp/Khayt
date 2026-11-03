import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The customer page, read from the phone's book: the jobs that are theirs,
/// what they owe under the shop's own rule, their terms, agreed prices and
/// the messages logged against them.
final class CustomerPageTests: XCTestCase {
    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "customer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        try book.replace(with: [
            "settings": .object(["currency": .string("SAR")]),
            "clients": .array([
                .object([
                    "id": .string("C-1"), "name": .string("Noura"),
                    "creditLimit": .number(100), "paymentTermsDays": .number(30),
                    "priceList": .array([.object(["product": .string("Bracket"), "price": .number(12), "note": .string("min 10")])]),
                    "commLog": .array([
                        .object(["id": .string("m1"), "type": .string("whatsapp"), "note": .string("Sent the quote"), "at": .string("2026-10-01T09:00:00Z")]),
                        .object(["id": .string("m2"), "type": .string("call"), "note": .string("Asked about colour"), "at": .string("2026-10-05T09:00:00Z"), "orderId": .string("J-1")]),
                    ]),
                ]),
                .object(["id": .string("C-2"), "name": .string("Fahad")]),
            ]),
            "printLog": .array([
                .object(["id": .string("J-1"), "project": .string("Brackets"), "clientId": .string("C-1"),
                         "status": .string("printing"), "price": .number(150), "dueDate": .string("2026-11-10")]),
                // Same name, no id: an older job still counts as theirs.
                .object(["id": .string("J-2"), "project": .string("Old sign"), "client": .string("noura"),
                         "status": .string("completed"), "price": .number(40), "paidAmount": .number(40), "paymentStatus": .string("paid"), "date": .string("2026-09-01")]),
                .object(["id": .string("J-3"), "project": .string("A quote"), "clientId": .string("C-1"),
                         "status": .string("quote"), "price": .number(500)]),
                .object(["id": .string("J-4"), "project": .string("Not hers"), "clientId": .string("C-2"),
                         "status": .string("pending"), "price": .number(90)]),
            ]),
        ], scope: nil)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testACustomersPageHoldsTheirJobsTermsAndMessages() async throws {
        let s = try await BookReader(book: book).customer(id: "C-1")
        let page = try XCTUnwrap(s)
        XCTAssertEqual(page.openJobs.map(\.id), ["J-1"], "a quote is not an open job, and another customer's job is not hers")
        XCTAssertEqual(page.finishedJobs.map(\.id), ["J-2"], "a job linked only by name is still hers")
        XCTAssertEqual(page.creditLimit, 100)
        XCTAssertEqual(page.paymentTermsDays, 30)
        XCTAssertEqual(page.currency, "SAR")
        XCTAssertEqual(page.agreements, [.init(product: "Bracket", price: 12, note: "min 10")])
        XCTAssertEqual(page.messages.map(\.id), ["m2", "m1"], "newest message first")
        XCTAssertEqual(page.messages.first?.orderId, "J-1")
    }

    func testWhatTheyOweIsTheShopsRuleAndTheLimitShows() async throws {
        let found = try await BookReader(book: book).customer(id: "C-1")
        let page = try XCTUnwrap(found)
        XCTAssertEqual(page.owed, 150, accuracy: 0.01, "the unpaid open job; the quote owes nothing")
        XCTAssertEqual(page.openJobs.first?.owed ?? 0, 150, accuracy: 0.01)
        XCTAssertTrue(page.isOverLimit)
        let other = try await BookReader(book: book).customer(id: "C-2")
        let fahad = try XCTUnwrap(other)
        XCTAssertFalse(fahad.isOverLimit, "no limit set means never over it")
    }

    func testAnUnknownCustomerHasNoPage() async throws {
        let none = try await BookReader(book: book).customer(id: "C-404")
        XCTAssertNil(none)
    }
}
