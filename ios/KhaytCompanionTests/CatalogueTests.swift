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

    func testABookWithoutProductsIsAnEmptyCatalogue() async throws {
        var store = SampleShop.book()
        store["products"] = nil
        let book = CompanionBook(directory: dir.appendingPathComponent("empty"))
        try book.replace(with: store, scope: SampleShop.scope())
        let page = try await BookReader(book: book).catalogue(language: "en")
        XCTAssertTrue(page.items.isEmpty)
    }
}
