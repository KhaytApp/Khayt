import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * Scanning the barcode on a box of filament, and booking several in at once.
 *
 * No test here touches the network: the product database is a closure, and
 * each test hands it the answer it needs.
 */
final class BarcodeBookingTests: XCTestCase {

    // MARK: - The code itself

    func testTheCheckDigitIsChecked() {
        XCTAssertEqual(ProductBarcode.normalize("4006381333931"), "4006381333931")   // EAN-13
        XCTAssertEqual(ProductBarcode.normalize("036000291452"), "036000291452")     // UPC-A
        XCTAssertEqual(ProductBarcode.normalize("96385074"), "96385074")             // EAN-8
        // One digit misread is somebody else's product. Refused, not looked up.
        XCTAssertNil(ProductBarcode.normalize("4006381333932"))
        XCTAssertNil(ProductBarcode.normalize("036000291453"))
    }

    func testOnlyDigitsAreACode() {
        XCTAssertEqual(ProductBarcode.normalize(" 4006381 333931 "), "4006381333931")
        XCTAssertNil(ProductBarcode.normalize("https://example.com/4006381333931"))
        XCTAssertNil(ProductBarcode.normalize("LOT 4006381333931"))
        XCTAssertNil(ProductBarcode.normalize("12345"))
        XCTAssertNil(ProductBarcode.normalize(""))
    }

    func testUPCEIsTheUPCAItStandsFor() {
        // The standard's own worked example.
        XCTAssertEqual(ProductBarcode.expandUPCE("04252614"), "042100005264")
        XCTAssertEqual(ProductBarcode.normalize("04252614", kind: .upce), "042100005264")
    }

    func testAUSBoxAndAEuropeanBoxAreOneProduct() {
        // iOS reports a UPC-A as EAN-13 with a leading zero.
        XCTAssertTrue(ProductBarcode.sameProduct("036000291452", "0036000291452"))
        XCTAssertFalse(ProductBarcode.sameProduct("036000291452", "4006381333931"))
    }

    // MARK: - The shelf first

    private func spool(_ json: String) throws -> InventorySpool {
        try JSONDecoder().decode(InventorySpool.self, from: Data(json.utf8))
    }

