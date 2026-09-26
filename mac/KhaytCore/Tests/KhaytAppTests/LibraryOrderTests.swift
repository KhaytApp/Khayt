import Foundation
import Testing
@testable import KhaytApp

/// The library opens newest-added first, and the order can be changed from
/// the Library screen itself.
@MainActor
struct LibraryOrderTests {

    static func file(_ id: String, created: String) throws -> LibraryFile {
        let json = #"{"id":"\#(id)","name":"\#(id)","createdAt":\#(created)}"#
        return try JSONDecoder().decode(LibraryFile.self, from: Data(json.utf8))
    }

    @Test("date added reads milliseconds and ISO strings alike, newest first")
    func newestFirst() throws {
        let old = try Self.file("old", created: #""2026-09-01T10:00:00.000Z""#)
        let mid = try Self.file("mid", created: "1789000000000")
        let new = try Self.file("new", created: "1790240571424.2148")
        let none = try JSONDecoder().decode(LibraryFile.self, from: Data(#"{"id":"none","name":"none"}"#.utf8))
        #expect(LibrarySort.added.sorted([old, none, mid, new]).map(\.id) == ["new", "mid", "old", "none"])
    }

    @Test("date added is the default, and the Library screen offers the choice")
    func defaultAndVisible() throws {
        #expect(LibrarySort.allCases.first == .added)
        let strip = try QuoteSheetStatusTests.source("ScreenActions.swift")
        #expect(strip.contains("selection: $shop.librarySort"))
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("var librarySort: LibrarySort = .added"))
    }

    @Test("an import reads the file off the main thread")
    func importOffMain() throws {
        let src = try QuoteSheetStatusTests.source("LibraryImport.swift")
        #expect(src.contains("await offMain { Mesh.provenance(of: destination) }"))
        #expect(src.contains("case \"3mf\": return try? Mesh.measure3MF(destination)"))
        #expect(!src.contains("geometry = try? Mesh.measure3MF(destination)"), "measuring is back on the main thread")
    }
}

@MainActor
struct LibraryFilterMenuTests {
    @Test("the library opens as one flat grid of models, and filters are menus, not a row of chips")
    func flatAndMenus() throws {
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("var libraryFlat = true"))
        #expect(shop.contains("if libraryFlat, group == nil"))
        let bar = try QuoteSheetStatusTests.source("LibraryFilterBar.swift")
        #expect(bar.contains("Menu {"))
        #expect(!bar.contains("FilterBar(chips: chips"), "the library is back to a strip of chips")
    }
}
