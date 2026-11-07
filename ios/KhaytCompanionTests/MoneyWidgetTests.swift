import XCTest
import SwiftUI
import KhaytCore
@testable import KhaytCompanion

/// The Money widget and every widget's age.
///
/// The figures are the app's own (`WidgetFigures`): Owed is Home's, Earned
/// today is End of Day's, Low stock is the shopping list's rule. These tests
/// hold them to those numbers on the sample shop, hold the staleness rule, and
/// read a snapshot written before `writtenAt` existed.
///
/// Run with `TEST_RUNNER_KHAYT_SHOTS=<dir>` and the widget is written there as
/// PNGs (small and medium; English and Arabic; light and dark; fresh, old,
/// locked and with no shop). Without it the renders are only checked to draw.
@MainActor
final class MoneyWidgetTests: XCTestCase {
    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "money-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope())
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - The figures are the app's

    func testTheFiguresAreHomesAndEndOfDaysOnTheSampleShop() async throws {
        let reader = BookReader(book: book)
        let pulse = try await reader.pulse()
        let day = try await reader.endOfDay()
        let store = try await reader.wholeBook()
        let list = ShopShoppingList(store: store, shopName: "Sample")
        let asOf = Date()

        let money = try XCTUnwrap(WidgetFigures.money(pulse: pulse, day: day,
                                                      lowStock: WidgetFigures.lowStock(list), asOf: asOf))
        XCTAssertEqual(money.owed, pulse.owed, "Owed is Home's figure")
        XCTAssertGreaterThan(money.owed, 0, "the sample shop has money owed, so this compares something")
        XCTAssertEqual(money.unpaid, pulse.unpaid)
        XCTAssertEqual(money.takingsToday, day.report.revenue, "Earned today is End of Day's figure")
        XCTAssertEqual(money.currency, pulse.currency)
        XCTAssertEqual(money.mark, Money.mark(pulse.currency ?? ""))
        XCTAssertEqual(money.owedText, WidgetFigures.figure(pulse.owed))
        XCTAssertEqual(money.takingsText, WidgetFigures.figure(day.report.revenue))
        XCTAssertEqual(money.asOf, asOf)
    }

    /// Low stock is `ReorderRules.isLowStock` over the shelf: every spool at or
    /// under its reorder point, once.
    func testLowStockIsTheReorderRule() async throws {
        let store = try await BookReader(book: book).wholeBook()
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { settings = s }
        let expected = JSRead.rows(store, "inventory").filter { row in
            guard case .object(let item) = row else { return false }
            return ReorderRules.isLowStock(item, settings: settings)
        }.count
        let list = ShopShoppingList(store: store, shopName: "")
        XCTAssertEqual(WidgetFigures.lowStock(list), expected)
        XCTAssertEqual(expected, 3, "the sample shop keeps three low spools")
    }

    /// A shop whose own reorder point is set: the widget follows it, not a
    /// fixed 200 g.
    func testLowStockFollowsTheShopsReorderPoint() {
        let store: [String: JSONValue] = [
            "settings": .object(["lowStockThreshold": .number(500)]),
            "inventory": .array([
                .object(["id": .string("a"), "material": .string("PLA"), "weight": .number(450)]),
                .object(["id": .string("b"), "material": .string("PETG"), "weight": .number(900)]),
                .object(["id": .string("c"), "material": .string("TPU"), "weight": .number(300), "reorderPoint": .number(250)]),
            ]),
        ]
        XCTAssertEqual(WidgetFigures.lowStock(ShopShoppingList(store: store, shopName: "")), 1,
                       "450 g is under the shop's 500 g; 300 g is over its own 250 g")
    }

    func testAMissingFigureMeansNoFigures() async throws {
        let reader = BookReader(book: book)
        let pulse = try await reader.pulse()
        let day = try await reader.endOfDay()
        XCTAssertNil(WidgetFigures.money(pulse: nil, day: day, lowStock: 1, asOf: Date()))
        XCTAssertNil(WidgetFigures.money(pulse: pulse, day: nil, lowStock: 1, asOf: Date()))
        XCTAssertNil(WidgetFigures.money(pulse: pulse, day: day, lowStock: nil, asOf: Date()))
    }

    /// Western digits on an Arabic phone, as Home's hero.
    func testFiguresAreWrittenWithWesternDigits() {
        let text = WidgetFigures.figure(12345.6)
        XCTAssertTrue(text.allSatisfy { $0.isASCII }, text)
        XCTAssertTrue(text.contains("12"), text)
    }

    // MARK: - Staleness

    func testFiguresTurnOldAfterAQuarterOfAnHour() {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(WidgetFreshness.isStale(asOf, now: asOf))
        XCTAssertFalse(WidgetFreshness.isStale(asOf, now: asOf.addingTimeInterval(14 * 60)))
        XCTAssertTrue(WidgetFreshness.isStale(asOf, now: asOf.addingTimeInterval(16 * 60)))
        XCTAssertEqual(WidgetFreshness.opacity(stale: false), 1)
        XCTAssertLessThan(WidgetFreshness.opacity(stale: true), 1)
    }

