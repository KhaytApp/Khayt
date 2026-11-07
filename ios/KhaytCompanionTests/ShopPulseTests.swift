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

    /// `cut` is the day a cut book was cut at (`Held.keptAfter`): every job
    /// left on the Mac is that old or older.
    private func load(_ orders: [JSONValue], whole: Bool, cut: String? = nil) throws {
        let taken = BookScope.Taken(collections: ["printLog": .init(whole: whole, sent: orders.count, available: whole ? orders.count : 999,
                                                                    keptAfter: cut)],
                                    omitted: ["expenses"], takenAt: "2026-09-18T11:00:00.000Z")
        try book.replace(with: ["settings": .object(["currency": .string("SAR")]), "printLog": .array(orders), "clients": .array([])],
                         scope: taken)
    }

    func testTheMonthIsAnsweredWhenTheWindowReachesPastItsFirstDay() async throws {
        // The window reaches back to 14 June: September is covered, the year is not.
        try load([order("A", "completed", date: "2026-06-14", price: 50),
                  order("B", "completed", date: "2026-09-10", price: 400),
                  order("C", "printing", date: "2026-09-17", price: 120)], whole: false, cut: "2026-06-13")
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertNotNil(pulse.thisMonth, "the window reaches past 1 September")
        XCTAssertNil(pulse.thisYear, "it does not reach 1 January — the year lives on the Mac")
        XCTAssertEqual(pulse.currency, "SAR")
    }

    func testAWindowThatStartsThisMonthCannotAnswerTheMonth() async throws {
        try load([order("B", "completed", date: "2026-09-10", price: 400)], whole: false, cut: "2026-09-09")
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertNil(pulse.thisMonth, "a zero or a partial month here would be an answer, and a wrong one")
        XCTAssertNil(pulse.thisYear)
    }

    /// One old job in a cut book — folded in by a cloud change, or kept
    /// because it still owes — made "This year" read as complete.
    func testOneOldJobDoesNotMakeTheYearComplete() async throws {
        try load([order("OLD", "completed", date: "2021-02-01", price: 30),
                  order("B", "completed", date: "2026-09-10", price: 400)], whole: false, cut: "2026-06-13")
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertNotNil(pulse.thisMonth)
        XCTAssertNil(pulse.thisYear, "the cut was made in June: January to June is on the Mac")
    }

    /// A scope from an older Mac does not say where it was cut, so only a
    /// whole book can answer a period.
    func testACutWithNoRecordedDayAnswersNoPeriod() async throws {
        try load([order("OLD", "completed", date: "2021-02-01", price: 30)], whole: false)
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertNil(pulse.thisMonth)
        XCTAssertNil(pulse.thisYear)
    }

    func testAWholeBookAnswersEverything() async throws {
        try load([order("B", "completed", date: "2026-09-10", price: 400)], whole: true)
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertNotNil(pulse.thisMonth)
        XCTAssertNotNil(pulse.thisYear)
    }

    func testTheSampleShopHasTakingsThisMonthAndThisYearWhicheverDayItOpens() async throws {
        // The sample shop is what the website photographs and a new user sees
        // first. Its newest completed job was dated nine days back, so on the
        // first nine days of every month Home read "This month 0".
        for stamp in ["2026-11-01T08:00:00Z", "2027-01-01T08:00:00Z", "2026-11-05T08:00:00Z"] {
            let day = ISO8601DateFormatter().date(from: stamp)!
            try book.replace(with: SampleShop.book(now: day), scope: SampleShop.scope(now: day))
            let pulse = try await BookReader(book: book).pulse(now: day)
            XCTAssertGreaterThan(pulse.thisMonth ?? 0, 0, "This month on \(stamp)")
            XCTAssertGreaterThan(pulse.thisYear ?? 0, 0, "This year on \(stamp)")
        }
        // Done today reads the shop's real day, so it is checked on today's sample.
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope(now: Date()))
        let today = try await BookReader(book: book).pulse()
        XCTAssertEqual(today.doneToday, 1, "the job finished today is counted")
    }

    func testOwedCountsEveryJobThatCanOweByTheShopsOwnRule() async throws {
        // Paid is `paidAmount`, as `lib/order-money.js` reads it; there is no
        // status label that settles an order. A finished job still owes until
        // it is paid (`lib/dashboard-facts.js`, the Mac's `Order.owesAtAll`).
        try load([order("C", "printing", date: "2026-09-17", price: 120),
                  order("D", "pending", date: "2026-09-17", price: 80, paid: 80),
                  order("B", "completed", date: "2026-09-10", price: 400),
                  order("Q", "quote", date: "2026-09-10", price: 900),
                  order("X", "cancelled", date: "2026-09-10", price: 700)], whole: false)
        let pulse = try await BookReader(book: book).pulse(now: now)
        XCTAssertEqual(pulse.unpaid, 2, "the paid one, the quote and the cancelled job owe nothing")
        XCTAssertEqual(pulse.owed, 520, accuracy: 0.001)
    }

    /// A job handed over and never paid for is the debt a shop most needs to
    /// chase, and Home's Owed and its "Who owes" list both left it out.
    func testADeliveredUnpaidJobIsOwedAndInWhoOwes() async throws {
        var voided = order("V", "delivered", date: "2026-09-02", price: 60)
        if case .object(var o) = voided { o["voidedAt"] = .string("2026-09-03"); voided = .object(o) }
        try load([order("DEL", "delivered", date: "2026-09-01", price: 250, paid: 50),
                  order("SHIP", "shipped", date: "2026-09-01", price: 30, paid: 30),
                  voided], whole: false)
        let reader = BookReader(book: book)
        let pulse = try await reader.pulse(now: now)
        XCTAssertEqual(pulse.owed, 200, accuracy: 0.001)
        XCTAssertEqual(pulse.unpaid, 1)
        let owing = try await reader.owing()
        XCTAssertEqual(owing.map(\.id), ["DEL"], "the delivered job is missing from Who owes")
        XCTAssertEqual(owing.first?.owed ?? 0, 200, accuracy: 0.001)
    }

    /// End of Day's waste and hours: a figure only when the phone holds the
    /// whole log, never the lines that happen to be on it.
    func testEndOfDayShowsWasteAndHoursOnlyFromAWholeLog() async throws {
        let today = Calendar.book.dayString(Date())
        let store: [String: JSONValue] = [
            "settings": .object(["currency": .string("SAR")]), "printLog": .array([]), "clients": .array([]),
            "wasteLog": .array([.object(["id": .string("W-1"), "date": .string(today), "grams": .number(12)])]),
            "timeEntries": .array([]),
        ]
        let cut = BookScope.Taken(collections: ["printLog": .init(whole: true, sent: 0, available: nil)],
                                  omitted: ["timeEntries", "wasteLog"], takenAt: "2026-11-07T00:00:00.000Z")
        try book.replace(with: store, scope: cut)
        var day = try await BookReader(book: book).endOfDay()
        XCTAssertFalse(day.holdsWaste, "the phone's own waste lines are not the day's waste")
        XCTAssertFalse(day.holdsTime)

        let whole = BookScope.Taken(collections: ["printLog": .init(whole: true, sent: 0, available: nil),
                                                  "wasteLog": .init(whole: true, sent: 1, available: nil),
                                                  "timeEntries": .init(whole: true, sent: 0, available: nil)],
                                    omitted: [], takenAt: "2026-11-07T00:00:00.000Z")
        try book.replace(with: store, scope: whole)
        day = try await BookReader(book: book).endOfDay()
        XCTAssertTrue(day.holdsWaste)
        XCTAssertTrue(day.holdsTime)
    }
}
