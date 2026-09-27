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
        XCTAssertEqual(pulse.currency, "USD")
    }

    func testTheSamplePrintersMoveWithTheClock() {
        let now = Date()
        let a = SampleShop.liveReadings(now: now), b = SampleShop.liveReadings(now: now.addingTimeInterval(600))
        let printing = a.filter(\.isPrinting)
        XCTAssertEqual(printing.count, 2)
        for r in printing { XCTAssertTrue((1...100).contains(r.progress ?? -1)) }
        XCTAssertNotEqual(a.first?.progress, b.first?.progress, "ten minutes later it has moved")
    }
}
