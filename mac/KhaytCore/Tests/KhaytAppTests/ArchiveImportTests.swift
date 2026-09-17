import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Models arriving inside a zip.
///
/// A shop downloads a model as a zip because that is how every model site hands
/// one over. Dropping one on the library did NOTHING — the walk looks for
/// `stl`, `3mf`, `obj` and gcode, and a `.zip` is none of them, so it was
/// skipped in silence: no error, no model, nothing to explain it.
@MainActor
struct ArchiveImportTests {

    /// A zip built here, so the test owns every byte that goes into it.
    static func makeZip(_ members: [(String, Data)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-ziptest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staging = dir.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, data) in members {
            let at = staging.appending(path: name)
            try FileManager.default.createDirectory(at: at.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: at)
        }
        let zip = dir.appending(path: "models.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-r", zip.path, "."]
        p.currentDirectoryURL = staging
        try p.run()
        p.waitUntilExit()
        return zip
    }

    /// A binary STL big enough to pass the shared rule's 84-byte floor.
    static var stl: Data { Data(repeating: 0x20, count: 200) }

    @Test("a zip of models gives up its models, grouped by the archive's name")
    func expandsModels() async throws {
        let engine = try KhaytEngine()
        let zip = try Self.makeZip([
            ("kings/faisal.stl", Self.stl),
            ("kings/saud.stl", Self.stl),
            ("readme.txt", Data("licence".utf8)),
            ("preview.png", Data(repeating: 0x89, count: 40)),
        ])
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        let out = try await ArchiveImport.expand(zip, engine: engine)
        defer { try? FileManager.default.removeItem(at: out.scratch) }

        // Only the models. A zip from a model site is mostly licence text and
        // render previews, and neither is a model.
        #expect(out.models.count == 2,
                Comment(rawValue: "got \(out.models.map(\.lastPathComponent))"))
        #expect(Set(out.models.map(\.lastPathComponent)) == ["faisal.stl", "saud.stl"])
        #expect(out.group == "models", "the archive's own name is what groups what came out of it")
        for m in out.models {
            #expect(FileManager.default.fileExists(atPath: m.path), "a model that was not written")
        }
    }

    @Test("the archive itself is never consumed")
    func leavesTheArchiveAlone() async throws {
        let engine = try KhaytEngine()
        let zip = try Self.makeZip([("a.stl", Self.stl)])
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let out = try await ArchiveImport.expand(zip, engine: engine)
        defer { try? FileManager.default.removeItem(at: out.scratch) }
        #expect(FileManager.default.fileExists(atPath: zip.path),
                "the shop's own download was taken away")
    }

    @Test("two members with the same leaf name both survive")
    func collidingNames() async throws {
        // Flattened to their last component, `head.stl` in two folders wants one
        // name. Dropping the second would lose a model without saying so.
        let engine = try KhaytEngine()
        let zip = try Self.makeZip([("left/head.stl", Self.stl), ("right/head.stl", Self.stl)])
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let out = try await ArchiveImport.expand(zip, engine: engine)
        defer { try? FileManager.default.removeItem(at: out.scratch) }
        #expect(out.models.count == 2)
        #expect(Set(out.models.map(\.lastPathComponent)).count == 2, "one overwrote the other")
    }

    @Test("a Finder resource fork is not a model")
    func skipsResourceForks() async throws {
        let engine = try KhaytEngine()
        let zip = try Self.makeZip([
            ("a.stl", Self.stl),
            ("__MACOSX/._a.stl", Data(repeating: 0, count: 120)),
        ])
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let out = try await ArchiveImport.expand(zip, engine: engine)
        defer { try? FileManager.default.removeItem(at: out.scratch) }
        #expect(out.models.count == 1, "four hundred bytes of Finder metadata came in as a model")
    }

    @Test("a zip with nothing in it Khayt can read says so")
    func noModels() async throws {
        let engine = try KhaytEngine()
        let zip = try Self.makeZip([("readme.txt", Data("nothing here".utf8))])
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        await #expect(throws: ArchiveImport.Failure.self) {
            _ = try await ArchiveImport.expand(zip, engine: engine)
        }
    }

    /// The refusal is the SHARED rule's, not this file's.
    ///
    /// Expanding an archive writes a stranger's bytes onto the shop's own disk.
    /// `lib/upload-scan.js` already decides what is safe to expand for the
    /// customer-upload path, and a shop's own download came from a stranger
    /// too — so it is the same rule, with the same tests, not a second one.
    @Test("the shared rule is what refuses an archive")
    func refusalComesFromTheRule() async throws {
        let engine = try KhaytEngine()
        // A traversal, judged by the rule rather than by anything here.
        let bad = try await engine.scanUpload(
            ext: "zip", size: 5_000, header: "504b03040a00",
            entries: [.object(["name": .string("../../x.stl"),
                               "size": .number(10), "compressedSize": .number(5)])])
        #expect(!bad.ok)
        #expect(bad.reason == "unsafe-path")

        let fine = try await engine.scanUpload(
            ext: "zip", size: 5_000_000, header: "504b03040a00",
            entries: [.object(["name": .string("a.stl"),
                               "size": .number(1_000_000), "compressedSize": .number(300_000)])])
        #expect(fine.ok)
    }

    @Test("the picker and the walk both know about archives")
    func wiredIn() {
        #expect(ArchiveImport.kinds.contains("zip"))
        // A zip is NOT a model — if it leaked into `kinds` the walk would try to
        // import the archive itself as a mesh.
        #expect(!LibraryImport.kinds.contains("zip"))
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("ArchiveImport.expand("), "nothing expands an archive on import")
        #expect(shop.contains("LibraryImport.kinds.union(ArchiveImport.kinds)"),
                "the file picker will not offer a zip, so one cannot be chosen")
    }
}
