import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The library's Colour and File type menus: the query the phone sends the
/// Mac, the `facets` it reads back, and the same contract answered on the
/// phone for its cloud copy and the sample shop.
@MainActor
final class LibraryFilterTests: XCTestCase {
    private func item(_ id: String, colours: [String] = [], ext: String? = "3mf", fileType: String? = nil,
                      folder: String? = nil) throws -> KhaytCompanion.LibraryItem {
        var o: [String: Any] = ["id": id, "name": id, "colors": colours.map { ["hex": $0] }]
        if let ext { o["ext"] = ext }
        if let fileType { o["fileType"] = fileType }
        if let folder { o["folder"] = folder }
        return try JSONDecoder().decode(KhaytCompanion.LibraryItem.self, from: JSONSerialization.data(withJSONObject: o))
    }

    // MARK: keys and query

    func testKeysAreTheContractsInItsOrder() {
        XCTAssertEqual(LibraryFilter.colourKeys, ["red", "orange", "yellow", "green", "blue", "purple", "pink", "brown",
                                                  "black", "grey", "white", "multi", "none"])
        XCTAssertEqual(LibraryFilter.typeKeys, ["3mf", "stl", "step", "obj", "gcode", "other", "nofile"])
    }

    func testTheQueryJoinsKeysInMenuOrderAndLeavesEmptyMenusOut() {
        let f = LibraryFilter(colours: ["black", "blue", "Teal"], types: ["stl", "3mf"])
        XCTAssertEqual(f.colourParam, "blue,black", "menu order, unknown keys dropped")
        XCTAssertEqual(f.typeParam, "3mf,stl")
        var q = URLComponents()
        q.queryItems = LibraryFilter.queryItems(query: "drone arm", folder: "Parts", offset: 50, limit: 50, filter: f)
        XCTAssertEqual(q.percentEncodedQuery, "q=drone%20arm&folder=Parts&offset=50&limit=50&colour=blue,black&type=3mf,stl")
        q.queryItems = LibraryFilter.queryItems(query: "", folder: "", offset: 0, limit: 50, filter: LibraryFilter())
        XCTAssertEqual(q.percentEncodedQuery, "q=&folder=&offset=0&limit=50", "no picks, no params: an older Mac reads the same question")
    }

    func testTheLaunchFlagReadsBothMenus() {
        let f = LibraryFilter(launchFlag: "colour=Blue, black;type=3mf,zip")
        XCTAssertEqual(f.colours, ["blue", "black"])
        XCTAssertEqual(f.types, ["3mf"])
        XCTAssertTrue(LibraryFilter(launchFlag: "nonsense").isEmpty)
    }

    // MARK: facets on the wire

    func testFacetsDecodeWithEveryKeyAndAbsentFacetsHideTheMenus() throws {
        let with = #"{"total":1,"offset":0,"folders":[],"items":[],"facets":{"colour":{"blue":3,"black":2,"teal":9},"type":{"3mf":4,"nofile":1}}}"#
        let page = try JSONDecoder().decode(LibraryPage.self, from: Data(with.utf8))
        let facets = try XCTUnwrap(page.facets)
        XCTAssertEqual(facets.colour["blue"], 3)
        XCTAssertEqual(facets.colour["red"], 0, "a key left out counts 0")
        XCTAssertNil(facets.colour["teal"], "an unknown key is dropped")
        XCTAssertEqual(Set(facets.colour.keys), Set(LibraryFilter.colourKeys))
        XCTAssertEqual(Set(facets.type.keys), Set(LibraryFilter.typeKeys))
        XCTAssertEqual(facets.type["nofile"], 1)

        let older = #"{"total":1,"offset":0,"folders":[],"items":[]}"#
        XCTAssertNil(try JSONDecoder().decode(LibraryPage.self, from: Data(older.utf8)).facets,
                     "an older Mac sends no facets, so the phone shows no menus")
        let broken = #"{"total":1,"items":[],"facets":"yes"}"#
        XCTAssertNil(try JSONDecoder().decode(LibraryPage.self, from: Data(broken.utf8)).facets,
                     "facets it cannot read are no facets, not a failed page")
    }

