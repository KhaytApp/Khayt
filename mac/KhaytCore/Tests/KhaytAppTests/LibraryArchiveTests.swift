import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Archiving by hand, and the Archived view it is undone from.
///
/// `archivedAt` was written only by a conversion (`supersede`), and the
/// function that cleared it had no caller: a model put aside could not be
/// found again from this app, and nothing could be put aside on purpose.
@MainActor
struct LibraryArchiveTests {

    static func row(_ i: Int, archived: Bool = false, tag: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(String(format: "PF-A%04d", i)), "name": .string("Model \(i)"),
            "createdAt": .number(1_750_000_000_000 + Double(i) * 1000),
        ]
        if archived { o["archivedAt"] = .string("2026-10-01T09:00:00.000Z") }
        if let tag { o["tags"] = .array([.string(tag)]) }
        return .object(o)
    }

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendLibrary((0..<10).map { row($0, archived: $0 % 4 == 0) })
        shop.clearLibraryFilter()
        shop.search = ""
        shop.shelf = .library(nil)
        shop.libraryFlat = true
        return shop
    }

    @Test("the library hides what is put aside, and the Archived view shows only that")
    func archivedViewIsOnlyArchived() async {
        let shop = await Self.shop()
        #expect(shop.shownFiles.count == 7)
        #expect(shop.shownFiles.allSatisfy { !$0.isArchived })
        shop.libraryShowArchived = true
        #expect(Set(shop.shownFiles.map(\.id)) == ["PF-A0000", "PF-A0004", "PF-A0008"])
        // It is a view the shop is IN, so Clear Filters takes it away.
        #expect(shop.libraryFilterOn)
        shop.clearLibraryFilter()
        #expect(!shop.libraryShowArchived)
        #expect(shop.shownFiles.count == 7)
    }

    @Test("leaving the Archived view drops a selection it can no longer see")
    func leavingPrunesSelection() async throws {
        let shop = await Self.shop()
        shop.libraryShowArchived = true
        let aside = try #require(shop.shownFiles.first)
        shop.select(aside, modifiers: .replace)
        #expect(shop.selectedFile?.id == aside.id)
        shop.libraryShowArchived = false
        #expect(shop.fileSelection.isEmpty)
    }

    @Test("the Show menu counts the archived, and the other chips stop counting them")
    func facetsFollowTheView() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendLibrary((0..<10).map { Self.row($0, archived: $0 % 4 == 0, tag: "dragon") })
        shop.libraryRows = (0..<10).map { Self.row($0, archived: $0 % 4 == 0, tag: "dragon") }
        shop.clearLibraryFilter()
        shop.shelf = .library(nil)
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.archived == 3)
        #expect(shop.libraryFacets.tags.first?.count == 7, "a tag chip counted models the grid cannot draw")
        shop.libraryShowArchived = true
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.tags.first?.count == 3)
        #expect(shop.libraryFacets.archived == 3, "the view's own count must not narrow to itself")
    }

    @Test("Archive and Restore act on the selection when the clicked model is in it")
    func targetsFollowSelection() async throws {
        let shop = await Self.shop()
        let shown = shop.shownFiles
        shop.select(shown[0], modifiers: .replace)
        shop.select(shown[1], modifiers: .toggle)
        #expect(shop.archiveTargets(for: shown[0], archiving: true) == [shown[0].id, shown[1].id])
        // Right-clicking one OUTSIDE the selection is that one alone.
        #expect(shop.archiveTargets(for: shown[2], archiving: true) == [shown[2].id])
        // Restore never offers what is not put aside.
        #expect(shop.archiveTargets(for: shown[0], archiving: false).isEmpty)
        #expect(shop.selectedArchiveIds(false) == [shown[0].id, shown[1].id])
        #expect(shop.selectedArchiveIds(true).isEmpty)
    }

    @Test("the menus and the inspector offer it, and every word has both languages")
    func wiredAndWorded() throws {
        let actions = try String(contentsOf: GroupFromRightClickTests.source("FileActions.swift"), encoding: .utf8)
        #expect(actions.contains("shop.archive(aside)") && actions.contains("shop.unarchive(aside)"))
        let inspector = try String(contentsOf: GroupFromRightClickTests.source("LibraryInspector.swift"), encoding: .utf8)
        #expect(inspector.contains("archiveButton(file)") && inspector.contains("shop.unarchive([file.id])"))
        let menus = try String(contentsOf: GroupFromRightClickTests.source("Menus.swift"), encoding: .utf8)
        #expect(menus.contains("shop.archive(shop.selectedArchiveIds(false))"))
        let many = try String(contentsOf: GroupFromRightClickTests.source("GroupMenu.swift"), encoding: .utf8)
        #expect(many.contains("shop.archive(aside)") && many.contains("shop.unarchive(back)"))
        let bar = try String(contentsOf: GroupFromRightClickTests.source("LibraryFilterBar.swift"), encoding: .utf8)
        #expect(bar.contains("\"never-printed\", \"archived\""), "the Archived view is not in the Show menu")
        for key in ["mac.archive_model", "mac.archive_n_models", "mac.unarchive_model", "mac.unarchive_n_models",
                    "mac.lib_archived", "mac.archived_on", "mac.archived_undated", "mac.archive_help"] {
            let entry = try #require(Words.own[key], "\(key) is missing")
            #expect(entry["en"]?.isEmpty == false && entry["ar"]?.isEmpty == false, "\(key)")
        }
    }
}

