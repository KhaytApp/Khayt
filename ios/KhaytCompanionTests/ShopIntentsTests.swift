import XCTest
@testable import KhaytCompanion

/// What Siri says when asked how much filament is left — from the book.
final class ShopIntentsTests: XCTestCase {
    private func spool(_ id: String, _ material: String, _ grams: Double) -> InventorySpool {
        let json = #"{"id":"\#(id)","material":"\#(material)","weight":\#(grams)}"#
        return try! JSONDecoder().decode(InventorySpool.self, from: Data(json.utf8))
    }

    override func setUp() { L10n.setLanguage(.en) }
    override func tearDown() { L10n.setLanguage(.system) }

    func testANamedMaterialIsSummedAcrossItsSpoolsWhateverTheCase() {
        let shelf = [spool("a", "PLA", 180), spool("b", "PLA", 640), spool("c", "PETG", 500)]
        XCTAssertEqual(FilamentLeftIntent.answer(shelf, material: "pla"), "820 g of pla left, on 2 spool(s).")
    }

    func testAMaterialNotOnTheShelfSaysSo() {
        XCTAssertEqual(FilamentLeftIntent.answer([spool("a", "PLA", 180)], material: "ABS"), "No ABS on the shelf.")
    }

    func testNoMaterialNamedGivesTheWholeShelf() {
        let shelf = [spool("a", "PLA", 180), spool("c", "PETG", 500)]
        XCTAssertEqual(FilamentLeftIntent.answer(shelf, material: nil), "PETG: 500 g · PLA: 180 g")
        XCTAssertEqual(FilamentLeftIntent.answer([], material: nil), "The shelf is empty.")
    }
}