    func testAModelReadsItsColoursAndType() throws {
        let json = ##"{"id":"PF-1","name":"Arm","ext":"STL","colors":[{"hex":"#1A1A1A","grams":30},"#2F6FDE",{"grams":4},{"hex":""}]}"##
        let it = try JSONDecoder().decode(KhaytCompanion.LibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(it.colors, ["#1A1A1A", "#2F6FDE"])
        XCTAssertEqual(it.colourKeys, ["blue", "black", "multi"])
        XCTAssertEqual(it.fileType, "stl")
        XCTAssertEqual(try item("w", colours: [], ext: nil).fileType, "nofile")
        XCTAssertEqual(try item("w", colours: []).colourKeys, ["none"])
    }

    // MARK: answered on the phone

    func testOrWithinAMenuAndAcrossMenus() throws {
        let all = [try item("black-3mf", colours: ["#111111"]),
                   try item("blue-stl", colours: ["#2F6FDE"], ext: "stl"),
                   try item("red-3mf", colours: ["#D92D20"]),
                   try item("bare-3mf")]
        let either = LibraryFilter(colours: ["black", "blue"])
        XCTAssertEqual(all.filter(either.matches).map(\.id), ["black-3mf", "blue-stl"], "OR within a menu")
        let both = LibraryFilter(colours: ["black", "blue"], types: ["3mf"])
        XCTAssertEqual(all.filter(both.matches).map(\.id), ["black-3mf"], "AND across the menus")
        XCTAssertEqual(all.filter(LibraryFilter().matches).count, 4, "no picks narrow nothing")
        XCTAssertEqual(all.filter(LibraryFilter(colours: ["none"]).matches).map(\.id), ["bare-3mf"])
    }

    func testAMulticolourModelIsUnderEachFamilyAndMulti() throws {
        let all = [try item("drone", colours: ["#1C1C22", "#2F6FDE"]), try item("clip", colours: ["#3A6EB5"])]
        let facets = LibraryFilter().facets(all)
        XCTAssertEqual(facets.colour["black"], 1)
        XCTAssertEqual(facets.colour["blue"], 2)
        XCTAssertEqual(facets.colour["multi"], 1)
        XCTAssertEqual(facets.colour["none"], 0)
        XCTAssertEqual(all.filter(LibraryFilter(colours: ["multi"]).matches).map(\.id), ["drone"])
    }

    func testEachMenuIsCountedOverTheOtherMenusPickNotItsOwn() throws {
        let all = [try item("black-3mf", colours: ["#111111"]),
                   try item("blue-stl", colours: ["#2F6FDE"], ext: "stl"),
                   try item("blue-3mf", colours: ["#2F6FDE"]),
                   try item("web", ext: nil)]
        let f = LibraryFilter(colours: ["blue"], types: ["3mf"])
        let facets = f.facets(all)
        // Colour counted over type=3mf: black-3mf, blue-3mf.
        XCTAssertEqual(facets.colour["black"], 1)
        XCTAssertEqual(facets.colour["blue"], 1, "blue-stl is out: the OTHER menu's pick applies")
        XCTAssertEqual(facets.colour["none"], 0, "the web model has no file, so type=3mf leaves it out")
        // Type counted over colour=blue: blue-stl, blue-3mf.
        XCTAssertEqual(facets.type["3mf"], 1)
        XCTAssertEqual(facets.type["stl"], 1, "its own pick does not narrow its own counts")
        XCTAssertEqual(facets.type["nofile"], 0)
        XCTAssertEqual(Set(facets.colour.keys), Set(LibraryFilter.colourKeys), "every key, zeros too")
        XCTAssertEqual(Set(facets.type.keys), Set(LibraryFilter.typeKeys))
    }

    func testTheSamplePageFiltersCountsAndKeepsTheUnfilteredTotal() {
        let f = LibraryFilter(colours: ["blue", "black"], types: ["3mf"])
        let page = SampleLibrary.page(query: "", folder: "", filter: f)
        XCTAssertEqual(Set(page.items.map(\.id)), ["PF-sample-drone-arm", "PF-sample-cable-clips", "PF-sample-desk-organiser"])
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.unfilteredTotal, 14, "at the top the menus reach the whole library")
        XCTAssertEqual(page.matchedTotal, 5, "the three listed here, the dallah and the king relief further down")
        XCTAssertNotNil(page.facets, "a library the phone holds always has the menus")
        XCTAssertEqual(page.facets?.type["nofile"], 0, "counted over colour=blue,black: the web keychain has no colour")
        XCTAssertEqual(SampleLibrary.page(query: "", folder: "", filter: LibraryFilter()).facets?.type["nofile"], 1)
        XCTAssertFalse(page.folders.isEmpty, "folders stay while filtering")
        // A search keeps the picks.
        let searched = SampleLibrary.page(query: "desk", folder: "", filter: f)
        XCTAssertEqual(Set(searched.items.map(\.id)), ["PF-sample-cable-clips", "PF-sample-desk-organiser"],
                       "the red phone stand is tagged desk too, and the colour pick leaves it out")
    }

