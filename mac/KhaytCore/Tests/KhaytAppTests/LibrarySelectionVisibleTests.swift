import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The library's selection holds only models drawn as tiles on screen.
///
/// ── WHY ───────────────────────────────────────────────────────────────────
///
/// 27 Sep 2026, alpha.52: a shop lost the 34 models of its "Luffy Card" group
/// in one multi-delete it never chose. In the grouped view `shownFiles` holds
/// every model INSIDE the folder tiles too, and ⌘A, ⇧-click and ⇧-arrow all
/// selected from it; the selection then survived view and folder changes, and
/// a right-click on a visible model offered "Delete 34 Models…" with only a
/// count to go on.
@MainActor
struct LibrarySelectionVisibleTests {

    static func row(_ id: String, _ name: String, group: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name),
            "sourceFile": .object(["filename": .string(name + ".stl"), "ext": .string("stl")]),
        ]
        if let group { o["folder"] = .string(group) }
        return .object(o)
    }

    /// 30 models in "Luffy Card", 3 loose, in the grouped view at the top.
    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        var rows = (1...30).map { row(String(format: "PF-luffy-%02d", $0), String(format: "luffy %02d", $0),
                                      group: "Luffy Card") }
        // Named so that, by name, the group's models sort BETWEEN the loose
        // ones: a range or an arrow walk over `shownFiles` crosses them.
        rows += [row("PF-loose-a", "aaa loose"), row("PF-loose-b", "mmm loose"), row("PF-loose-c", "zzz loose")]
        shop.pretendLibrary(rows)
        shop.libraryShowArchived = false
        shop.clearLibraryFilter()
        shop.search = ""
        shop.librarySort = .name
        shop.shelf = .library(nil)
        shop.libraryFlat = false
        return shop
    }

    static let loose: Set<String> = ["PF-loose-a", "PF-loose-b", "PF-loose-c"]

    @Test("visible models are exactly the .file entries the grid draws")
    func derivedFromEntries() async {
        let shop = await Self.shop()
        for flat in [false, true] {
            shop.libraryFlat = flat
            let drawn = shop.shownEntries.compactMap { e -> String? in
                if case .file(let f) = e { return f.id } else { return nil }
            }
            #expect(shop.visibleFiles.map(\.id) == drawn)
        }
    }

    @Test("grouped view: what is visible is the loose models, not the folder's contents")
    func visibleIsLoose() async {
        let shop = await Self.shop()
        #expect(shop.shownFiles.count == 33, "the fixture changed")
        #expect(Set(shop.visibleFiles.map(\.id)) == Self.loose)
        shop.libraryFlat = true
        #expect(shop.visibleFiles.count == 33, "the flat view draws every model")
    }

    @Test("⌘A in the grouped view selects only the 3 loose models")
    func selectAllIsLooseOnly() async {
        let shop = await Self.shop()
        shop.selectAllShown()
        #expect(shop.fileSelection == Self.loose)
        #expect(Set(shop.selectedFiles.map(\.id)) == Self.loose)
    }

    @Test("a ⇧-click range between two loose models never takes a grouped one")
    func shiftClickRange() async throws {
        let shop = await Self.shop()
        let a = try #require(shop.files.first { $0.id == "PF-loose-a" })
        let c = try #require(shop.files.first { $0.id == "PF-loose-c" })
        shop.select(a, modifiers: .replace)
        shop.select(c, modifiers: .extend)
        #expect(shop.fileSelection == Self.loose)
        #expect(!shop.fileSelection.contains { $0.hasPrefix("PF-luffy") })
    }

    @Test("⇧-arrow never walks into a folder tile's contents")
    func shiftArrow() async throws {
        let shop = await Self.shop()
        let a = try #require(shop.files.first { $0.id == "PF-loose-a" })
        let c = try #require(shop.files.first { $0.id == "PF-loose-c" })
        // Both directions: whichever side of the loose models the grouped ones
        // sort to, one of these walks towards them.
        shop.select(a, modifiers: .replace)
        while shop.moveSelection(by: 1, extending: true) {}
        #expect(shop.fileSelection == Self.loose)
        shop.select(c, modifiers: .replace)
        while shop.moveSelection(by: -1, extending: true) {}
        #expect(shop.fileSelection == Self.loose)
        shop.select(a, modifiers: .replace)
        while shop.moveSelection(by: -1, extending: true) {}
        #expect(!shop.fileSelection.contains { $0.hasPrefix("PF-luffy") })
        shop.select(c, modifiers: .replace)
        while shop.moveSelection(by: 1, extending: true) {}
        #expect(!shop.fileSelection.contains { $0.hasPrefix("PF-luffy") })
    }

    @Test("switching All models → Groups prunes the selection to what is on screen")
    func flatToGroupedPrunes() async {
        let shop = await Self.shop()
        shop.libraryFlat = true
        shop.selectAllShown()
        #expect(shop.fileSelection.count == 33)
        shop.libraryFlat = false
        #expect(shop.fileSelection == Self.loose)
    }

    @Test("a search or a filter prunes what it hides")
    func searchPrunes() async {
        let shop = await Self.shop()
        shop.libraryFlat = true
        shop.selectAllShown()
        shop.search = "luffy"
        #expect(shop.fileSelection.count == 30)
        #expect(!shop.fileSelection.contains("PF-loose-a"))
        shop.search = ""
        shop.libraryUnfiledOnly = true
        #expect(shop.fileSelection.isEmpty, "every luffy model is filed; the filter hides them all")
    }

    @Test("entering a folder, and leaving it, clears the selection")
    func folderClears() async {
        let shop = await Self.shop()
        shop.selectAllShown()
        shop.shelf = .library("Luffy Card")
        #expect(shop.fileSelection.isEmpty)
        shop.selectAllShown()
        #expect(shop.fileSelection.count == 30, "inside the folder its models are the tiles")
        shop.shelf = .library(nil)
        #expect(shop.fileSelection.isEmpty)
    }

    @Test("a stale selection holding hidden models acts only on the visible ones")
    func staleSelectionIsMasked() async {
        let shop = await Self.shop()
        // A state the UI can no longer reach — set behind its back, as a
        // future regression would.
        shop.fileSelection = Set(shop.files.map(\.id))
        #expect(Set(shop.selectedFiles.map(\.id)) == Self.loose)
        #expect(shop.selectedIds == Self.loose)
    }

    @Test("the delete confirmation lists exactly the visible selection")
    func confirmationListsVisible() async throws {
        let shop = await Self.shop()
        shop.fileSelection = Set(shop.files.map(\.id))   // stale, as above
        let chosen = shop.selectedFiles
        #expect(shop.askToDeleteFromLibrary(chosen).isEmpty)
        #expect(Set(shop.pendingLibraryDeletes.map(\.id)) == Self.loose)
        let message = shop.libraryDeleteMessage(shop.pendingLibraryDeletes)
        for f in shop.pendingLibraryDeletes { #expect(message.contains(f.title)) }
        #expect(!message.contains("luffy"), "a model not chosen is named")
    }

    @Test("the confirmation names the first eight, counts the rest, and says how many are in groups")
    func confirmationShape() async {
        let shop = await Self.shop()
        shop.libraryFlat = true
        let chosen = Array(shop.visibleFiles.prefix(12))
        let lines = Shop.libraryDeleteLines(chosen, words: shop.words)
        let named = lines.filter { $0.hasPrefix("\u{2022} ") }
        #expect(named.count == 8)
        #expect(lines.contains(shop.words.callIt("mac.delete_and_more", ["n": .number(4)])))
        let grouped = chosen.filter { $0.groupName != nil }.count
        #expect(grouped > 0)
        #expect(lines.contains { $0.contains("Luffy Card") && $0.contains("\(grouped)") })
    }

    @Test("the UI's delete refuses models that are not on screen, and nothing is asked")
    func refusesHidden() async {
        let shop = await Self.shop()
        let everything = shop.files
        let hidden = shop.askToDeleteFromLibrary(everything)
        #expect(hidden.count == 30)
        #expect(shop.pendingLibraryDeletes.isEmpty)
        #expect(shop.importProblem == shop.words.callIt("mac.delete_not_on_screen", ["n": .number(30)]))

        // And at Delete itself, should a question ever be open over them.
        shop.importProblem = nil
        shop.pendingLibraryDeletes = everything
        await shop.confirmLibraryDeletes()
        #expect(shop.pendingLibraryDeletes.isEmpty)
        #expect(shop.importProblem == shop.words.callIt("mac.delete_not_on_screen", ["n": .number(30)]),
                "went on to delete — on a sample book the refusal would be mac.move_sample")
        #expect(shop.files.count == 33)
    }
}
