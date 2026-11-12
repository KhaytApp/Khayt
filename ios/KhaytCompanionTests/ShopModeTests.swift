import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * S4: the phone follows the shop's mode, and asks the shared map what each
 * screen does with it.
 *
 * Every decision here goes through the real engine (`KhaytEngine.simpleSurface`,
 * which reads `lib/feature-tiers.js` SIMPLE_MAP). Nothing below restates the
 * map; it checks the phone asks it, and draws what it answers.
 */
final class ShopModeTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "shopmode-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func engine() async throws -> KhaytEngine { try await BookReader(book: book).sharedEngine() }

    private func store(mode: String?) -> [String: JSONValue] {
        var settings: [String: JSONValue] = ["shopName": .string("Ward"), "currency": .string("SAR")]
        if let mode { settings["mode"] = .string(mode) }
        return ["settings": .object(settings), "printLog": .array([])]
    }

    // MARK: - The map

    func testEveryKeyThePhoneAsksAboutIsARowOfTheMap() async throws {
        let keys = try await engine().simpleSurfaceKeys()
        XCTAssertFalse(keys.isEmpty)
        for key in ShopMode.askedKeys {
            XCTAssertTrue(keys.contains(key), "the phone asks about `\(key)`, which SIMPLE_MAP does not have")
        }
    }

    func testASimpleShopGetsTheMapsAnswers() async throws {
        let m = await ShopMode.decide(mode: "simple", engine: try await engine())
        XCTAssertTrue(m.isSimple)
        XCTAssertEqual(m.surface("queue"), .reduced)
        // History and Quotes stay reachable in Simple: the jobs log is shown
        // and quoting is reduced, never Professional's alone.
        XCTAssertEqual(m.surface("jobsLog"), .full)
        XCTAssertEqual(m.surface("quote"), .reduced)
        XCTAssertEqual(m.surface("expenses"), .reduced)
        XCTAssertEqual(m.surface("machineUpkeep"), .professionalOnly)
        XCTAssertEqual(m.surface("modeBadge"), .full)
        XCTAssertEqual(m.surface("gatedLink"), .full)
        XCTAssertEqual(m.surface("customers"), .reduced)
        XCTAssertEqual(m.surface("inventory"), .reduced)
        XCTAssertEqual(m.surface("money"), .reduced)
        XCTAssertEqual(m.badgeKey, "mode.simple")
        // Bed Ready's old hobbyist word reads as Simple, by the engine's rule.
        let enthusiast = await ShopMode.decide(mode: "enthusiast", engine: try await engine())
        XCTAssertEqual(enthusiast.surface("machineUpkeep"), .professionalOnly)
    }

    func testProfessionalAbsentAndUnknownModesShowEverything() async throws {
        for mode in ["professional", nil, "turbo", "Simple"] as [String?] {
            let m = await ShopMode.decide(mode: mode, engine: try await engine())
            XCTAssertFalse(m.isSimple, "\(mode ?? "nil")")
            for key in ShopMode.askedKeys {
                XCTAssertEqual(m.surface(key), .full, "\(key) in \(mode ?? "no mode")")
            }
            XCTAssertEqual(m.badgeKey, "mode.professional")
        }
    }

    func testAKeyNobodyAskedIsFull() {
        XCTAssertEqual(ShopMode.professional.surface("no-such-row"), .full)
    }

    // MARK: - The book

    func testTheModeIsTheBooksAsItIsWritten() {
        XCTAssertEqual(ShopMode.mode(in: store(mode: "simple")), "simple")
        XCTAssertEqual(ShopMode.mode(in: store(mode: "Simple")), "Simple", "passed on, not normalised")
        XCTAssertNil(ShopMode.mode(in: store(mode: nil)))
        XCTAssertNil(ShopMode.mode(in: [:]))
    }

    func testNoBookIsProfessional() async {
        let mode = await BookReader(book: book).shopMode()
        XCTAssertEqual(mode, .professional)
        XCTAssertFalse(mode.isProfessionalOnly("machineUpkeep"))
    }

    func testABookWithNoModeIsProfessional() async throws {
        try book.replace(with: store(mode: nil), scope: nil)
        let mode = await BookReader(book: book).shopMode()
        XCTAssertFalse(mode.isSimple)
        XCTAssertEqual(mode.surface("queue"), .full)
    }

    func testASimpleBookIsSimple() async throws {
        try book.replace(with: store(mode: "simple"), scope: nil)
        let mode = await BookReader(book: book).shopMode()
        XCTAssertTrue(mode.isSimple)
        XCTAssertEqual(mode.surface("queue"), .reduced)
    }

    /// Care and Parts to buy open the gated card in Simple: the client the
    /// screens read says so once the book is Simple, and not without a book.
    @MainActor
    func testTheClientGatesCareInSimpleAndNotWithoutABook() async throws {
        try book.replace(with: store(mode: "simple"), scope: nil)
        let api = KhaytAPIClient(settings: ConnectionSettings(), book: book)
        api.refreshShopMode()
        for _ in 0..<100 where !api.shopMode.isSimple { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(api.shopMode.isProfessionalOnly("machineUpkeep"), "Care shows the gated card")
        XCTAssertTrue(api.shopMode.isReduced("expenses"))

        let live = KhaytAPIClient(settings: ConnectionSettings(), withBook: false)
        live.refreshShopMode()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(live.shopMode, .professional)
        XCTAssertFalse(live.shopMode.isProfessionalOnly("machineUpkeep"))
    }

    // MARK: - The sample shop

    func testTheSampleShopIsProfessionalUnlessTheDebugFlagSaysSimple() throws {
        XCTAssertNil(ShopMode.mode(in: SampleShop.book()), "the sample shop carries no mode")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shopmode-\(UUID().uuidString)"))
        XCTAssertNil(SampleShop.debugMode(defaults))
        defaults.set("simple", forKey: "KhaytShopMode")
        XCTAssertEqual(SampleShop.debugMode(defaults), "simple")
        XCTAssertEqual(ShopMode.mode(in: SampleShop.book(mode: SampleShop.debugMode(defaults))), "simple")
    }

    // MARK: - Simple's four stages

    func testTheFourStagesFileEveryStageAsTheBoardRuleDoes() {
        func f(_ s: String, shipped: Bool = false, delivered: Bool = false) -> SimpleBoard.Filing? {
            SimpleBoard.filing(status: s, shipped: shipped, delivered: delivered)
        }
        XCTAssertEqual(f("quote"), .init(column: .quote, note: nil))
        XCTAssertEqual(f("pending"), .init(column: .queued, note: nil))
        XCTAssertEqual(f("split"), .init(column: .queued, note: nil))
        XCTAssertEqual(f("on_hold"), .init(column: .queued, note: "on_hold"))
        XCTAssertEqual(f("printing"), .init(column: .printing, note: nil))
        XCTAssertEqual(f("post"), .init(column: .printing, note: "post"))
        XCTAssertEqual(f("qc"), .init(column: .printing, note: "qc"))
        XCTAssertEqual(f("completed"), .init(column: .ready, note: nil))
        XCTAssertEqual(f("completed", shipped: true), .init(column: .ready, note: "shipped"))
        XCTAssertEqual(f("completed", shipped: true, delivered: true), .init(column: .ready, note: "delivered"))
        XCTAssertEqual(f("shipped"), .init(column: .ready, note: "shipped"))
        XCTAssertEqual(f("delivered"), .init(column: .ready, note: "delivered"))
        XCTAssertNil(f("cancelled"))
        XCTAssertNil(f("failed"))
        XCTAssertNil(f("something-new"))
        XCTAssertEqual(SimpleBoard.Column.allCases, [.quote, .queued, .printing, .ready])
        // Active's chips in Simple: Quote is its own segment, so not a chip too.
        XCTAssertEqual(OrdersView.simpleActiveColumns, [.queued, .printing, .ready])
    }

    private func entries(_ rows: [[String: Any]]) throws -> [OrderLogEntry] {
        let data = try JSONSerialization.data(withJSONObject: rows)
        return try JSONDecoder().decode([OrderLogEntry].self, from: data)
    }

    func testTheBoardHoldsLiveWorkQuotesHeldAndFinishedJobsInStageOrder() throws {
        let queue = [
            QueueOrder(id: "J-2", project: "Lid", client: "Acme", status: "qc", machine: nil, machineId: nil,
                       dueDate: nil, priority: nil),
            QueueOrder(id: "J-1", project: "Arm", client: "Acme", status: "printing", machine: "X1C",
                       machineId: "M-1", dueDate: nil, priority: nil),
        ]
        let book = try entries([
            ["id": "J-1", "status": "printing", "project": "Arm", "date": "2026-11-10"],
            ["id": "J-2", "status": "qc", "project": "Lid", "date": "2026-11-09"],
            ["id": "Q-1", "status": "quote", "project": "Sign", "date": "2026-11-11"],
            ["id": "H-1", "status": "on_hold", "project": "Gear", "date": "2026-11-08"],
            ["id": "D-1", "status": "completed", "project": "Old", "date": "2026-10-01"],
            ["id": "D-2", "status": "completed", "project": "Sent", "date": "2026-11-01", "shippedAt": "2026-11-02T10:00:00Z"],
            ["id": "V-1", "status": "completed", "project": "Void", "date": "2026-11-05", "voidedAt": "2026-11-06"],
            ["id": "C-1", "status": "cancelled", "project": "Nope", "date": "2026-11-07"],
        ])
        let rows = SimpleBoard.rows(queue: queue, book: book)
        XCTAssertEqual(rows.map(\.id), ["Q-1", "H-1", "J-2", "J-1", "D-2", "D-1"])
        XCTAssertEqual(rows.first { $0.id == "J-1" }?.order.machineId, "M-1", "live work is the queue's own record")
        XCTAssertEqual(rows.first { $0.id == "J-2" }?.filing, .init(column: .printing, note: "qc"))
        XCTAssertEqual(rows.first { $0.id == "D-2" }?.filing, .init(column: .ready, note: "shipped"))
        XCTAssertEqual(rows.first { $0.id == "H-1" }?.filing, .init(column: .queued, note: "on_hold"))
    }

    func testReadyIsCappedNewestFirst() throws {
        let many = (0..<(SimpleBoard.readyCap + 5)).map { i in
            ["id": "D-\(i)", "status": "completed", "date": String(format: "2026-%02d-%02d", 1 + i / 28, 1 + i % 28)]
        }
        let rows = SimpleBoard.rows(queue: [], book: try entries(many))
        XCTAssertEqual(rows.count, SimpleBoard.readyCap)
        XCTAssertEqual(rows.first?.id, "D-\(SimpleBoard.readyCap + 4)")
    }

    // MARK: - This month's spending

    private let nov12: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 12; c.hour = 12
        return Calendar.gregorianHere.date(from: c)!
    }()

    func testThisMonthsExpensesAreSummedNetOfReclaimedTax() {
        let store: [String: JSONValue] = ["expenses": .array([
            .object(["date": .string("2026-11-01"), "category": .string("filament"), "amount": .number(115), "vatAmount": .number(15)]),
            .object(["date": .string("2026-11-12"), "category": .string("electricity"), "amount": .number(20)]),
            .object(["date": .string("2026-10-31"), "category": .string("filament"), "amount": .number(999)]),
            .object(["date": .string("2025-11-03"), "category": .string("filament"), "amount": .number(999)]),
        ])]
        XCTAssertEqual(MonthSpend.total(in: store, reclaimsTax: true, now: nov12), .init(amount: 120, count: 2))
        XCTAssertEqual(MonthSpend.total(in: store, reclaimsTax: false, now: nov12), .init(amount: 135, count: 2),
                       "a shop that is not registered reclaims nothing")
    }

    func testNoExpensesOnThePhoneHidesTheLine() {
        XCTAssertNil(MonthSpend.total(in: [:], reclaimsTax: false, now: nov12))
        XCTAssertEqual(MonthSpend.total(in: ["expenses": .array([])], reclaimsTax: false, now: nov12),
                       .init(amount: 0, count: 0))
    }

    func testTheSampleShopHasThisMonthsTwoExpenses() {
        let total = MonthSpend.total(in: SampleShop.book(), reclaimsTax: false)
        XCTAssertEqual(total, .init(amount: 120, count: 2))
    }

    // MARK: - Words

    func testTheNewWordsCountInEveryLanguage() {
        let before = L10n.currentLanguage
        defer { L10n.setLanguage(before) }
        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.count("simple.expenses.count", 1), "1 expense")
        XCTAssertEqual(L10n.count("simple.expenses.count", 2), "2 expenses")
        XCTAssertEqual(SimpleBoard.title(.ready), "Ready")
        XCTAssertEqual(SimpleBoard.title(.queued), "Pending")
        XCTAssertEqual(SimpleBoard.noteText("qc"), "In QC")
        L10n.setLanguage(.ar)
        XCTAssertEqual(L10n.count("simple.expenses.count", 2), "مصروفان")
    }
}
