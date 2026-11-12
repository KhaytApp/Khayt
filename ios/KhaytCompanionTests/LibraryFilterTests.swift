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
        XCTAssertEqual(page.unfilteredTotal, 7, "the top's own models before the menus")
        XCTAssertNotNil(page.facets, "a library the phone holds always has the menus")
        XCTAssertEqual(page.facets?.type["nofile"], 0, "counted over colour=blue,black: the web keychain has no colour")
        XCTAssertEqual(SampleLibrary.page(query: "", folder: "", filter: LibraryFilter()).facets?.type["nofile"], 1)
        XCTAssertFalse(page.folders.isEmpty, "folders stay while filtering")
        // A search keeps the picks.
        let searched = SampleLibrary.page(query: "desk", folder: "", filter: f)
        XCTAssertEqual(Set(searched.items.map(\.id)), ["PF-sample-cable-clips", "PF-sample-desk-organiser"],
                       "the red phone stand is tagged desk too, and the colour pick leaves it out")
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
