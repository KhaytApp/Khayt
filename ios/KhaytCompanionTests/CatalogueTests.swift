import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The phone's catalogue: the Mac's own rows from the book the phone keeps,
/// with the counted stock beside them.
@MainActor
final class CatalogueTests: XCTestCase {
    private var dir: URL!
    private var reader: BookReader!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let book = CompanionBook(directory: dir)
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope())
        reader = BookReader(book: book)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testTheCatalogueIsTheMacsRowsWithStock() async throws {
        let page = try await reader.catalogue(language: "en")
        XCTAssertEqual(page.currency, "USD")
        XCTAssertTrue(page.whole)
        let byId = Dictionary(uniqueKeysWithValues: page.items.map { ($0.id, $0) })
        XCTAssertEqual(byId.count, 4)

        let lamp = try XCTUnwrap(byId["PROD-S1"])
        XCTAssertEqual(lamp.row.name, "Desk lamp shade")
        XCTAssertEqual(lamp.row.final, 40, "38.40 rounded up to the next 5, as the Mac shows it")
        XCTAssertEqual(lamp.row.source, "rounded")
        XCTAssertTrue(lamp.row.thumbnail.hasPrefix("data:image/"))
        XCTAssertEqual(lamp.stock, 6)

        XCTAssertEqual(byId["PROD-S2"]?.stock, 0, "counted at none is out of stock")
        XCTAssertNil(byId["PROD-S3"]?.stock, "never counted is not stocked")
        XCTAssertEqual(byId["PROD-S3"]?.row.final, 25, "the shop's own price wins")
        XCTAssertEqual(CatalogueItemPage.reasonKey(try XCTUnwrap(byId["PROD-S3"]).row), "catalogue.price.override")

        let arabic = try await reader.catalogue(language: "ar")
        XCTAssertEqual(arabic.items.first { $0.id == "PROD-S1" }?.row.name, "غطاء مصباح مكتب")
    }

    func testSearchNeedsEveryWord() async throws {
        let items = try await reader.catalogue(language: "en").items
        XCTAssertEqual(BookReader.filter(items, query: "cable petg").map(\.id), ["PROD-S2"])
        XCTAssertEqual(BookReader.filter(items, query: "GIFTS").map(\.id), ["PROD-S3"], "the group counts")
        XCTAssertEqual(BookReader.filter(items, query: "").count, 4)
    }

    func testTheCustomerGetsTheProductAndThePrice() async throws {
        let items = try await reader.catalogue(language: "en").items
        let lamp = try XCTUnwrap(items.first { $0.id == "PROD-S1" })
        XCTAssertEqual(CatalogueItemPage.shareText(lamp.row, qty: 3, currency: "USD").components(separatedBy: "\n"), [
            "Desk lamp shade",
            L10n.format("calc.share.price", Money.text(120, "USD")),
            L10n.format("calc.share.each", 3, Money.text(40, "USD")),
        ])
    }

    func testTheCatalogueIsNeverSentFromThePhone() async throws {
        // A product changed here, by any path: a newer rev and a field gone.
        // Sync replaces whole records, and the phone's copy has no file paths,
        // so sending it would wipe the Mac's photos and documents.
        let book = CompanionBook(directory: dir.appendingPathComponent("send"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("send"), withIntermediateDirectories: true)
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope())
        try book.update { root in
            guard case .array(var rows)? = root["products"], case .object(var p) = rows[0] else { return }
            p["rev"] = .number(99); p["nameEn"] = .string("Changed on the phone")
            rows[0] = .object(p)
            rows.append(.object(["id": .string("PROD-NEW"), "nameEn": .string("Made on the phone"), "rev": .number(1)]))
            root["products"] = .array(rows)
        }
        let outbox = try await BookReader(book: book).pendingChanges()
        let sent = try XCTUnwrap(outbox)
        let collections = (sent.deltas + sent.tombstones).compactMap { d -> String? in
            if case .object(let o) = d, case .string(let c)? = o["collection"] { return c } else { return nil }
        }
        XCTAssertFalse(collections.contains("products"), "the phone must never send a product")
        XCTAssertTrue(sent.isEmpty)

        // And a product deleted on the phone sends no tombstone either.
        try book.update { root in root["products"] = .array([]) }
        let afterDelete = try await BookReader(book: book).pendingChanges()
        XCTAssertTrue(try XCTUnwrap(afterDelete).isEmpty)
    }

    func testACutCatalogueSaysHowMuchIsHere() async throws {
        var scope = SampleShop.scope()
        scope = BookScope.Taken(collections: scope.collections.merging(
            ["products": .init(whole: false, sent: 4, available: 2_400)]) { $1 }, omitted: [], takenAt: scope.takenAt)
        let book = CompanionBook(directory: dir.appendingPathComponent("cut"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("cut"), withIntermediateDirectories: true)
        try book.replace(with: SampleShop.book(), scope: scope)
        let page = try await BookReader(book: book).catalogue(language: "en")
        XCTAssertFalse(page.whole)
        XCTAssertEqual(page.available, 2_400)
    }

    func testABookWithoutProductsIsAnEmptyCatalogue() async throws {
        var store = SampleShop.book()
        store["products"] = nil
        let book = CompanionBook(directory: dir.appendingPathComponent("empty"))
        try book.replace(with: store, scope: SampleShop.scope())
        let page = try await BookReader(book: book).catalogue(language: "en")
        XCTAssertTrue(page.items.isEmpty)
    }
}
