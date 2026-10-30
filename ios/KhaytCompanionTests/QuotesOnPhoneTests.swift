import XCTest
import KhaytCore
@testable import KhaytCompanion

/// A quote made on the phone used to vanish from it: the queue leaves quotes
/// out and History takes only finished work. These hold the Quotes list and
/// the two answers its page writes.
final class QuotesOnPhoneTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    /// One for the class: starting the rules costs about a fifth of a second.
    private static let sharedEngine = Result { try KhaytEngine() }
    private var engine: KhaytEngine!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "quotes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        engine = try Self.sharedEngine.get()
        try book.replace(with: shop(), scope: nil)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func shop() -> [String: JSONValue] {
        func job(_ id: String, _ status: String, _ date: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "status": .string(status), "project": .string("P \(id)"),
                                          "client": .string("Ward"), "date": .string(date), "rev": .number(1)]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        return [
            "settings": .object(["shopName": .string("Ward"), "currency": .string("SAR")]),
            "printLog": .array([
                job("O-1", "pending", "2026-10-20"),
                job("Q-1", "quote", "2026-10-18", ["price": .number(120), "quoteExpiresAt": .string("2026-10-25")]),
                job("Q-2", "quote", "2026-10-22", ["price": .number(40)]),
                job("O-2", "completed", "2026-10-23"),
                job("O-3", "cancelled", "2026-10-24"),
                job("Q-3", "quote", "2026-10-22"),
                job("Q-4", "pending", "2026-10-26", ["quoteAcceptedAt": .string("2026-10-26")]),
            ]),
        ]
    }

    private func record(_ id: String) throws -> [String: JSONValue] {
        guard case .array(let rows)? = try book.read()["printLog"] else { return [:] }
        for row in rows {
            if case .object(let o) = row, case .string(let rid)? = o["id"], rid == id { return o }
        }
        return [:]
    }

    // MARK: - The list

    func testTheListHoldsOnlyOpenQuotesNewestFirst() async throws {
        let read = try await BookReader(book: book).recentOrders(limit: 200, status: OrderStatus.quote.rawValue)
        let quotes = QuoteList.select(read)
        // Q-4 was a quote and is a job now; it is not on the list.
        XCTAssertEqual(quotes.map(\.id), ["Q-3", "Q-2", "Q-1"], "newest first; a same-day tie keeps one order")
        let q1 = try XCTUnwrap(quotes.first { $0.id == "Q-1" })
        XCTAssertEqual(q1.price, 120)
        XCTAssertEqual(q1.quoteExpiresAt, "2026-10-25", "the last day is read from the record")
        XCTAssertNil(quotes.first { $0.id == "Q-2" }?.quoteExpiresAt)
    }

    func testSelectionLeavesEverythingButQuotesOut() async throws {
        // Handed the whole book (an older reader, or `/api/orders` without a
        // filter), the list still holds quotes alone.
        let everything = try await BookReader(book: book).recentOrders(limit: 200)
        XCTAssertEqual(Set(QuoteList.select(everything).map(\.id)), ["Q-1", "Q-2", "Q-3"])
    }

    func testAQuoteExpiresAfterItsLastDayNotOnIt() throws {
        let entries = try JSONDecoder().decode([OrderLogEntry].self, from: Data("""
            [{"id":"Q-1","status":"quote","quoteExpiresAt":"2026-10-25"},
             {"id":"Q-2","status":"quote"}]
            """.utf8))
        XCTAssertFalse(entries[0].isQuoteExpired(today: "2026-10-25"), "the last day is still good")
        XCTAssertTrue(entries[0].isQuoteExpired(today: "2026-10-26"))
        XCTAssertFalse(entries[1].isQuoteExpired(today: "2030-01-01"), "no last day never expires")
    }

    func testTheSampleShopHasQuotesTheQueueLeavesOut() async throws {
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope())
        let reader = BookReader(book: book)
        let quotes = QuoteList.select(try await reader.recentOrders(limit: 200, status: "quote"))
        XCTAssertFalse(quotes.isEmpty, "the sample shows the Quotes list with something on it")
        XCTAssertTrue(quotes.allSatisfy { $0.price != nil && $0.quoteExpiresAt != nil })
        let queue = try await reader.queue()
        XCTAssertTrue(Set(queue.map(\.id)).isDisjoint(with: quotes.map(\.id)), "quotes are not in the queue")
    }

    // MARK: - The answers

    func testApproveMakesAPendingJobStampedAcceptedToday() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T09:00:00Z")!
        XCTAssertEqual(QuoteAnswer.approve.status, "pending")
        try await BookWriter(book: book).setOrderStatus(orderId: "Q-1", to: QuoteAnswer.approve.status, engine: engine, now: now)
        let q = try record("Q-1")
        XCTAssertEqual(q["status"], .string("pending"))
        XCTAssertEqual(q["quoteAcceptedAt"], .string(BookWriter.localDay(now)))
        XCTAssertNil(q["cancelledAt"])
    }

    func testDeclineCancelsAndKeepsTheQuoteUnaccepted() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T09:00:00Z")!
        XCTAssertEqual(QuoteAnswer.decline.status, "cancelled")
        try await BookWriter(book: book).setOrderStatus(orderId: "Q-2", to: QuoteAnswer.decline.status, engine: engine, now: now)
        let q = try record("Q-2")
        XCTAssertEqual(q["status"], .string("cancelled"))
        XCTAssertEqual(q["cancelledAt"], .string(BookWriter.localDay(now)))
        XCTAssertNil(q["quoteAcceptedAt"], "a declined quote was never accepted")
        XCTAssertNotNil(q["price"], "declined is kept, not deleted: what was offered stays on record")
    }

    func testAnAnsweredQuoteLeavesTheList() async throws {
        let writer = BookWriter(book: book)
        try await writer.setOrderStatus(orderId: "Q-1", to: QuoteAnswer.approve.status, engine: engine)
        try await writer.setOrderStatus(orderId: "Q-2", to: QuoteAnswer.decline.status, engine: engine)
        let quotes = QuoteList.select(try await BookReader(book: book).recentOrders(limit: 200, status: "quote"))
        XCTAssertEqual(quotes.map(\.id), ["Q-3"])
    }
}