    func testTheNewestMatchingRollIsTheOneCopied() throws {
        let shelf = [
            try spool(#"{"id":"A","material":"Sunlu PLA","barcode":"0036000291452","cost":70,"addedAt":"2026-01-01T00:00:00Z"}"#),
            try spool(#"{"id":"B","material":"Sunlu PLA","barcode":"036000291452","cost":82,"addedAt":"2026-08-01T00:00:00Z"}"#),
            try spool(#"{"id":"C","material":"Other","barcode":"4006381333931","addedAt":"2026-09-01T00:00:00Z"}"#),
        ]
        XCTAssertEqual(BarcodeLookup.onShelf("036000291452", in: shelf)?.id, "B",
                       "the latest box carries the latest price")
    }

    func testAGTINTypedIntoTheSKUBeforeThisFieldExistedIsFound() throws {
        let shelf = [try spool(#"{"id":"A","material":"PETG","sku":"4006381333931"}"#)]
        XCTAssertEqual(BarcodeLookup.onShelf("4006381333931", in: shelf)?.id, "A")
    }

    func testTheSameFilamentAgainCopiesTheBoxNotTheRoll() throws {
        let roll = try spool(#"""
        {"id":"A","material":"Sunlu PLA","brand":"Sunlu","color":"#FF0000","cost":82.5,
         "weight":140,"spoolWeight":1000,"printTemp":210,"bedTemp":60,"lot":"L9","sku":"SL-1"}
        """#)
        let d = SpoolDraft.again(from: roll, barcode: "036000291452")
        XCTAssertEqual(d.material, "Sunlu PLA")
        XCTAssertEqual(d.brand, "Sunlu")
        XCTAssertEqual(d.colorHex, "#FF0000")
        XCTAssertEqual(d.costValue, 82.5, "the price last paid is the best guess at this one")
        XCTAssertEqual(d.weightGrams, 1000, "a new box is full, not what is left on the old roll")
        XCTAssertEqual(d.printTemp, "210")
        XCTAssertEqual(d.lot, "", "a lot is one production run; a new box is usually another")
        XCTAssertEqual(d.barcode, "036000291452")
    }

    // MARK: - Then the database

    private final class Calls: @unchecked Sendable { var urls: [URL] = [] }

    private func lookup(status: Int, body: String, calls: Calls = Calls()) -> BarcodeLookup {
        var l = BarcodeLookup()
        l.fetch = { request in
            calls.urls.append(request.url!)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        return l
    }

    func testTheShelfIsAskedBeforeTheInternet() async throws {
        let calls = Calls()
        let shelf = [try spool(#"{"id":"A","material":"Sunlu PLA","barcode":"036000291452"}"#)]
        let found = await lookup(status: 200, body: "{}", calls: calls).lookUp("036000291452", shelf: shelf)
        guard case .onShelf(_, let from) = found else { return XCTFail("\(found)") }
        XCTAssertEqual(from.id, "A")
        XCTAssertTrue(calls.urls.isEmpty, "a roll on the shelf needs no lookup, and works offline")
    }

    func testAProductTitleIsReadLikeALabel() async throws {
        let calls = Calls()
        let body = #"{"code":"OK","total":1,"items":[{"ean":"6938936716785","title":"SUNLU PLA 3D Printer Filament 1.75mm 1KG Black","brand":"SUNLU"}]}"#
        let found = await lookup(status: 200, body: body, calls: calls).lookUp("6938936716785", shelf: [])
        guard case .inDatabase(let d, _) = found else { return XCTFail("\(found)") }
        XCTAssertEqual(d.barcode, "6938936716785")
        XCTAssertEqual(d.brand, "SUNLU")
        XCTAssertEqual(d.weightGrams, 1000)
        XCTAssertTrue(d.material.localizedCaseInsensitiveContains("PLA"), d.material)
        // The digits and nothing else leave the phone.
        let sent = try XCTUnwrap(calls.urls.first)
        XCTAssertEqual(sent.host, "api.upcitemdb.com")
        XCTAssertEqual(sent.query, "upc=6938936716785")
    }

    func testAnUnknownCodeStillOpensTheFormWithTheBarcode() async {
        let found = await lookup(status: 404, body: #"{"code":"NOT_FOUND"}"#).lookUp("4006381333931", shelf: [])
        guard case .notFound(let d, let reason) = found else { return XCTFail("\(found)") }
        XCTAssertEqual(d.barcode, "4006381333931")
        XCTAssertTrue(reason.contains("Not in the product database"), reason)
    }

    func testRunningOutOfLookupsIsNotTheSameAsNoSuchProduct() async {
        let found = await lookup(status: 429, body: "{}").lookUp("4006381333931", shelf: [])
        guard case .notFound(_, let reason) = found else { return XCTFail("\(found)") }
        XCTAssertTrue(reason.contains("could not be reached"), reason)
    }

    // MARK: - Several at once

    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    private func openBook() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "barcode-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
        try book.replace(with: ["settings": .object([:]), "inventory": .array([])], scope: nil)
        try book.markSynced()
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testTenBoxesAreTenSpoolsInOneWrite() async throws {
        try openBook()
        var d = SpoolDraft()
        d.material = "Sunlu PLA"
        d.cost = "82"
        d.barcode = "036000291452"
        let records = try await reader.newSpools(from: d, count: 10)
        try BookWriter(book: book).addSpools(records)

        guard case .array(let shelf)? = try book.read()["inventory"] else { return XCTFail() }
        XCTAssertEqual(shelf.count, 10)
        let ids = Set(records.compactMap { r -> String? in
            if case .string(let id)? = r["id"] { return id } else { return nil }
        })
        XCTAssertEqual(ids.count, 10, "each roll is its own spool")
        for r in records {
            XCTAssertEqual(r["barcode"], .string("036000291452"))
            XCTAssertEqual(r["cost"], .number(82))
        }
        let produced = try await reader.pendingChanges()
        XCTAssertEqual(try XCTUnwrap(produced).count, 10)
    }

    func testABatchWithARepeatedIdWritesNothing() async throws {
        try openBook()
        var d = SpoolDraft()
        d.material = "PLA"
        let one = try await reader.newSpool(from: d)
        XCTAssertThrowsError(try BookWriter(book: book).addSpools([one, one])) {
            XCTAssertEqual($0 as? BookWriter.Refusal, .idTaken)
        }
        guard case .array(let shelf)? = try book.read()["inventory"] else { return XCTFail() }
        XCTAssertTrue(shelf.isEmpty, "all of them or none")
    }

    func testFiftyIdsMintedInOneMillisecondAreAllDifferent() {
        let now = Date()
        XCTAssertEqual(Set(BookWriter.newSpoolIds(50, now: now)).count, 50)
    }

    func testAnInvalidBarcodeIsNotWrittenOntoTheRecord() async throws {
        try openBook()
        var d = SpoolDraft()
        d.material = "PLA"
        d.barcode = "12345"
        let record = try await reader.newSpool(from: d)
        XCTAssertNil(record["barcode"], "it would be matched against every future scan")
    }
}
