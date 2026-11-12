import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The phone searches the shop's library on this Mac and has a model priced
/// here, at the price this Mac's own "Quote this model…" gives.
@MainActor
struct LanLibraryTests {
    static let pin = ["x-khayt-pin": "24682468"]

    static func json(_ reply: LanServerTests.Bench.Reply) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
    }

    @Test("a page: the top level's folders with counts and its own models, favourites first")
    func topLevel() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        #expect(try await bench.get("/api/library").status == 401, "the owner's, not a visitor's")

        let top = try Self.json(try await bench.get("/api/library", headers: Self.pin))
        let folders = try #require(top["folders"] as? [[String: Any]])
        #expect(folders.map { $0["name"] as? String } == ["Dental", "Desk Organiser Pack", "Patreon Minis", "Saudi Kings"])
        #expect(folders.map { $0["count"] as? Int } == [2, 2, 1, 7])
        let items = try #require(top["items"] as? [[String: Any]])
        #expect(top["total"] as? Int == 6 && items.count == 6, "only the ungrouped models at the top")
        #expect(Set(items.prefix(2).compactMap { $0["id"] as? String }) == ["PF-sample-falcon", "PF-sample-lantern"])

        let lantern = try #require(items.first { $0["id"] as? String == "PF-sample-lantern" })
        #expect(lantern["printTimeMins"] as? Double == 318)
        #expect((lantern["plates"] as? [Any])?.count == 2)
        #expect(lantern["thumb"] as? Bool == true && lantern["estimable"] as? Bool == true)
        let falcon = try #require(items.first { $0["id"] as? String == "PF-sample-falcon" })
        #expect(falcon["printTimeMins"] is NSNull, "null, never a made-up 0")

        let kings = try Self.json(try await bench.get("/api/library?folder=Saudi%20Kings&limit=3&offset=2",
                                                      headers: Self.pin))
        #expect(kings["total"] as? Int == 7)
        #expect((kings["items"] as? [Any])?.count == 3)
        #expect((kings["folders"] as? [Any])?.isEmpty == true)
    }

    /// The phone's two filter menus (Turki, Nov 2026: "filter by color group,
    /// filter by file type"). The rule is `lib/lan-library.js narrow`, whose
    /// own tests pin the cases; this holds the Mac's native answer to the same
    /// shape and the same arithmetic on the sample book.
    @Test("colour and type narrow the phone's list, and each menu is counted without its own choice")
    func filters() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        func page(_ query: String) async throws
            -> (total: Int, ids: [String], colour: [String: Int], type: [String: Int], unfiltered: Int) {
            let body = try Self.json(try await bench.get("/api/library" + query, headers: Self.pin))
            let facets = try #require(body["facets"] as? [String: Any], "a Mac that filters says so with facets")
            let items = try #require(body["items"] as? [[String: Any]])
            return (try #require(body["total"] as? Int), items.compactMap { $0["id"] as? String },
                    try #require(facets["colour"] as? [String: Int]), try #require(facets["type"] as? [String: Int]),
                    try #require(body["unfilteredTotal"] as? Int))
        }
        // A search, so the whole sample library is in play rather than one folder.
        let all = try await page("?q=e&limit=200")
        #expect(Set(all.colour.keys) == Set(ColourFamily.tokens), "every colour row, zeros included")
        #expect(Set(all.type.keys) == Set(ModelFileType.allCases.map(\.rawValue)))
        #expect(all.type.values.reduce(0, +) == all.total, "every model has exactly one type")
        #expect(all.total > 3)
        #expect(all.unfiltered == all.total, "nothing chosen: N of N")

        // Each colour row: asking for it gives exactly the count it showed,
        // leaves the colour counts alone, and narrows the type counts.
        for (key, count) in all.colour where count > 0 {
            let one = try await page("?q=e&limit=200&colour=" + key)
            #expect(one.total == count, "\(key)")
            #expect(one.unfiltered == all.total, "\(key): N of M, M is the search before the menus")
            #expect(one.colour == all.colour, "\(key): a menu is not narrowed by its own choice")
            #expect(one.type.values.reduce(0, +) == count, "\(key): the other menu is")
            #expect(Set(one.ids).isSubset(of: Set(all.ids)))
        }
        // And each type row the same way round.
        for (key, count) in all.type where count > 0 {
            let one = try await page("?q=e&limit=200&type=" + key)
            #expect(one.total == count, "\(key)")
            #expect(one.type == all.type, "\(key)")
        }
        // OR within a menu: two rows give at least the larger and at most the sum.
        let rows = all.colour.filter { $0.value > 0 && $0.key != ColourFamily.multi }.keys.sorted()
        if rows.count >= 2 {
            let two = try await page("?q=e&limit=200&colour=\(rows[0]),\(rows[1])")
            #expect(two.total >= max(all.colour[rows[0]]!, all.colour[rows[1]]!))
            #expect(two.total <= all.colour[rows[0]]! + all.colour[rows[1]]!)
        }
        // A key nobody knows is ignored; so are case and spaces.
        #expect(try await page("?q=e&limit=200&colour=teal").total == all.total)
        if let first = rows.first {
            #expect(try await page("?q=e&limit=200&colour=%20" + first.uppercased() + "%20,teal").total == all.colour[first])
        }
    }

    @Test("the menus' arithmetic, on models made for it")
    func narrowRule() {
        func model(_ id: String, _ file: String?, _ hexes: [String]) -> LibraryFile {
            Self.file(id, name: id, folder: "", filename: file, colours: hexes)
        }
        let files = [
            model("a", "a.3mf", ["#ff0000", "#ffffff"]), model("b", "b.stl", []),
            model("c", "c.3mf", ["#0000ff"]), model("d", "d.gcode", ["#0000cc"]), model("e", nil, []),
        ]
        func run(_ colour: String?, _ type: String?) -> (ids: [String], colour: [String: Int], type: [String: Int]) {
            let r = Shop.libraryNarrow(files, .init(colour: colour, type: type)) { $0.colourTokens }
            return (r.files.map(\.id), r.colour, r.type)
        }
        #expect(run(nil, nil).ids == ["a", "b", "c", "d", "e"])
        #expect(run("blue", nil).ids == ["c", "d"])
        #expect(run("blue,red", nil).ids == ["a", "c", "d"])
        #expect(run("blue", "3mf").ids == ["c"])
        #expect(run("multi", nil).ids == ["a"] && run("white", nil).ids == ["a"])
        #expect(run("none", nil).ids == ["b", "e"] && run(nil, "nofile").ids == ["e"])
        // The same figures `test/lan-library.test.js` holds the JavaScript to.
        let none = run(nil, nil)
        #expect(none.colour["red"] == 1 && none.colour["blue"] == 2 && none.colour["white"] == 1
                && none.colour["multi"] == 1 && none.colour["none"] == 2 && none.colour["green"] == 0)
        #expect(none.type == ["3mf": 2, "stl": 1, "step": 0, "obj": 0, "gcode": 1, "other": 0, "nofile": 1])
        let blue = run("blue", nil)
        #expect(blue.colour == none.colour)
        #expect(blue.type == ["3mf": 1, "stl": 0, "step": 0, "obj": 0, "gcode": 1, "other": 0, "nofile": 0])
        #expect(run(nil, "3mf").type == none.type && run(nil, "3mf").colour["none"] == 0)

        // The sub-folders follow the menus, at the count of what passes.
        let deep = files + [Self.file("f", name: "f", folder: "Deep", filename: "f.stl", colours: ["#ff0000"])]
        func folders(_ colour: String?, _ type: String?) -> [String] {
            let filter = Shop.PhoneLibraryFilter(colour: colour, type: type)
            return Shop.libraryPage(deep, q: "", folder: "", offset: 0, limit: 50,
                                    passes: { filter.passes($0) { $0.colourTokens } })
                .folders.map { "\($0.path) \($0.count)" }
        }
        #expect(folders(nil, nil) == ["Deep 1"] && folders("red", nil) == ["Deep 1"])
        #expect(folders("blue", nil).isEmpty, "nothing blue under Deep: not offered")
        #expect(folders("red", "3mf").isEmpty, "the red one under Deep is an STL")
    }

    @Test("a search covers the whole library, every word, any case or accent, and the folder name")
    func search() throws {
        let shop = Shop()
        let files = [
            Self.file("a", name: "Ramadan lantern", folder: "Home/Decor", tags: ["gift"]),
            Self.file("b", name: "مكتبة صغيرة", folder: "Home"),
            Self.file("c", name: "Bracket", folder: "Parts", category: "Functional"),
            Self.file("d", name: "Old lantern", folder: "Home", archived: true),
        ]
        _ = shop
        #expect(Shop.libraryPage(files, q: "LANTERN", folder: "", offset: 0, limit: 50).files.map(\.id) == ["a"],
                "archived models are not offered")
        #expect(Shop.libraryPage(files, q: "مكتبه", folder: "", offset: 0, limit: 50).files.map(\.id) == ["b"],
                "tā' marbūṭa typed either way")
        #expect(Shop.libraryPage(files, q: "home gift", folder: "", offset: 0, limit: 50).files.map(\.id) == ["a"])
        #expect(Shop.libraryPage(files, q: "functional", folder: "", offset: 0, limit: 50).files.map(\.id) == ["c"])
        let home = Shop.libraryPage(files, q: "", folder: "Home", offset: 0, limit: 50)
        #expect(home.files.map(\.id) == ["b"])
        #expect(home.folders.map(\.path) == ["Home/Decor"] && home.folders.map(\.count) == [1])
        let top = Shop.libraryPage(files, q: "", folder: "", offset: 0, limit: 50)
        #expect(top.folders.map(\.name) == ["Home", "Parts"] && top.folders.map(\.count) == [2, 1],
                "a folder counts every model at or under it")
    }

    static func file(_ id: String, name: String, folder: String, tags: [String] = [], category: String? = nil,
                     archived: Bool = false, filename: String? = nil, colours: [String] = []) -> LibraryFile {
        var o: [String: Any] = ["id": id, "name": name, "folder": folder, "tags": tags]
        if let filename { o["sourceFile"] = ["filename": filename] }
        if !colours.isEmpty { o["colors"] = colours.map { ["hex": $0] } }
        if let category { o["category"] = category }
        if archived { o["archivedAt"] = "2026-10-01T00:00:00Z" }
        let data = try! JSONSerialization.data(withJSONObject: o)
        return try! JSONDecoder().decode(LibraryFile.self, from: data)
    }

    @Test("a thumbnail where there is one, a 404 where there is none")
    func thumbs() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        // Asked first: the picture is cacheable, and a cached 200 would answer
        // this one without the server ever seeing it.
        #expect(try await bench.get("/api/library/PF-sample-king-7/thumb").status == 401)
        let photo = try await bench.get("/api/library/PF-sample-king-7/thumb", headers: Self.pin)
        #expect(photo.status == 200)
        #expect(photo.headers["content-type"]?.hasPrefix("image/") == true)
        #expect(photo.headers["cache-control"] == "private, max-age=300")
        #expect(!photo.body.isEmpty)
        #expect(try await bench.get("/api/library/PF-sample-king-1/thumb", headers: Self.pin).status == 404)
    }

    @Test("a price is the Mac's own: the slicer's figures when recorded, the measured mesh when not")
    func estimate() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let sliced = try Self.json(try await bench.post("/api/library/PF-sample-lantern/estimate", json: "",
                                                        headers: Self.pin))
        #expect(sliced["ok"] as? Bool == true)
        #expect(sliced["exact"] as? Bool == true)
        #expect(sliced["reliable"] as? Bool == true)
        let price = try #require(sliced["price"] as? Double)
        let lantern = try #require(bench.shop.files.first { $0.id == "PF-sample-lantern" })
        let mac = try #require(await bench.shop.calculator(for: lantern, plate: nil))
        #expect(price == mac.quoted?.total, "the number the Mac's own Quote this model gives")
        #expect(sliced["currency"] as? String == bench.shop.currency)

        let two = try Self.json(try await bench.post("/api/library/PF-sample-lantern/estimate?qty=2", json: "",
                                                     headers: Self.pin))
        #expect((two["price"] as? Double ?? 0) > price && two["qty"] as? Int == 2)

        let plate = try Self.json(try await bench.post("/api/library/PF-sample-lantern/estimate?plate=1", json: "",
                                                       headers: Self.pin))
        #expect(plate["ok"] as? Bool == true && (plate["price"] as? Double ?? 0) < price)
        #expect(try await bench.post("/api/library/PF-sample-lantern/estimate?plate=9", json: "",
                                     headers: Self.pin).status == 404)

        let measured = try Self.json(try await bench.post("/api/library/PF-sample-king-1/estimate", json: "",
                                                          headers: Self.pin))
        #expect(measured["ok"] as? Bool == true && measured["exact"] as? Bool == false,
                "nothing sliced it: the mesh is measured, and it says so")
        #expect(measured["reliable"] is Bool)

        let missing = try await bench.post("/api/library/PF-nobody/estimate", json: "", headers: Self.pin)
        #expect(missing.status == 404 && missing.text.contains("not-found"))
        #expect(try await bench.post("/api/library/PF-sample-lantern/estimate", json: "").status == 401)
        #expect(try await bench.get("/api/library/PF-sample-lantern/estimate", headers: Self.pin).status == 404,
                "a POST, as the intake estimate is")
    }
}
