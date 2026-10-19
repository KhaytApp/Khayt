import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The phone's half of `GET /api/library` and `POST /api/library/{id}/estimate`:
/// reading the Mac's answer, and the sample shop's library, which follows the
/// same search rules so the screen is drawn the same way for both.
@MainActor
final class LibraryTests: XCTestCase {
    func testAPageReadsAndOneBadModelDoesNotSinkIt() throws {
        let json = #"""
        {"total":3,"offset":0,
         "folders":[{"path":"Kings/Large","count":12},{"nope":1}],
         "items":[
           {"id":"PF-1","name":"Lantern","folder":"Home","tags":["gift"],"ext":"3MF","favorite":true,"thumb":true,
            "estimable":true,"printTimeMins":318,"grams":154,"plates":[{"index":1,"name":"Body","grams":112},{"bad":true}]},
           {"name":"no id"},
           {"id":"PF-2","name":"  ","grams":0,"printTimeMins":null}
         ]}
        """#
        let page = try JSONDecoder().decode(LibraryPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.folders, [LibraryFolder(path: "Kings/Large", name: "Large", count: 12)], "the name falls back to the last level")
        XCTAssertEqual(page.items.map(\.id), ["PF-1", "PF-2"])
        let lantern = page.items[0]
        XCTAssertEqual(lantern.ext, "3mf")
        XCTAssertEqual(lantern.plates.map(\.index), [1])
        XCTAssertTrue(lantern.favorite && lantern.thumb && lantern.estimable)
        let blank = page.items[1]
        XCTAssertEqual(blank.name, "PF-2", "an untitled model shows its id rather than nothing")
        XCTAssertNil(blank.grams, "a recorded 0 g is a slicer that measured nothing")
        XCTAssertFalse(blank.estimable, "unsaid means the Mac did not offer to measure it")
    }

    func testSearchNeedsEveryWordIgnoringCaseAndDiacritics() {
        let (folders, hits) = SampleLibrary.search(SampleLibrary.items, query: "abdulaziz RELIEF", folder: "")
        XCTAssertEqual(hits.map(\.id), ["PF-sample-king-1"])
        XCTAssertTrue(folders.isEmpty, "a search spans the whole library")
        XCTAssertEqual(Set(SampleLibrary.search(SampleLibrary.items, query: "gift", folder: "Parts").1.map(\.id)),
                       ["PF-sample-lantern", "PF-sample-dallah", "PF-sample-falcon"],
                       "tags and folder names both count, and the open folder does not narrow a search")
        XCTAssertTrue(SampleLibrary.search(SampleLibrary.items, query: "lantern zebra", folder: "").1.isEmpty)
        let accented = SampleLibrary.search(SampleLibrary.items, query: "SPÏRAL", folder: "").1
        XCTAssertEqual(accented.map(\.id), ["PF-sample-vase"])
    }

    func testAFolderListsItsOwnModelsAndCountsEverythingUnderASubFolder() {
        let (top, here) = SampleLibrary.search(SampleLibrary.items, query: "", folder: "")
        XCTAssertTrue(here.isEmpty, "every sample model is filed in a folder")
        XCTAssertEqual(top.map(\.name), ["Gifts", "Home", "Parts", "Saudi Kings"])
        XCTAssertEqual(top.first { $0.path == "Home" }?.count, 2, "Home's own model and the one under Home/Lighting")

        let (sub, homeItems) = SampleLibrary.search(SampleLibrary.items, query: "", folder: "Home")
        XCTAssertEqual(homeItems.map(\.id), ["PF-sample-vase"], "only what is filed directly here")
        XCTAssertEqual(sub, [LibraryFolder(path: "Home/Lighting", name: "Lighting", count: 1)])
        XCTAssertTrue(SampleLibrary.search(SampleLibrary.items, query: "", folder: "Hom").0.isEmpty,
                      "a folder is a path, not a prefix")
    }

    func testFavouritesComeFirst() {
        let gifts = SampleLibrary.search(SampleLibrary.items, query: "", folder: "Gifts").1
        XCTAssertEqual(gifts.map(\.name), ["Dallah coffee pot", "Falcon hood"])
        XCTAssertTrue(gifts[0].favorite)
    }

    func testPagingSlicesTheSameOrder() {
        let all = SampleLibrary.page(query: "a", folder: "", limit: 50)
        let first = SampleLibrary.page(query: "a", folder: "", offset: 0, limit: 2)
        let rest = SampleLibrary.page(query: "a", folder: "", offset: 2, limit: 50)
        XCTAssertEqual(first.total, all.total)
        XCTAssertEqual((first.items + rest.items).map(\.id), all.items.map(\.id))
    }

    func testTheRowLineShowsRecordedFiguresOnly() throws {
        let lantern = try XCTUnwrap(SampleLibrary.items.first { $0.id == "PF-sample-lantern" })
        let line = try XCTUnwrap(LibraryItemPage.figures(lantern))
        XCTAssertTrue(line.contains("154"), line)
        XCTAssertTrue(line.contains("PLA Silk"), line)
        let falcon = try XCTUnwrap(SampleLibrary.items.first { $0.id == "PF-sample-falcon" })
        XCTAssertNil(LibraryItemPage.figures(falcon), "a material alone is not figures; the row shows the folder")
    }

    func testTheCalculatorStartsFromTheModel() {
        let calc = PhoneCalculator()
        calc.shelf.spools = [
            .init(costing: .init(id: "S-PETG", material: "PETG", cost: 25, spoolWeight: 1000, color: nil), label: "PETG", hex: nil),
            .init(costing: .init(id: "S-PLA", material: "PLA", cost: 20, spoolWeight: 1000, color: nil), label: "PLA", hex: nil),
        ]
        calc.apply(CalculatorSeed(grams: 154, hours: 5.3, qty: 3, material: "PLA Silk"))
        XCTAssertEqual(calc.lines[0].grams, "154")
        XCTAssertEqual(calc.hours, "5.3")
        XCTAssertEqual(calc.qty, 3)
        XCTAssertEqual(calc.lines[0].spoolId, "S-PLA", "PLA Silk is printed from a PLA spool")

        let other = PhoneCalculator()
        other.apply(CalculatorSeed(grams: nil, hours: nil, qty: 0, material: "Nylon"))
        XCTAssertEqual(other.lines[0].grams, "")
        XCTAssertEqual(other.qty, 1)
        XCTAssertNil(other.lines[0].spoolId)
    }
}