    func testUnfilteredTotalIsReadFromTheMac() throws {
        let json = #"{"total":26,"offset":0,"folders":[],"items":[],"unfilteredTotal":312,"facets":{"colour":{},"type":{}}}"#
        let page = try JSONDecoder().decode(LibraryPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.total, 26)
        XCTAssertEqual(page.unfilteredTotal, 312, "N of M: M is the Mac's, never a cached guess")
        let older = #"{"total":5,"items":[]}"#
        XCTAssertNil(try JSONDecoder().decode(LibraryPage.self, from: Data(older.utf8)).unfilteredTotal)
    }

    func testFoldersFollowTheMenusAndAnEmptyOneIsLeftOut() {
        let green = LibraryFilter(colours: ["green"])
        let top = SampleLibrary.page(query: "", folder: "", filter: green)
        XCTAssertEqual(top.folders, [LibraryFolder(path: "Home", name: "Home", count: 1)],
                       "only Home holds a green model (the lantern, under Home/Lighting); the rest are left out")
        XCTAssertEqual(top.items.map(\.id), ["PF-sample-planter"])
        XCTAssertEqual(top.unfilteredTotal, 14)
        XCTAssertEqual(top.matchedTotal, 2, "the planter here and the lantern under Home/Lighting")
        let plain = SampleLibrary.page(query: "", folder: "", filter: LibraryFilter())
        XCTAssertEqual(plain.folders.map(\.name), ["Gifts", "Home", "Parts", "Saudi Kings"], "nothing picked: the normal shape")
        XCTAssertEqual(plain.unfilteredTotal, 14, "nothing picked at the top: the whole library")
        XCTAssertEqual(plain.matchedTotal, 14, "nothing picked: N equals M")
        XCTAssertEqual(plain.total, 7, "total still pages only the models filed at the top")
        let both = SampleLibrary.page(query: "", folder: "", filter: LibraryFilter(colours: ["black"], types: ["stl"]))
        XCTAssertEqual(both.folders, [LibraryFolder(path: "Parts", name: "Parts", count: 1)], "a folder counts what passes BOTH menus")
    }

    func testTheMenusReachTheWholeSubtreeWithoutASearch() throws {
        let all = [try item("red-a", colours: ["#D92D20"], folder: "Home"),
                   try item("red-b", colours: ["#C0392B"], folder: "Home/Kitchen"),
                   try item("blue-top", colours: ["#2F6FDE"]),
                   try item("bare-top")]
        let red = SampleLibrary.page(all, query: "", folder: "", filter: LibraryFilter(colours: ["red"]))
        XCTAssertEqual(red.total, 0, "no red model is filed at the top itself")
        XCTAssertEqual(red.items, [])
        XCTAssertEqual(red.matchedTotal, 2)
        XCTAssertEqual(red.unfilteredTotal, 4)
        XCTAssertEqual(red.facets?.colour["red"], 2, "Red counts every red model under the top")
        XCTAssertEqual(red.folders, [LibraryFolder(path: "Home", name: "Home", count: 2)])

        let nothing = SampleLibrary.page(all, query: "", folder: "", filter: LibraryFilter())
        XCTAssertEqual(nothing.facets?.colour["red"], 2, "nothing chosen: the whole library is counted")
        XCTAssertEqual(nothing.facets?.colour["blue"], 1)
        XCTAssertEqual(nothing.facets?.colour["none"], 1)
        XCTAssertEqual(nothing.facets?.type["3mf"], 4)
        XCTAssertEqual(nothing.unfilteredTotal, 4)
        XCTAssertEqual(nothing.total, 2, "only the two filed at the top are listed")

        let home = SampleLibrary.page(all, query: "", folder: "Home", filter: LibraryFilter(colours: ["red"]))
        XCTAssertEqual(home.total, 1)
        XCTAssertEqual(home.matchedTotal, 2, "Home and Home/Kitchen")
        XCTAssertEqual(home.unfilteredTotal, 2)

        let search = SampleLibrary.page(all, query: "red", folder: "", filter: LibraryFilter(colours: ["red"]))
        XCTAssertEqual(search.total, 2, "a search reaches the whole library and lists what it finds")
        XCTAssertEqual(search.matchedTotal, search.total, "for a search the totals agree")
        XCTAssertEqual(search.unfilteredTotal, 2)
    }

