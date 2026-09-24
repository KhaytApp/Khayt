import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Shop Pulse's one rule (`design/ios-v2/`): a figure bounded by recency is
/// answerable only when the book reaches past the period's start — otherwise it
/// is nil, the screen's em-dash "On the Mac". Never a zero.
final class ShopPulseTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pulse-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let now = ISO8601DateFormatter().date(from: "2026-09-18T12:00:00Z")!

    private func order(_ id: String, _ status: String, date: String, price: Double, paid: Double = 0) -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "date": .string(date), "project": .string(id),
                 "price": .number(price), "paidAmount": .number(paid), "priority": .bool(false)])
    }

    private func load(_ orders: [JSONValue], whole: Bool) throws {
        let taken = BookScope.Taken(collections: ["printLog": .init(whole: whole, sent: orders.count, available: whole ? orders.count : 999)],
                                    omitted: ["expenses"], takenAt: "2026-09-18T11:00:00.000Z")
        try book.replace(with: ["settings": .object(["currency": .string("SAR")]), "printLog": .array(orders), "clients": .array([])],
                         scope: taken)
    }

    func testTheMonthIsAnsweredWhenTheWindowReachesPastItsFirstDay() async throws {
        // The window reaches back to 14 June: September is covered, the year is not.
        try load([order("A", "completed", date: "2026-06-14", price: 50),
                  order("B", "completed", date: "2026-09-10", price: 400),
                  order("C", "printing", date: "2026-09-17", price: 120)], whole: false)
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertNotNil(pulse.thisMonth, "the window reaches past 1 September")
        XCTAssertNil(pulse.thisYear, "it does not reach 1 January — the year lives on the Mac")
        XCTAssertEqual(pulse.currency, "SAR")
    }

    func testAWindowThatStartsThisMonthCannotAnswerTheMonth() async throws {
        try load([order("B", "completed", date: "2026-09-10", price: 400)], whole: false)
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertNil(pulse.thisMonth, "a zero or a partial month here would be an answer, and a wrong one")
        XCTAssertNil(pulse.thisYear)
    }

    func testAWholeBookAnswersEverything() async throws {
        try load([order("B", "completed", date: "2026-09-10", price: 400)], whole: true)
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertNotNil(pulse.thisMonth)
        XCTAssertNotNil(pulse.thisYear)
    }

    func testOwedCountsOpenOrdersByTheShopsOwnRule() async throws {
        // Owed is open work, every one of which travels — so it is always answerable.
        // Paid is `paidAmount`, as `lib/order-money.js` reads it; there is no
        // status label that settles an order.
        try load([order("C", "printing", date: "2026-09-17", price: 120),
                  order("D", "pending", date: "2026-09-17", price: 80, paid: 80),
                  order("B", "completed", date: "2026-09-10", price: 400)], whole: false)
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertEqual(pulse.unpaid, 1, "the paid one owes nothing; the finished one is not open work")
        XCTAssertEqual(pulse.owed, 120, accuracy: 0.001)
    }
}
