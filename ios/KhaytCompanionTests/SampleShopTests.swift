import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The sample shop is read through the same rules as a real one — if these
/// pass, a reviewer sees a working app, not an empty one.
final class SampleShopTests: XCTestCase {
    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope())
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testEveryScreenHasSomethingToShow() async throws {
        let reader = BookReader(book: book)
        let queue = try await reader.queue()
        XCTAssertEqual(Set(queue.map(\.status)), ["pending", "printing", "post", "qc"], "every stage of the board is in use")
        XCTAssertTrue(queue.contains(where: \.isOverdue), "one job is late, so Home's late rail shows")
        let spools = try await reader.inventory()
        XCTAssertEqual(spools.count, 6)
        XCTAssertEqual(spools.filter(\.isLowStock).count, 2)
        let clients = try await reader.clients()
        let waiting = try await reader.waitingList()
        let machines = try await reader.machines()
        XCTAssertFalse(clients.isEmpty)
        XCTAssertEqual(waiting.count, 2)
        XCTAssertEqual(machines.count, 3)
        XCTAssertTrue(book.holdsAll("printLog"), "the sample is the whole shop, so every figure is answerable")
    }

    func testTheMoneyOnPulseIsTheShopsOwnRule() async throws {
        let pulse = try await BookReader(book: book).pulse()
        XCTAssertGreaterThan(pulse.owed, 0)
        XCTAssertNotNil(pulse.thisMonth, "a whole book answers the month")
        // Four finished, paid jobs inside the last six weeks: a reviewer's
        // first screen must not say the shop earned nothing this year.
        XCTAssertGreaterThan(pulse.thisYear ?? 0, 0, "year=\(String(describing: pulse.thisYear)) month=\(String(describing: pulse.thisMonth))")
        XCTAssertEqual(pulse.currency, "USD")
    }

    /// A phone set to Saudi Arabia runs Umm al-Qura. Home keyed this month as
    /// "1448-04" against the P&L's "2026-10" rows and showed 0 and 0.
    func testASaudiPhonesCalendarStillCountsTheShopsMoney() async throws {
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        let reader = BookReader(book: book)
        let saudi = try await reader.pulse(calendar: hijri)
        let plain = try await reader.pulse(calendar: Calendar(identifier: .gregorian))
        XCTAssertGreaterThan(saudi.thisYear ?? 0, 0)
        XCTAssertEqual(saudi.thisYear, plain.thisYear)
        XCTAssertEqual(saudi.thisMonth, plain.thisMonth)
    }

    func testTheSamplePrintersMoveWithTheClock() {
        let now = Date()
        let a = SampleShop.liveReadings(now: now), b = SampleShop.liveReadings(now: now.addingTimeInterval(600))
        let printing = a.filter(\.isPrinting)
        XCTAssertEqual(printing.count, 2)
        for r in printing { XCTAssertTrue((1...100).contains(r.progress ?? -1)) }
        XCTAssertNotEqual(a.first?.progress, b.first?.progress, "ten minutes later it has moved")
    }

    /// The sample shop has no address and no sign-in, by design. The gate in
    /// front of the tabs once asked for one of the two, so the button wrote
    /// the book and the phone stayed on the pairing screen.
    @MainActor
    func testOpeningTheSampleShopGetsPastPairing() {
        let defaults = UserDefaults.standard
        let keys = ["khayt.host", "khayt.paired", "khayt.sampleShop"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let settings = ConnectionSettings()
        settings.host = ""
        settings.isPaired = true
        settings.isSampleShop = false
        XCTAssertFalse(ContentView.hasAShop(settings: settings, signedInToCloud: false),
                       "paired to nothing is not a shop")
        settings.isSampleShop = true
        XCTAssertTrue(ContentView.hasAShop(settings: settings, signedInToCloud: false))
        settings.unpair()
        XCTAssertFalse(ContentView.hasAShop(settings: settings, signedInToCloud: false),
                       "leaving the sample shop goes back to pairing")
    }
}
