import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// How the library is ordered.
///
/// The one that matters is `.khayt`: the shop's other app sorts favourites
/// first and then most recently updated, and a library that comes out in a
/// different order on the Mac is a second library as far as anyone using both
/// is concerned.
@MainActor
struct LibrarySortTests {

    static func file(_ id: String, name: String, favourite: Bool = false,
                     updated: String? = nil, size: Double? = nil,
                     printed: Int? = nil, lastPrinted: String? = nil) throws -> LibraryFile {
        let json = """
        {"id":"\(id)","name":"\(name)","favorite":\(favourite),
         \(updated.map { "\"updatedAt\":\"\($0)\"," } ?? "")
         \(lastPrinted.map { "\"lastPrinted\":\"\($0)\"," } ?? "")
         \(printed.map { "\"timesPrinted\":\($0)," } ?? "")
         "sourceFile":{"size":\(size ?? 0)}}
        """
        return try JSONDecoder().decode(LibraryFile.self, from: Data(json.utf8))
    }

    @Test("the default is Khayt's: favourites first, then most recently updated")
    func matchesKhayt() throws {
        let old = try Self.file("a", name: "Zebra", updated: "2026-01-01T00:00:00.000Z")
        let recent = try Self.file("b", name: "Apple", updated: "2026-08-01T00:00:00.000Z")
        let favourite = try Self.file("c", name: "Middle", favourite: true,
                                      updated: "2026-02-01T00:00:00.000Z")

        let sorted = [old, recent, favourite].sorted(by: LibrarySort.khayt.order)
        #expect(sorted.map(\.id) == ["c", "b", "a"],
                "a favourite comes first even when something else is newer")
    }

    @Test("by name is the shop's collation, not ASCII")
    func nameUsesCollation() throws {
        let ten = try Self.file("a", name: "Model 10")
        let two = try Self.file("b", name: "Model 2")
        let sorted = [ten, two].sorted(by: LibrarySort.name.order)
        #expect(sorted.map(\.id) == ["b", "a"],
                "Model 2 before Model 10 — a plain string compare puts 10 first")
    }

    @Test("by size is biggest first, because that is the question being asked")
    func sizeIsDescending() throws {
        let small = try Self.file("a", name: "Small", size: 1_000)
        let big = try Self.file("b", name: "Big", size: 90_000_000)
        #expect([small, big].sorted(by: LibrarySort.size.order).map(\.id) == ["b", "a"])
    }

    @Test("a model that has never run sorts last, not first")
    func neverPrintedSortsLast() throws {
        // The absent date must read as "long ago", not as "now". A model with
        // no lastPrinted jumping to the top of "Last run" would be the first
        // thing a shop sees and the least useful.
        let never = try Self.file("a", name: "Never")
        let once = try Self.file("b", name: "Once", lastPrinted: "2026-05-05")
        #expect([never, once].sorted(by: LibrarySort.lastPrinted.order).map(\.id) == ["b", "a"])

        let unprinted = try Self.file("c", name: "None")
        let printed = try Self.file("d", name: "Some", printed: 4)
        #expect([unprinted, printed].sorted(by: LibrarySort.timesPrinted.order).map(\.id) == ["d", "c"])
    }

    @Test("every order has a name in both languages")
    func allAreNamed() async throws {
        let engine = try KhaytEngine()
        for language in Words.supported {
            let words = Words()
            await words.load(language, engine: engine)
            for sort in LibrarySort.allCases {
                let said = words.callIt(sort.key)
                #expect(said != sort.key, "\(language) has no word for \(sort.rawValue)")
            }
        }
    }

    @Test("the shelf actually uses it")
    func theShelfSorts() async {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)

        shop.librarySort = .name
        let byName = shop.shownFiles.map(\.title)
        #expect(byName == byName.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        shop.librarySort = .size
        let bySize = shop.shownFiles.compactMap(\.size)
        #expect(bySize == bySize.sorted(by: >), "the shelf ignored the sort")
    }
}
