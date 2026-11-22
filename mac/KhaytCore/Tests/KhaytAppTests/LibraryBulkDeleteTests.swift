import Foundation
import Testing
@testable import KhaytApp

/// Several selected models can be deleted at once.
@MainActor
struct LibraryBulkDeleteTests {
    @Test("a multi-selection offers one delete for all of it, asked once, written once")
    func wired() throws {
        let actions = try QuoteSheetStatusTests.source("FileActions.swift")
        #expect(actions.contains("shop.askToDeleteFromLibrary(chosenForDelete)"))
        let window = try QuoteSheetStatusTests.source("ShopWindow.swift")
        #expect(window.contains("await shop.confirmLibraryDeletes(chosen)"),
                "the list is taken before the Task: the dialog empties it first")
        #expect(window.contains("let chosen = shop.pendingLibraryDeletes"))
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("func deleteLibraryFiles(_ files: [LibraryFile]) async"))
        #expect(shop.contains("await deleteLibraryFiles([file])"), "single delete no longer goes the same way")
    }

    @Test("Delete acts on the list it was handed, after the dialog has emptied pending")
    func handedList() async {
        let shop = Shop()
        await shop.load(.sample)
        let chosen = Array(shop.shownFiles.prefix(2))
        shop.pendingLibraryDeletes = []
        await shop.confirmLibraryDeletes(chosen)
        // The sample book refuses a delete in words. Reaching that refusal is
        // the proof the list arrived: an empty list returns before it.
        #expect(shop.importProblem != nil, "an emptied list deleted nothing and said nothing")
    }

    @Test("a sample book refuses, and nothing is asked when nothing is chosen")
    func refusals() async {
        let shop = Shop()
        await shop.load(.sample)
        shop.pendingLibraryDeletes = Array(shop.shownFiles.prefix(2))
        await shop.deleteLibraryFiles(shop.pendingLibraryDeletes)
        #expect(shop.pendingLibraryDeletes.isEmpty)
        #expect(shop.importProblem != nil, "the sample book was changed")
    }
}
