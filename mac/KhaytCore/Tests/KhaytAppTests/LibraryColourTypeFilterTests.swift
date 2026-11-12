import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Library's Colour and File type menus.
///
/// The shop asked for two more filters: by colour group, and by file type.
/// What is held here is what was decided about them — a model is under EACH
/// of its colour families and under Multicolour; a model with no colour on
/// its record is under "No colour info" and nowhere else; several rows of
/// one menu are OR and the two menus AND; every row is always listed, greyed
/// when empty — and that they are an axis like the other five: in the one
/// query, the one matcher, the counts, the saved searches and the search box.
@MainActor
struct LibraryColourTypeFilterTests {

    static func sample() async -> Shop { await LibrarySmartFolderTests.sample() }

    private func shown(_ shop: Shop) -> Set<String> { Set(shop.shownFiles.map(\.id)) }

    // MARK: - On the sample book

    @Test("the sample book fills several rows of both menus")
    func sampleRows() async {
        let shop = await Self.sample()
        let live = shop.files.filter { !$0.isArchived }
        #expect(live.count == 18)
        // Worked out from the models, by the shared rule…
        var colours: [String: Int] = [:], types: [String: Int] = [:]
        for f in live {
            for token in f.colourTokens { colours[token, default: 0] += 1 }
            types[f.fileType.rawValue, default: 0] += 1
        }
        #expect(shop.libraryFacets.colours == colours)
        #expect(shop.libraryFacets.fileTypes == types)
        // …and as figures, so a threshold that moves shows here.
        #expect(colours == ["brown": 10, "white": 9, "green": 3, "black": 3, "grey": 1, "yellow": 1,
                            "multi": 11, "none": 3])
        #expect(types == ["3mf": 14, "stl": 4])
        // A multicolour model is counted under each family, so the rows add
        // up to more than the library.
        #expect(colours.values.reduce(0, +) > live.count)
    }

    @Test("a multicolour model is under each of its families, and under Multicolour")
    func multiUnderEachFamily() async {
        let shop = await Self.sample()
        let lantern = shop.files.first { $0.id == "PF-sample-lantern" }
        #expect(lantern?.colourTokens == ["yellow", "green", "brown", "multi"])
        for row in ["yellow", "green", "brown", "multi"] {
            shop.libraryColours = [row]
            #expect(shown(shop).contains("PF-sample-lantern"), "not under \(row)")
        }
        shop.libraryColours = ["black"]
        #expect(!shown(shop).contains("PF-sample-lantern"))
        // One colour is not multicolour, and two shades of one family are one.
        shop.libraryColours = ["multi"]
        #expect(!shown(shop).contains("PF-sample-vase"))
        #expect(!shown(shop).contains("PF-sample-falcon"), "two browns are not multicolour")
        #expect(shown(shop).count == 11)
    }

    @Test("no colour info is its own row, and only the models with none are under it")
    func noColourInfo() async {
        let shop = await Self.sample()
        shop.libraryColours = ["none"]
        let ids = shown(shop)
        #expect(ids == ["PF-sample-arc-pen", "PF-sample-arc-clip", "PF-sample-arc-knight"])
        for f in shop.shownFiles { #expect(f.palette.isEmpty && f.colourTokens == ["none"]) }
        // Nothing is invented for them: no family finds a model with no colours.
        for family in ColourFamily.allCases {
            shop.libraryColours = [family.rawValue]
            #expect(shown(shop).isDisjoint(with: ids), "\(family) found a model with no colour on its record")
        }
    }

    @Test("several rows of one menu are OR; the two menus AND")
    func orWithinAndAcross() async {
        let shop = await Self.sample()
        let live = shop.files.filter { !$0.isArchived }
        func under(_ tokens: Set<String>) -> Set<String> {
            Set(live.filter { !tokens.isDisjoint(with: $0.colourTokens) }.map(\.id))
        }
        shop.libraryColours = ["green"]
        let green = shown(shop)
        shop.libraryColours = ["black"]
        let black = shown(shop)
        #expect(green.count == 3 && black.count == 3 && green.isDisjoint(with: black))
        shop.libraryColours = ["green", "black"]
        #expect(shown(shop) == green.union(black))
        #expect(shown(shop) == under(["green", "black"]))

        shop.libraryFileTypes = ["stl"]
        #expect(shown(shop) == ["PF-sample-gripper"], "black or green, AND an STL")
        shop.libraryFileTypes = ["stl", "3mf"]
        #expect(shown(shop) == green.union(black))
        shop.libraryFileTypes = ["obj"]
        #expect(shown(shop).isEmpty)

        // And with an older axis: the same AND.
        shop.libraryFileTypes = []
        shop.libraryColours = ["brown"]
        shop.libraryNeverPrintedOnly = true
        #expect(shown(shop) == under(["brown"]).intersection(live.filter { $0.printCount == 0 }.map(\.id)))
    }

    @Test("each menu counts what the OTHER filters leave, never its own choice")
    func countsFollowTheOthers() async {
        let shop = await Self.sample()
        let whole = shop.libraryFacets
        // Choosing a colour does not shrink the colour rows — or a second one
        // could never be picked — and does shrink the file types.
        shop.libraryColours = ["black"]
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.colours == whole.colours)
        #expect(shop.libraryFacets.fileTypes == ["3mf": 2, "stl": 1])
        // And the other way round.
        shop.libraryColours = []
        shop.libraryFileTypes = ["stl"]
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.fileTypes == whole.fileTypes)
        #expect(shop.libraryFacets.colours == ["black": 1, "none": 3])
        // Both on: each still counted without itself.
        shop.libraryColours = ["none"]
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.colours == ["black": 1, "none": 3])
        #expect(shop.libraryFacets.fileTypes == ["stl": 3])
        // An older axis narrows both.
        shop.clearLibraryFilter()
        shop.search = "dental"
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.fileTypes == ["3mf": 2])
        #expect(shop.libraryFacets.colours == ["black": 2, "white": 2, "multi": 2])
    }

    // MARK: - File types

    static func model(_ id: String, _ fields: [String: JSONValue]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string("Model " + id)]
        for (k, v) in fields { o[k] = v }
        return .object(o)
    }

    static func source(_ name: String, ext: String, kind: String = "model") -> JSONValue {
        .object(["filename": .string(name), "originalName": .string(name), "size": .number(1000),
                 "ext": .string(ext), "kind": .string(kind)])
    }

    /// One invented model of each kind. Never the owner's.
    static let invented: [JSONValue] = [
        model("PF-t-3mf", ["sourceFile": source("frame.3mf", ext: "3mf"),
                           "colors": .array([.object(["hex": .string("#FF00FF")])])]),
        model("PF-t-stl", ["sourceFile": source("frame.stl", ext: "stl")]),
        model("PF-t-step", ["sourceFile": source("frame.step", ext: "step")]),
        model("PF-t-stp", ["sourceFile": source("frame.STP", ext: "stp")]),
        model("PF-t-obj", ["sourceFile": source("frame.obj", ext: "obj")]),
        model("PF-t-gcode", ["sourceFile": source("frame.gcode", ext: "gcode", kind: "gcode")]),
        model("PF-t-plate", ["sourceFile": source("plate_1.gcode.3mf", ext: "3mf"),
                             "colors": .array([.object(["hex": .string("#F28C28")]), .object(["hex": .string("#0A2A50")])])]),
        model("PF-t-scad", ["sourceFile": source("frame.scad", ext: "scad")]),
        model("PF-t-web", ["sourceUrl": .string("https://example.com/models/1"),
                           "savedFromWebAt": .string("2026-11-01T10:00:00.000Z"), "colors": .array([])]),
        model("PF-t-linked", ["externalPath": .string("/Volumes/Models/benchy.3mf")]),
    ]

    @Test("every file type row finds its models, a sliced plate is G-code, a web save has no file")
    func fileTypes() async {
        let shop = await Self.sample()
        shop.pretendLibrary(Self.invented)
        let expected: [(ModelFileType, Set<String>)] = [
            (.threeMF, ["PF-t-3mf", "PF-t-linked"]), (.stl, ["PF-t-stl"]), (.step, ["PF-t-step", "PF-t-stp"]),
            (.obj, ["PF-t-obj"]), (.gcode, ["PF-t-gcode", "PF-t-plate"]), (.other, ["PF-t-scad"]),
            (.noFile, ["PF-t-web"]),
        ]
        for (type, ids) in expected {
            shop.libraryFileTypes = [type.rawValue]
            #expect(shown(shop) == ids, "\(type.rawValue)")
            var q = LibraryQuery()
            q.fileTypes = [type.rawValue]
            #expect(shop.libraryCount(q) == ids.count, "a saved search counts what the grid shows")
        }
        shop.libraryFileTypes = ["step", "obj", "nofile"]
        #expect(shown(shop) == ["PF-t-step", "PF-t-stp", "PF-t-obj", "PF-t-web"])
        // Through the menus together: a magenta 3MF is purple, a two-colour plate is multicolour G-code.
        shop.libraryFileTypes = ["gcode"]
        shop.libraryColours = ["multi"]
        #expect(shown(shop) == ["PF-t-plate"])
        shop.libraryFileTypes = []
        shop.libraryColours = ["purple"]
        #expect(shown(shop) == ["PF-t-3mf"])
        // The web save is honest on both: no file, no colour info.
        shop.libraryColours = ["none"]
        shop.libraryFileTypes = ["nofile"]
        #expect(shown(shop) == ["PF-t-web"])
    }

    // MARK: - The one query

    @Test("the bar is the query: set, read back, cleared")
    func barIsTheQuery() async {
        let shop = await Self.sample()
        #expect(!shop.libraryFilterOn && !shop.libraryQueryActive)
        shop.libraryColours = ["white", "red"]
        shop.libraryFileTypes = ["stl"]
        #expect(shop.libraryFilterOn && shop.libraryQueryActive)
        let q = shop.libraryQuery
        #expect(q.colours == ["red", "white"], "kept in menu order, whatever order they were pressed in")
        #expect(q.fileTypes == ["stl"] && q.filtersOn && !q.isEmpty)

        shop.clearLibraryFilter()
        #expect(shop.libraryColours.isEmpty && shop.libraryFileTypes.isEmpty && !shop.libraryFilterOn)
        shop.openLibraryQuery(q)
        #expect(shop.libraryColours == ["white", "red"] && shop.libraryFileTypes == ["stl"])
        #expect(shop.libraryShows(q))
    }

    @Test("a saved search keeps both, in the book and back")
    func savedSearchRoundTrip() throws {
        var q = LibraryQuery()
        q.colours = ["multi", "none", "blue", "blue"]
        q.fileTypes = ["nofile", "3mf"]
        #expect(q.colours == ["blue", "multi", "none"] && q.fileTypes == ["3mf", "nofile"])
        #expect(q.json == .object(["colours": .array([.string("blue"), .string("multi"), .string("none")]),
                                   "fileTypes": .array([.string("3mf"), .string("nofile")])]))
        #expect(LibraryQuery(json: q.json) == q)
        #expect(try JSONDecoder().decode(LibraryQuery.self, from: JSONEncoder().encode(q)) == q)
        let saved = LibrarySavedSearch(id: "LSS-1", name: "Blue or bare", query: q, createdAt: "2026-11-11T00:00:00Z")
        #expect(LibrarySavedSearch(json: saved.json)?.query == q)
        // Two queries that ask the same thing are one query (a count's key).
        var other = LibraryQuery()
        other.colours = ["none", "blue", "multi"]
        other.fileTypes = ["3mf", "nofile"]
        #expect(other == q && other.hashValue == q.hashValue)
        #expect(LibraryQuery().json == .object([:]), "nothing chosen writes nothing")
    }

    @Test("ids this build does not know are dropped; a build that knows neither key ignores both")
    func otherBuilds() {
        // From a newer build: a family and a type added since.
        let newer: JSONValue = .object([
            "colours": .array([.string("Red"), .string("teal"), .number(4), .string("multi")]),
            "fileTypes": .array([.string("3mf"), .string("usdz")]),
            "tag": .string("relief"),
        ])
        let q = LibraryQuery(json: newer)
        #expect(q?.colours == ["red", "multi"] && q?.fileTypes == ["3mf"] && q?.tag == "relief")
        // The wrong shape is off, not fatal.
        let odd = LibraryQuery(json: .object(["colours": .string("red"), "fileTypes": .object([:])]))
        #expect(odd?.colours == [] && odd?.fileTypes == [] && odd?.isEmpty == true)
        // What an OLDER build does with a search saved here: it reads the keys
        // it knows and passes over these two (`init(json:)` reads by name), so
        // the search opens there as its other filters, without the colour
        // and file-type narrowing. The same reader, shown the same way:
        var mine = LibraryQuery()
        mine.colours = ["red"]; mine.fileTypes = ["stl"]; mine.tag = "relief"
        guard case .object(var stored) = mine.json else { Issue.record("not an object"); return }
        stored["axisFromTheFuture"] = .array([.string("x")])
        #expect(LibraryQuery(json: .object(stored)) == mine, "a key this build does not know is passed over")
    }

    // MARK: - The menus

    @Test("two more menus, after Tag; every row always listed, an empty one greyed")
    func menus() async {
        let shop = await Self.sample()
        #expect(LibraryFilterBar.axes.map(\.key) == ["mac.lib_show", "mac.lib_printer", "mac.lib_creator",
                                                    "mac.category", "mac.lib_tag", "inv.color", "brl.sort_type"])
        #expect(LibraryFilterBar.axes[5].prefix == "colour:" && LibraryFilterBar.axes[6].prefix == "type:")
        let chips = LibraryFilterBar(shop: shop).chips
        let colour = chips.filter(LibraryFilterBar.axes[5].holds)
        let type = chips.filter(LibraryFilterBar.axes[6].holds)
        #expect(colour.map(\.id) == ["red", "orange", "yellow", "green", "blue", "purple", "pink", "brown",
                                     "black", "grey", "white", "multi", "none"].map { "colour:" + $0 })
        #expect(type.map(\.id) == ["3mf", "stl", "step", "obj", "gcode", "other", "nofile"].map { "type:" + $0 })
        // Counts from the facets; nothing under Red on the sample, so it is greyed, not gone.
        let by = Dictionary(uniqueKeysWithValues: chips.map { ($0.id, $0) })
        #expect(by["colour:brown"]?.count == 10 && by["colour:brown"]?.enabled == true)
        #expect(by["colour:red"]?.count == 0 && by["colour:red"]?.enabled == false)
        #expect(by["colour:none"]?.count == 3 && by["colour:multi"]?.count == 11)
        #expect(by["type:stl"]?.count == 4 && by["type:obj"]?.enabled == false)
        // A swatch on each family, none on Multicolour or No colour info.
        #expect(colour.prefix(11).allSatisfy { $0.swatch != nil })
        #expect(by["colour:multi"]?.swatch == nil && by["colour:none"]?.swatch == nil)
        #expect(type.allSatisfy { $0.swatch == nil })
        #expect(LibraryFilterBar.offered(colour) == 8 && LibraryFilterBar.offered(type) == 2)
        // The older menus' rows are all offered, as before.
        for axis in LibraryFilterBar.axes.prefix(5) {
            let rows = chips.filter(axis.holds)
            #expect(LibraryFilterBar.offered(rows) == rows.count)
        }

        // Pressing a row turns it on, a second one joins it, pressing again takes it off.
        by["colour:brown"]?.press()
        #expect(shop.libraryColours == ["brown"])
        LibraryFilterBar(shop: shop).chips.first { $0.id == "colour:white" }?.press()
        #expect(shop.libraryColours == ["brown", "white"])
        let after = LibraryFilterBar(shop: shop).chips
        #expect(after.filter(\.on).map(\.id) == ["colour:brown", "colour:white"])
        after.first { $0.id == "colour:brown" }?.press()
        #expect(shop.libraryColours == ["white"])
        // A row that is on stays pressable at zero, so it can be taken off.
        shop.libraryColours = ["red"]
        await shop.settleLibraryFacets()
        let red = LibraryFilterBar(shop: shop).chips.first { $0.id == "colour:red" }
        #expect(red?.on == true && red?.count == 0 && red?.enabled == true)
    }

    @Test("an empty library greys both menus")
    func emptyLibrary() async {
        let shop = Shop()
        let chips = LibraryFilterBar(shop: shop).chips
        for axis in LibraryFilterBar.axes.suffix(2) {
            let rows = chips.filter(axis.holds)
            #expect(!rows.isEmpty)
            #expect(!LibraryFilterBar.menuEnabled(rows: LibraryFilterBar.offered(rows)))
        }
    }

    @Test("every row has a name in English and Arabic, as decided")
    func words() {
        let arabic: [String: String] = [
            "red": "أحمر", "orange": "برتقالي", "yellow": "أصفر", "green": "أخضر", "blue": "أزرق",
            "purple": "بنفسجي", "pink": "وردي", "brown": "بني", "black": "أسود", "grey": "رمادي", "white": "أبيض",
            "none": "بلا معلومات لون",
        ]
        for (token, said) in arabic {
            let key = LibraryFilterBar.colourKey(token)
            #expect(Words.own[key]?["ar"] == said, "\(key)")
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key)")
        }
        #expect(Words.own["mac.lf_no_colour"]?["en"] == "No colour info")
        #expect(Words.own["mac.lf_no_file"]?["en"] == "No file" && Words.own["mac.lf_no_file"]?["ar"] == "بلا ملف")
        #expect(Words.own["mac.lf_gcode"]?["en"] == "G-code")
        // The titles, Multicolour and Other are the shared catalogue's, and listed as borrowed.
        for key in ["inv.color", "brl.sort_type", "plan.material_label", "inv.type_other"] {
            #expect(Words.borrowed.contains(key), "\(key)")
        }
        #expect(LibraryFilterBar.colourKey("multi") == "plan.material_label")
    }

    // MARK: - Typed into the search box

    @Test("colour: and type: in the search box are those menus, typed")
    func searchTokens() async {
        let shop = await Self.sample()
        let parsed = LibrarySearch.parse("colour:green type:3mf لون:بني color:multi filetype:stl")
        #expect(parsed.tokens.map(\.field) == [.colour, .type, .colour, .colour, .type])
        #expect(parsed.text.isEmpty)
        #expect(LibrarySearch.Field.colour.wordKey == "inv.color" && LibrarySearch.Field.type.wordKey == "brl.sort_type")

        shop.libraryColours = ["green"]
        let menu = shown(shop)
        shop.libraryColours = []
        for typed in ["colour:green", "color:Green", "colour:gree", "اللون:green"] {
            shop.search = typed
            #expect(shown(shop) == menu, "\(typed)")
        }
        // From the start of a name: "gr" is green and grey, "re" is red alone (none here).
        shop.search = "colour:gr"
        #expect(shown(shop).count == 4)
        shop.search = "colour:re"
        #expect(shown(shop).isEmpty, "\"re\" inside green and grey is not a match")
        shop.search = "colour:none"
        #expect(shown(shop).count == 3)
        shop.search = "type:stl"
        #expect(shown(shop).count == 4)
        shop.search = "type:stl colour:black"
        #expect(shown(shop) == ["PF-sample-gripper"])
        // The chip takes its text back out of the box.
        let token = LibrarySearch.parse(shop.search).tokens[0]
        #expect(LibrarySearch.removing(token, from: shop.search) == "colour:black")
        // Narrowing reuses the last list only when the longer value starts with the shorter.
        #expect(LibrarySearch.parse("colour:gre").narrows(from: LibrarySearch.parse("colour:gr")))
        #expect(!LibrarySearch.parse("colour:red").narrows(from: LibrarySearch.parse("colour:ed")))
        #expect(LibrarySearch.parse("tag:red").narrows(from: LibrarySearch.parse("tag:ed")), "the other tokens are unchanged")
    }
}
