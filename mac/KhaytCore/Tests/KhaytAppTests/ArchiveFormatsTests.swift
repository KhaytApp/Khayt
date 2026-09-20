import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The archives a model pack actually arrives in.
///
/// A pack downloaded from a model site is a zip about as often as it is a RAR
/// or a 7-Zip, and this app opened only the zip. The others were not refused
/// with a reason — they were not archives as far as the import was concerned,
/// so a shop dropping one in got "nothing to import".
///
/// libarchive does the reading, through `bsdtar`, which macOS ships.
@MainActor
struct ArchiveFormatsTests {

    static func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-arc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A gzipped tar with a model inside a subfolder — the shape a pack has.
    static func madeTgz(in dir: URL) throws -> URL {
        let src = dir.appending(path: "pack")
        try FileManager.default.createDirectory(at: src.appending(path: "STL"),
                                                withIntermediateDirectories: true)
        try Data("solid a\nendsolid\n".utf8)
            .write(to: src.appending(path: "STL/part.stl"))
        try Data("not a model".utf8).write(to: src.appending(path: "readme.txt"))
        let archive = dir.appending(path: "pack.tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", src.path, "."]
        try tar.run()
        tar.waitUntilExit()
        return archive
    }

    @Test("a gzipped pack opens, and only its models come out")
    func itOpens() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Self.madeTgz(in: dir)
        let engine = try KhaytEngine()

        let out = try await ArchiveImport.expand(archive, engine: engine)
        defer { try? FileManager.default.removeItem(at: out.scratch) }
        #expect(out.models.count == 1, Comment(rawValue:
            "\(out.models.map(\.lastPathComponent)) — the readme came out as a model"))
        #expect(out.models.first?.lastPathComponent == "part.stl")
        // Grouped by the archive's own name, as a zip is.
        #expect(out.group == "pack", Comment(rawValue: out.group ?? "nil"))
    }

    @Test("the formats a pack arrives in are all offered")
    func theKinds() {
        for kind in ["zip", "rar", "7z", "tgz"] {
            #expect(ArchiveImport.kinds.contains(kind), Comment(rawValue: kind))
        }
        // A bare `.tar` is deliberately absent: its magic is at offset 257,
        // which is not in the header the shared rule is given, so the check
        // would always pass and check nothing.
        #expect(!ArchiveImport.kinds.contains("tar"))
    }

    @Test("an archive wearing the wrong name is refused by the shared rule")
    func wrongMagic() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A zip renamed to .rar. The magic says zip; the name says RAR.
        let fake = dir.appending(path: "liar.rar")
        try Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 64)).write(to: fake)
        let engine = try KhaytEngine()
        await #expect(throws: ArchiveImport.Failure.self) {
            _ = try await ArchiveImport.expand(fake, engine: engine)
        }
    }

    @Test("a local pack is judged against a local budget, not the intake route's")
    func localBudget() async throws {
        // The rule's own cap is 32 MB, sized for a stranger posting a file over
        // HTTP. A pack the shop already has is routinely larger, and refusing
        // one as "too-large" reads as the app being broken.
        let engine = try KhaytEngine()
        let big = 400 * 1024 * 1024
        let entries: [JSONValue] = [.object(["name": .string("a.stl"),
                                             "size": .number(10),
                                             "compressedSize": .number(5)])]
        let underIntake = try await engine.scanUpload(ext: "zip", size: big,
                                                      header: "504b0304", entries: entries)
        #expect(!underIntake.ok, "the intake cap no longer bites, so this proves nothing")
        #expect(underIntake.reason == "too-large")

        let underLocal = try await engine.scanUpload(ext: "zip", size: big,
                                                     header: "504b0304", entries: entries,
                                                     maxBytes: ArchiveImport.localBudget)
        #expect(underLocal.ok, Comment(rawValue:
            "a \(big / 1024 / 1024) MB pack on the shop's own disk is still refused"))
    }
}
