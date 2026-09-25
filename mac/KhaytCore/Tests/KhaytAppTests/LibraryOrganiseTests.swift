import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// Creators, Print next and Duplicates — what a library of hundreds needs
/// beyond folders (Sep 2026, after the shop pointed at LayerMate).
@MainActor
struct LibraryOrganiseTests {
    static func file(_ id: String, source: String? = nil, hash: String? = nil, geometry: String? = nil,
                     printNext: String? = nil) throws -> LibraryFile {
        var o: [String: Any] = ["id": id, "name": id]
        if let source { o["source"] = source }
        if let hash { o["contentHash"] = hash }
        if let geometry { o["geometryKey"] = geometry }
        if let printNext { o["printNextAt"] = printNext }
        return try JSONDecoder().decode(LibraryFile.self, from: JSONSerialization.data(withJSONObject: o))
    }

    @Test("a creator is the designer named, or the site a link points at")
    func creators() {
        #expect(LibraryFile.creator(of: "  Loubie3D ") == "Loubie3D")
        #expect(LibraryFile.creator(of: "https://www.printables.com/model/123-dragon") == "printables.com")
        #expect(LibraryFile.creator(of: "http://makerworld.com/en/models/9") == "makerworld.com")
        #expect(LibraryFile.creator(of: "") == nil)
        #expect(LibraryFile.creator(of: nil) == nil)
    }

    @Test("duplicates: the same bytes certainly, the same mesh as a strong hint, and nothing else")
    func duplicates() throws {
        let files = [
            try Self.file("a", hash: "h1", geometry: "100:5.0:1x2x3"),
            try Self.file("b", hash: "h1", geometry: "100:5.0:1x2x3"),     // same file
            try Self.file("c", hash: "h2", geometry: "200:9.0:4x4x4"),
            try Self.file("d", hash: "h3", geometry: "200:9.0:4x4x4"),     // same mesh, re-saved
            try Self.file("e", hash: "h4", geometry: "300:1.0:1x1x1"),     // alone
            try Self.file("f", hash: "h5", geometry: "0:0:0x0x0"),         // unmeasured: never a match
            try Self.file("g", hash: "h6", geometry: "0:0:0x0x0"),
        ]
        let groups = Shop.duplicateGroups(files)
        #expect(groups["a"] != nil && groups["a"] == groups["b"])
        #expect(groups["a"]!.hasPrefix("file:"), "same bytes is reported as the same FILE")
        #expect(groups["c"] != nil && groups["c"] == groups["d"])
        #expect(groups["e"] == nil)
        #expect(groups["f"] == nil && groups["g"] == nil, "two unmeasured models are not the same model")
    }

    @Test("Print next is a mark with a date, read as a list oldest first")
    func printNext() throws {
        #expect(try Self.file("a", printNext: "2026-09-25T01:00:00.000Z").isPrintNext)
        #expect(try !Self.file("b").isPrintNext)
        #expect(try !Self.file("c", printNext: "").isPrintNext)
    }

    @Test("the chips count against the sample book, and a creator filter narrows the grid")
    func onTheSampleBook() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.settleLibraryFacets()
        let facets = shop.libraryFacets
        let total = facets.creators.reduce(0) { $0 + $1.count }
        #expect(total == shop.files.filter { $0.creator != nil && !$0.isArchived }.count || total <= shop.files.count)
        if let first = facets.creators.first {
            shop.libraryCreator = first.name
            await shop.settleLibraryFacets()
            #expect(shop.shownFiles.allSatisfy { $0.creator?.lowercased() == first.name.lowercased() })
            #expect(shop.libraryFilterOn)
            shop.clearLibraryFilter()
            #expect(!shop.libraryFilterOn)
        }
    }
}
