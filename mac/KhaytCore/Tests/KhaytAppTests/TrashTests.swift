import Foundation
import Testing
@testable import KhaytApp

/// Deleting a model puts it where the Finder can get it back.
///
/// It used `removeItem`, so a model a shop deleted was gone — no undo in the
/// app by design, and none outside it either. The codebase argues the opposite
/// case in its own words a few hundred lines away, refusing a duplicate rather
/// than overwriting because "a duplicate is recoverable, a deletion is not".
struct TrashTests {

    @Test("a file goes to the Trash rather than off the disk")
    func itGoesToTheTrash() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "model.stl")
        try Data("solid x\nendsolid\n".utf8).write(to: file)

        try Shop.trash(file)
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "the file is still where it was")

        // And it is recoverable: somewhere OTHER than gone. `trashItem` on a
        // volume with a wastebasket leaves it in one.
        let home = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        if let home {
            let landed = (try? FileManager.default.contentsOfDirectory(
                at: home, includingPropertiesForKeys: nil))?
                .contains { $0.lastPathComponent.hasPrefix("model") } ?? false
            #expect(landed, "nothing named like it turned up in the Trash")
        }
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("a volume with no wastebasket keeps the file and says the delete was partial")
    func neverPermanently() throws {
        // This used to fall back to deleting outright on ANY Trash error. A
        // file-safety scan (Sep 2026) turned that round: a model the Trash
        // will not take stays where it is, the record goes, and the shop is
        // told the delete was partial. The Finder can still delete it by hand;
        // nothing the app does removes a model for good.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        guard let at = source.range(of: "static func trash(") else {
            Issue.record("trash is gone"); return
        }
        let body = String(source[at.lowerBound...].prefix(200))
        #expect(body.contains("trashItem"), "it deletes outright again")
        #expect(!body.contains("removeItem"), "a Trash error falls back to deleting for good again")
        #expect(source.contains("plib.delete_partial"), "a file left behind is no longer said")
    }

    @Test("the library's delete goes through it")
    func libraryUsesIt() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        guard let at = source.range(of: "func deleteLibraryFiles(") else {
            Issue.record("deleteLibraryFiles is gone"); return
        }
        let body = String(source[at.lowerBound...].prefix(1600))
        #expect(body.contains("Self.trash(url)"), "a deleted model is gone for good again")
        #expect(!body.contains("FileManager.default.removeItem(at: url)"),
                "the permanent delete is back beside the recoverable one")
    }
}
