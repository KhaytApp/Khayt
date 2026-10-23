import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Renaming a model: its title, through the store's write chain, undoable.
@MainActor
struct LibraryRenameTests {

    @Test("a typed title is one line, trimmed")
    func cleanTitle() {
        #expect(Shop.cleanTitle("  Falcon hood \n") == "Falcon hood")
        #expect(Shop.cleanTitle("Falcon\nhood") == "Falcon hood")
        #expect(Shop.cleanTitle(" دلة  القهوة ") == "دلة  القهوة")
        #expect(Shop.cleanTitle(" \n ").isEmpty)
    }

    @Test("the inspector, the right-click menu and the Model menu all open the one field")
    func wired() throws {
        let actions = try String(contentsOf: GroupFromRightClickTests.source("FileActions.swift"), encoding: .utf8)
        #expect(actions.contains("shop.beginRename(file)"))
        let menus = try String(contentsOf: GroupFromRightClickTests.source("Menus.swift"), encoding: .utf8)
        #expect(menus.contains("shop.beginRename(one)"))
        let inspector = try String(contentsOf: GroupFromRightClickTests.source("LibraryInspector.swift"), encoding: .utf8)
        #expect(inspector.contains("ModelTitle(shop: shop, file: file)"))
        #expect(inspector.contains("shop.rename(file.id, to: draft)"))
        // Written the way every library edit is: never a bare store write.
        let shop = try String(contentsOf: GroupFromRightClickTests.source("Shop+Library.swift"), encoding: .utf8)
        let body = try #require(shop.range(of: "func rename(_ id: LibraryFile.ID")).upperBound
        let next = String(shop[body...].prefix(600))
        #expect(next.contains("editFiles([id]"), "rename does not go through the write chain")
        for key in ["mac.rename_model", "mac.rename_model_undo"] {
            let entry = try #require(Words.own[key], "\(key) is missing")
            #expect(entry["en"]?.isEmpty == false && entry["ar"]?.isEmpty == false)
        }
    }

    @Test("Rename… selects the model it was asked for")
    func beginSelects() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.clearLibraryFilter()
        shop.shelf = .library(nil)
        let files = shop.visibleFiles
        try #require(files.count >= 2)
        shop.select(files[0], modifiers: .replace)
        shop.beginRename(files[1])
        #expect(shop.fileSelection == [files[1].id])
        #expect(shop.renamingFileId == files[1].id)
    }
}

extension LibraryEditPerfTests {

    @Test("renaming writes the title only, is found by search at once, and Undo puts it back")
    func renameRoundTrip() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 20)) { shop, url in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            let file = try #require(shop.files.first)
            let was = file.name
            func record() throws -> [String: JSONValue]? {
                for case .object(let o) in try diskRows(url) where o["id"] == .string(file.id) { return o }
                return nil
            }
            let before = try #require(try record())

            shop.clearLibraryFilter()
            shop.shelf = .library(nil)
            shop.libraryFlat = true
            shop.search = "دلة"
            #expect(shop.shownFiles.isEmpty)

            undo.beginUndoGrouping()
            #expect(shop.rename(file.id, to: "  دلّة القهوة \n"))
            undo.endUndoGrouping()
            await shop.settleLibraryWrites()
            let after = try #require(try record())
            #expect(after["name"] == .string("دلّة القهوة"))
            #expect(after["originalName"] == before["originalName"], "renaming touched the file's name")
            #expect(after["sourceFile"] == before["sourceFile"])
            // Typed without the shadda, found all the same.
            #expect(shop.shownFiles.map(\.id) == [file.id], "the memoised search kept the old title")

            #expect(!shop.rename(file.id, to: "   "), "a blank title was accepted")
            #expect(!shop.rename(file.id, to: "دلّة القهوة"), "a rename to the same title wrote")

            undo.undo()
            await shop.settleLibraryWrites()
            #expect(try record()?["name"] == .string(was))
            #expect(shop.shownFiles.isEmpty)
            shop.search = ""
            shop.undoManager = nil
        }
    }
}
