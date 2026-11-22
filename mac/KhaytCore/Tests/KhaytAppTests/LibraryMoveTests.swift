import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// The Swift port of `lib/print-library-migrate.js`, against the real module
/// under Node — the same inputs through both.
struct LibraryMoveParityTests {
    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        const PLM = require('./lib/print-library-migrate.js');
        process.stdout.write(JSON.stringify(\(expression)));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.currentDirectoryURL = LibraryLocationParityTests.repoRoot
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("which folders are moved out of: never the destination, the mirror, or one nested either way")
    func sources() throws {
        let cases: [([String], String, String?)] = [
            (["/new", "/vault", "/old", "/mirror"], "/new", "/mirror"),
            (["/lib", "/lib/sub", "/other"], "/lib", nil),
            (["/a", "/a", " /b ", ""], "/c", nil),
            (["/x/library2", "/x/lib"], "/x/lib", nil),
        ]
        for (roots, primary, mirror) in cases {
            let js = try Self.node("PLM.sources(\(roots.debugDescription), \(primary.debugDescription), \(mirror.map(\.debugDescription) ?? "null"))")
            let swift = LibraryMove.sources(roots: roots, primary: primary, mirror: mirror)
            #expect(js == .array(swift.map(JSONValue.string)), "\(roots) → \(primary)")
        }
    }

    /// Where the two DIFFER, on purpose. `convert-paths.js under` asks for
    /// `'/' + '/'` as the prefix, so to it `/lib` is not inside `/`, and a
    /// remembered root of `/` would be walked as a folder to move files OUT
    /// of — the whole disk. The port keeps it out. Reported to the desktop
    /// app's owners (Sep 2026).
    @Test("the root of the disk is never a folder to move files out of")
    func neverTheWholeDisk() {
        #expect(LibraryMove.sources(roots: ["/", "/lib", "/other"], primary: "/lib", mirror: nil) == ["/other"])
        #expect(LibraryMove.under("/lib", "/"))
    }

    @Test("move, duplicate or collision, as the other app decides")
    func decide() throws {
        for (exists, a, b) in [(false, "h", nil), (true, "h", "h"), (true, "h", "g"), (true, nil, nil) as (Bool, String?, String?)] {
            let js = try Self.node("PLM.decide({destExists: \(exists), srcHash: \(a.map(\.debugDescription) ?? "null"), destHash: \(b.map(\.debugDescription) ?? "null")})")
            #expect(js == .string(LibraryMove.decide(destExists: exists, srcHash: a, destHash: b)))
        }
    }

    @Test("a free name, suffixed before the extension")
    func names() throws {
        let cases: [(String, [String])] = [
            ("a.stl", []), ("a.stl", ["a.stl"]), ("a.stl", ["a.stl", "a (moved).stl"]),
            (".hidden", [".hidden"]), ("noext", ["noext"]), ("", [""]),
        ]
        for (name, taken) in cases {
            let js = try Self.node("PLM.collisionName(\(name.debugDescription), \(taken.debugDescription))")
            #expect(js == .string(LibraryMove.collisionName(name, taken: taken)), "\(name) \(taken)")
        }
    }

    @Test("the root being left is remembered, and a root moved back to is not history")
    func remember() throws {
        let cases: [(String, [String], String)] = [
            ("/nas", [], "/icloud"), ("", [], "/icloud"), ("/icloud", ["/nas"], "/nas"),
            ("/vault", [], "/x"), ("/nas", ["/nas"], "/y"),
        ]
        for (root, history, next) in cases {
            let settings: [String: JSONValue] = ["root": .string(root), "history": .array(history.map(JSONValue.string))]
            let js = try Self.node("PLM.rememberRoot({root: \(root.debugDescription), history: \(history.debugDescription)}, \(next.debugDescription), '/vault')")
            #expect(js == .object(LibraryMove.rememberRoot(settings, next: next, defaultRoot: "/vault")), "\(root) → \(next)")
        }
    }
}

/// The one step that removes anything, on a real disk.
struct LibraryMoveDiskTests {
    func dirs() throws -> (from: URL, to: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "libmove-\(UUID().uuidString)")
        let from = base.appending(path: "old/PF-1"), to = base.appending(path: "new/PF-1")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        return (from, to)
    }

    @Test("moved, proved, and only then the original to the Trash")
    func moves() throws {
        let (from, to) = try dirs()
        let src = from.appending(path: "Benchy.3mf")
        try Data(repeating: 7, count: 5000).write(to: src)
        var trashed: [URL] = []
        let r = try LibraryMove.moveOne(src, to: to, filename: "Benchy.3mf") { url in
            #expect(FileManager.default.fileExists(atPath: to.appending(path: "Benchy.3mf").path),
                    "the original went before its copy existed")
            trashed.append(url)
        }
        #expect(r.action == LibraryMove.move && trashed == [src])
        #expect(try Data(contentsOf: to.appending(path: "Benchy.3mf")) == Data(repeating: 7, count: 5000))
    }

    @Test("the same bytes already there: nothing copied, the original goes; different bytes: both kept")
    func duplicatesAndCollisions() throws {
        let (from, to) = try dirs()
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let same = from.appending(path: "a.stl"), other = from.appending(path: "b.stl")
        try Data([1, 2, 3]).write(to: same); try Data([1, 2, 3]).write(to: to.appending(path: "a.stl"))
        try Data([9, 9]).write(to: other); try Data([1]).write(to: to.appending(path: "b.stl"))
        var trashed: [URL] = []
        #expect(try LibraryMove.moveOne(same, to: to, filename: "a.stl") { trashed.append($0) }.action == LibraryMove.same)
        let c = try LibraryMove.moveOne(other, to: to, filename: "b.stl") { trashed.append($0) }
        #expect(c.action == LibraryMove.collision && c.name == "b (moved).stl")
        #expect(try Data(contentsOf: to.appending(path: "b.stl")) == Data([1]), "a different file was overwritten")
        #expect(try Data(contentsOf: to.appending(path: "b (moved).stl")) == Data([9, 9]))
        #expect(trashed == [same, other])
    }

    @Test("a Trash that refuses leaves the original where it was, and says so")
    func trashRefuses() throws {
        let (from, to) = try dirs()
        let src = from.appending(path: "x.stl")
        try Data([4, 5]).write(to: src)
        struct NoTrash: Error {}
        #expect(throws: NoTrash.self) {
            try LibraryMove.moveOne(src, to: to, filename: "x.stl") { _ in throw NoTrash() }
        }
        #expect(FileManager.default.fileExists(atPath: src.path))
    }
}