    func testMatchedTotalIsReadAndFallsBackToTotal() throws {
        let with = #"{"total":0,"matchedTotal":2,"unfilteredTotal":9,"items":[],"facets":{"colour":{},"type":{}}}"#
        let page = try JSONDecoder().decode(LibraryPage.self, from: Data(with.utf8))
        XCTAssertEqual(page.shownTotal, 2, "N is matchedTotal, not the page's own total")
        let without = #"{"total":3,"unfilteredTotal":9,"items":[],"facets":{"colour":{},"type":{}}}"#
        XCTAssertEqual(try JSONDecoder().decode(LibraryPage.self, from: Data(without.utf8)).shownTotal, 3,
                       "facets without matchedTotal: fall back to total")
    }

    func testAFolderCanHoldItsMatchesOnlyDeeperDown() {
        let green = LibraryFilter(colours: ["green"])
        let home = SampleLibrary.page(query: "", folder: "Home", filter: green)
        XCTAssertTrue(home.items.isEmpty, "the spiral vase filed in Home has no colour, so Home shows none of its own")
        XCTAssertEqual(home.total, 0)
        XCTAssertEqual(home.unfilteredTotal, 2, "the vase here and the lantern under Lighting")
        XCTAssertEqual(home.matchedTotal, 1, "N counts the subtree, so it is 1 while total is 0")
        XCTAssertEqual(home.folders, [LibraryFolder(path: "Home/Lighting", name: "Lighting", count: 1)],
                       "but its sub-folder holds the match, so the page is folders, not an empty library")
        let lighting = SampleLibrary.page(query: "", folder: "Home/Lighting", filter: green)
        XCTAssertEqual(lighting.items.map(\.id), ["PF-sample-lantern"])
    }

    func testTheCloudCopyWorksOutTheTypeFromTheWholeRecord() throws {
        func row(_ o: [String: JSONValue]) -> KhaytCompanion.LibraryItem? { LibraryCopy.item(.object(o)) }
        let web = try XCTUnwrap(row(["id": .string("PF-web"), "name": .string("From the web")]))
        XCTAssertEqual(web.fileType, "nofile")
        let member = try XCTUnwrap(row(["id": .string("PF-zip"), "name": .string("In a zip"),
                                         "archiveMember": .string("set/part.stl")]))
        XCTAssertEqual(member.fileType, "stl", "a model inside an archive has a file without a sourceFile")
        let sliced = try XCTUnwrap(row(["id": .string("PF-g"), "name": .string("Plate"),
                                        "sourceFile": .object(["filename": .string("plate.gcode.3mf"), "ext": .string("3mf")]),
                                        "colors": .array([.object(["hex": .string("#D92D20"), "label": .string("Red")])])]))
        XCTAssertEqual(sliced.fileType, "gcode", "a .gcode.3mf is G-code, by the shared rule")
        XCTAssertEqual(sliced.colourKeys, ["red"])
        XCTAssertTrue(LibraryCopy.kept.isSuperset(of: ["archiveMember", "externalPath", "colors", "sourceFile"]))
    }
}