    /// The widget's timeline has an entry for the moment the figures turn old,
    /// so they grey with the app closed.
    func testTheTimelineGreysOnTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = WidgetFreshness.entryDates(asOf: now.addingTimeInterval(-5 * 60), now: now)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates[0], now)
        XCTAssertTrue(WidgetFreshness.isStale(now.addingTimeInterval(-5 * 60), now: dates[1]))
        XCTAssertEqual(WidgetFreshness.entryDates(asOf: now.addingTimeInterval(-3600), now: now), [now], "already old")
        XCTAssertEqual(WidgetFreshness.entryDates(asOf: nil, now: now), [now])
    }

    /// The age is the older of what the data is as of and when it was written:
    /// a book an hour old, written a minute ago, is an hour old.
    func testTheAgeIsTheOlderOfTheTwo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var s = snapshot(updatedAt: now.addingTimeInterval(-3600))
        s.writtenAt = now.addingTimeInterval(-60)
        XCTAssertEqual(WidgetFreshness.asOf(s), now.addingTimeInterval(-3600))
        s.updatedAt = now
        XCTAssertEqual(WidgetFreshness.asOf(s), now.addingTimeInterval(-60))
    }

    /// A snapshot written by a build before `writtenAt` and `money` still reads.
    func testASnapshotFromBeforeWrittenAtStillReads() throws {
        let old = #"""
        {"shopName":"Tuwaiq 3D","queued":8,"printing":2,"post":1,"qc":3,"completedToday":5,
         "connected":true,"updatedAt":800000000,
         "prints":[{"id":"M1","name":"X1C","progress":62,"eta":"1h 29m"}]}
        """#
        let s = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(s.writtenAt)
        XCTAssertNil(s.money)
        XCTAssertEqual(s.queued, 8)
        XCTAssertEqual(WidgetFreshness.asOf(s), Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    /// And one with the money round-trips whole.
    func testASnapshotWithMoneyRoundTrips() throws {
        var s = snapshot(updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        s.writtenAt = Date(timeIntervalSinceReferenceDate: 800_000_060)
        s.money = sampleMoney(asOf: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.money, s.money)
        XCTAssertEqual(back.writtenAt, s.writtenAt)
    }

    /// Saving stamps when it was written.
    func testSavingStampsWrittenAt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: WidgetSnapshotStore.appGroupID))
        let key = "khayt.widget.snapshot"
        let before = defaults.data(forKey: key)
        defer {
            if let before { defaults.set(before, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let at = Date(timeIntervalSinceReferenceDate: 800_000_123)
        WidgetSnapshotStore.save(snapshot(updatedAt: at.addingTimeInterval(-30)), now: at)
        XCTAssertEqual(WidgetSnapshotStore.load()?.writtenAt, at)
    }

    // MARK: - The face

    private var widgetBundle: Bundle {
        let url = Bundle.main.builtInPlugInsURL!.appending(path: "KhaytWidgetExtension.appex")
        return Bundle(url: url) ?? .main
    }

    private func snapshot(updatedAt: Date, money: WidgetMoney? = nil) -> WidgetSnapshot {
        WidgetSnapshot(shopName: "Tuwaiq 3D", queued: 8, printing: 2, post: 1, qc: 3, completedToday: 5,
                       connected: true, updatedAt: updatedAt, prints: nil, writtenAt: updatedAt, money: money)
    }

    private func sampleMoney(asOf: Date) -> WidgetMoney {
        WidgetMoney(takingsToday: 1240, owed: 3460.5, unpaid: 4, lowStock: 3, currency: "SAR",
                    takingsText: "1,240", owedText: "3,461", mark: Money.mark("SAR"), asOf: asOf)
    }

    func testTheWidgetDrawsEveryStateInBothLanguagesAndAppearances() throws {
        let out = ProcessInfo.processInfo.environment["KHAYT_SHOTS"].map { URL(filePath: $0) }
        let now = Date()
        let states: [(String, WidgetSnapshot?, Bool)] = [
            ("fresh", snapshot(updatedAt: now.addingTimeInterval(-4 * 60), money: sampleMoney(asOf: now.addingTimeInterval(-4 * 60))), false),
            ("stale", snapshot(updatedAt: now.addingTimeInterval(-2 * 3600), money: sampleMoney(asOf: now.addingTimeInterval(-2 * 3600))), false),
            ("locked", snapshot(updatedAt: now.addingTimeInterval(-4 * 60), money: sampleMoney(asOf: now.addingTimeInterval(-4 * 60))), true),
            ("noshop", nil, false),
        ]
        for (name, snap, locked) in states {
            for size in [KhaytMoneyView.Size.small, .medium] {
                for lang in ["en", "ar"] {
                    for dark in [false, true] {
                        let width: CGFloat = size == .small ? 170 : 364
                        let face = KhaytMoneyView(snapshot: snap, now: now, size: size, bundle: widgetBundle)
                            .padding(16)
                            .frame(width: width, height: 170)
                            .background(PrintActivityLook.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .redacted(reason: locked ? .privacy : [])
                            .padding(12)
                            .background(dark ? Color.black : Color(white: 0.82))
                            .environment(\.locale, Locale(identifier: lang))
                            .environment(\.layoutDirection, lang == "ar" ? .rightToLeft : .leftToRight)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let renderer = ImageRenderer(content: face)
                        renderer.scale = 3
                        let image = try XCTUnwrap(renderer.uiImage, "\(name) \(lang) did not draw")
                        XCTAssertGreaterThan(image.size.height, 150)
                        if let out, let png = image.pngData() {
                            let file = "widget-money-\(size == .small ? "small" : "medium")-\(name)-\(lang)-\(dark ? "dark" : "light").png"
                            try png.write(to: out.appending(path: file))
                        }
                    }
                }
            }
        }
    }
}
