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
        #expect(folders.map { $0["name"] as? String } == ["Dental", "Saudi Kings"])
        #expect(folders.map { $0["count"] as? Int } == [2, 7])
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
                     archived: Bool = false) -> LibraryFile {
        var o: [String: Any] = ["id": id, "name": name, "folder": folder, "tags": tags]
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
        #expect(photo.headers["cache-control"] == "private, max-age=86400")
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

        let missing = try await bench.post("/api/library/PF-nobody/estimate", json: "", headers: Self.pin)
        #expect(missing.status == 404 && missing.text.contains("not-found"))
        #expect(try await bench.post("/api/library/PF-sample-lantern/estimate", json: "").status == 401)
        #expect(try await bench.get("/api/library/PF-sample-lantern/estimate", headers: Self.pin).status == 404,
                "a POST, as the intake estimate is")
    }
}