/// In the serialised suite that owns the test support folder.
extension LibraryEditPerfTests {

    @Test("archiving writes the date, deletes nothing, and Undo brings it back")
    func archiveRoundTrip() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 30)) { shop, url in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            // A vault model, with its file where the library keeps it.
            let file = try #require(shop.files.first { !$0.isLinked && !$0.isArchived })
            let primary = try #require(shop.libraryRoots?.primary)
            let dir = URL(fileURLWithPath: primary).appending(path: LibraryLocation.itemDirName(file.id))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let model = dir.appending(path: file.sourceFile?.filename ?? "model.3mf")
            try Data("solid x".utf8).write(to: model)
            let other = try #require(shop.files.first { $0.id != file.id && !$0.isArchived })
            let before = try diskRows(url).count

            undo.beginUndoGrouping()
            #expect(shop.archive([file.id, other.id]))
            undo.endUndoGrouping()
            await shop.settleLibraryWrites()
            func record(_ id: String) throws -> [String: JSONValue]? {
                for case .object(let o) in try diskRows(url) where o["id"] == .string(id) { return o }
                return nil
            }
            #expect(try record(file.id)?["archivedAt"] != nil)
            #expect(try record(file.id)?["supersededBy"] == nil, "a hand archive names no replacement")
            #expect(try diskRows(url).count == before, "archiving removed a record")
            #expect(FileManager.default.fileExists(atPath: model.path), "archiving touched the file")
            #expect(shop.files.first { $0.id == file.id }?.isArchived == true)
            #expect(!shop.shownFiles.contains { $0.id == file.id })

            undo.undo()
            await shop.settleLibraryWrites()
            #expect(try record(file.id)?["archivedAt"] == nil, "undo did not bring it back")
            #expect(try record(other.id)?["archivedAt"] == nil)

            // And from the Archived view, by hand.
            shop.undoManager = nil
            #expect(shop.archive([file.id]))
            await shop.settleLibraryWrites()
            shop.libraryShowArchived = true
            #expect(shop.shownFiles.map(\.id) == [file.id])
            #expect(shop.unarchive([file.id]))
            await shop.settleLibraryWrites()
            #expect(try record(file.id)?["archivedAt"] == nil)
            #expect(shop.shownFiles.isEmpty)
        }
    }
}
