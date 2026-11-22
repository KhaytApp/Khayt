import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Putting a library back together.
///
/// ── WHY THE NESTING FIX WAS NOT THE WHOLE ANSWER ──────────────────────────
///
/// #1448 made an import keep the folders a project came with. It could do
/// nothing for a library ALREADY imported flat — the original tree is not
/// recorded anywhere, so no migration can reconstruct it — and the shop that
/// reported the fault has twenty-three folders named `pose 1`, `Blue`, `eyes`
/// that each came from one project.
///
/// Filing works on a SELECTION, which means opening each folder, selecting all
/// of it and typing a path exactly, once per folder. This moves a folder and
/// everything under it in one go. `fix-the-data-already-on-disk`: a fix that
/// only helps new data strands what a shop already has.
@MainActor
struct MoveFolderTests {

    static func file(_ id: String, group: String?) -> LibraryFile {
        var row: [String: JSONValue] = ["id": .string(id), "name": .string(id + ".stl")]
        if let group { row["folder"] = .string(group) }
        return try! JSONDecoder().decode(LibraryFile.self,
                                         from: JSONEncoder().encode(JSONValue.object(row)))
    }

    /// Where each file would end up, worked out the way `moveFolder` does.
    static func after(_ files: [LibraryFile], move path: String, under parent: String?)
    -> [String: String] {
        let leaf = path.components(separatedBy: ImportGrouping.separator).last ?? path
        let destination = (parent?.isEmpty == false)
            ? parent! + ImportGrouping.separator + leaf : leaf
        var out: [String: String] = [:]
        for f in files where Shop.isUnder(f.groupName, path) {
            out[f.id] = destination + (f.groupName ?? "").dropFirst(path.count)
        }
        return out
    }

    @Test("a folder takes everything under it, each file keeping its own depth")
    func theSubtreeMoves() {
        let files = [Self.file("a", group: "Blue"),
                     Self.file("b", group: "Blue/left"),
                     Self.file("c", group: "Blue/left/pins"),
                     Self.file("d", group: "Red")]
        let moved = Self.after(files, move: "Blue", under: "Helmet/pose 1")
        #expect(moved["a"] == "Helmet/pose 1/Blue")
        #expect(moved["b"] == "Helmet/pose 1/Blue/left")
        #expect(moved["c"] == "Helmet/pose 1/Blue/left/pins",
                "a three-level folder arrived flattened")
        #expect(moved["d"] == nil, "a folder that was not moved came along")
    }

    @Test("moving to the top strips the path down to the folder itself")
    func outToTheTop() {
        let files = [Self.file("a", group: "Helmet/pose 1/Blue"),
                     Self.file("b", group: "Helmet/pose 1/Blue/left")]
        let moved = Self.after(files, move: "Helmet/pose 1/Blue", under: nil)
        #expect(moved["a"] == "Blue")
        #expect(moved["b"] == "Blue/left")
    }

    @Test("a folder is never offered a home inside itself")
    func notIntoItself() {
        // Writing a path that contains its own prefix would take the folder
        // off the level it was on and put it somewhere unreachable.
        #expect(Shop.isUnder("Helmet/pose 1", "Helmet"),
                "a descendant is not recognised, so it would be offered")
        #expect(!Shop.isUnder("Helmet", "Helmet/pose 1"))
        // And the guard in `moveFolder` reads the same way round.
        #expect(Shop.isUnder("Helmet/Helmet", "Helmet"))
    }

    @Test("every level is a place to move to, not only the leaves")
    func everyLevelIsADestination() async {
        let shop = Shop()
        await shop.load(.sample)
        // Driven over a known set rather than the sample, whose library is
        // flat — what is being checked is that the in-between levels appear.
        let files = [Self.file("a", group: "A/B/C"), Self.file("b", group: "D")]
        var seen = Set<String>()
        for group in files.compactMap { $0.groupName } {
            var parts: [String] = []
            for level in group.components(separatedBy: ImportGrouping.separator) {
                parts.append(level)
                seen.insert(parts.joined(separator: ImportGrouping.separator))
            }
        }
        #expect(seen == ["A", "A/B", "A/B/C", "D"], Comment(rawValue: "\(seen.sorted())"))
    }

    @Test("the folder offers the move, and it is a write")
    func wired() throws {
        let grid = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/LibraryGrid.swift"), encoding: .utf8)
        #expect(grid.contains("FolderMoveMenu(shop: shop, path: path)"),
                "a folder cannot be moved, so a flat library stays flat")
        #expect(grid.contains("!Shop.isUnder($0, path)"), Comment(rawValue:
            "a folder is offered a home inside itself, which writes a path containing "
            + "its own prefix and loses the folder"))
        #expect(grid.contains("disabled(!shop.canMoveJobs)"),
                "a book this app does not own can be rearranged")
    }
}
