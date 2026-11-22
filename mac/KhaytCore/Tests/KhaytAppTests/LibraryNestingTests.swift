import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A project with levels in it keeps them.
///
/// ── WHAT WAS REPORTED ─────────────────────────────────────────────────────
///
/// *"in library it only shows one folder even though I added a project with
/// multiple levels"* — and then, precisely: *"only the files in the first
/// folder, all sub folders skipped"*.
///
/// Nothing was skipped. The walk found every file; `ImportGrouping` returned
/// only the DEEPEST folder that named something, so
///
///     MyProject/base.stl            → MyProject
///     MyProject/pose 1/Blue/a.stl   → Blue
///     MyProject/pose 2/Grey/b.stl   → Grey
///
/// left the project holding one file and its contents scattered into sibling
/// folders with no project above them. From the library that is exactly what
/// "all sub folders skipped" looks like.
@MainActor
struct LibraryNestingTests {

    static func file(_ id: String, group: String?) -> LibraryFile {
        var row: [String: JSONValue] = ["id": .string(id), "name": .string(id + ".stl")]
        if let group { row["folder"] = .string(group) }
        return try! JSONDecoder().decode(LibraryFile.self,
                                         from: JSONEncoder().encode(JSONValue.object(row)))
    }

    static let pack = [
        file("base", group: "MyProject"),
        file("blue-a", group: "MyProject/pose 1/Blue"),
        file("blue-b", group: "MyProject/pose 1/Blue"),
        file("red-a", group: "MyProject/pose 1/Red"),
        file("grey-a", group: "MyProject/pose 2/Grey"),
        file("loose", group: nil),
    ]

    static func order(_ a: LibraryFile, _ b: LibraryFile) -> Bool { a.id < b.id }

    static func names(_ entries: [LibraryEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .folder(let name, _, let count, _): return "\(name)/ (\(count))"
            case .file(let f): return f.id
            }
        }
    }

    @Test("the top shows the project as ONE folder, not its leaves as siblings")
    func atTheTop() {
        let top = LibraryEntry.top(of: Self.pack, under: nil, order: Self.order)
        #expect(Self.names(top) == ["MyProject/ (5)", "loose"], Comment(rawValue:
            "\(Self.names(top)) — the project's inner levels are siblings again"))
    }

    @Test("opening the project shows its levels and the files that sit in it")
    func insideTheProject() {
        let inside = LibraryEntry.top(of: Self.pack, under: "MyProject", order: Self.order)
        // `base` sits at this level; the poses are folders below it.
        #expect(Self.names(inside) == ["pose 1/ (3)", "pose 2/ (1)", "base"],
                Comment(rawValue: "\(Self.names(inside))"))
    }

    @Test("opening a level shows the level below it")
    func deeperStill() {
        let inside = LibraryEntry.top(of: Self.pack, under: "MyProject/pose 1", order: Self.order)
        #expect(Self.names(inside) == ["Blue/ (2)", "Red/ (1)"], Comment(rawValue: "\(Self.names(inside))"))
        let leaf = LibraryEntry.top(of: Self.pack, under: "MyProject/pose 1/Blue", order: Self.order)
        #expect(Self.names(leaf) == ["blue-a", "blue-b"], Comment(rawValue: "\(Self.names(leaf))"))
    }

    @Test("a folder opens by its PATH, so two projects may each have a Blue")
    func pathsNotNames() {
        let two = [Self.file("a", group: "One/Blue"), Self.file("b", group: "Two/Blue")]
        let top = LibraryEntry.top(of: two, under: nil, order: Self.order)
        #expect(Self.names(top) == ["One/ (1)", "Two/ (1)"])
        let inOne = LibraryEntry.top(of: two, under: "One", order: Self.order)
        guard case .folder(_, let path, _, _)? = inOne.first else {
            Issue.record("no folder inside One"); return
        }
        #expect(path == "One/Blue", "opening it would show both projects' Blue")
    }

    @Test("a folder does not swallow a longer name that merely starts the same")
    func noPrefixBleed() {
        // `MyProject` must not contain `MyProjectile`. The separator is what
        // makes the difference, and a bare `hasPrefix` would lose it.
        #expect(Shop.isUnder("MyProject", "MyProject"))
        #expect(Shop.isUnder("MyProject/pose 1", "MyProject"))
        #expect(!Shop.isUnder("MyProjectile", "MyProject"))
        #expect(!Shop.isUnder(nil, "MyProject"))
    }

    @Test("a flat library is unchanged — one level is still one level")
    func flatStillWorks() {
        let flat = [Self.file("a", group: "Dragons"), Self.file("b", group: "Dragons"),
                    Self.file("c", group: nil)]
        #expect(Self.names(LibraryEntry.top(of: flat, under: nil, order: Self.order))
                == ["Dragons/ (2)", "c"])
        #expect(Self.names(LibraryEntry.top(of: flat, under: "Dragons", order: Self.order))
                == ["a", "b"])
    }
}
