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

    /// A tgz of `src`, symlinks archived as symlinks (bsdtar's default).
    static func tgz(of src: URL, to archive: URL) throws {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", src.path, "."]
        try tar.run()
        tar.waitUntilExit()
    }

    /// A pack can carry a model's NAME on a symlink. The walk took names only,
    /// so `dragon.stl → ~/Library/…/khayt-store.json` was hashed, copied into
    /// the vault and uploaded to the bucket, and `→ /dev/zero` hashed for ever.
    @Test("a symlink in a pack is not a model, whatever it is called or points at")
    func symlinksAreNotModels() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appending(path: "khayt-store.json")
        try Data("{\"secret\":1}".utf8).write(to: secret)
        let src = dir.appending(path: "evil")
        try FileManager.default.createDirectory(at: src.appending(path: "STL"),
                                                withIntermediateDirectories: true)
        try Data("solid a\nendsolid\n".utf8).write(to: src.appending(path: "STL/part.stl"))
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: src.appending(path: "dragon.stl").path,
                                  withDestinationPath: secret.path)
        try fm.createSymbolicLink(atPath: src.appending(path: "zero.3mf").path,
                                  withDestinationPath: "/dev/zero")
        try fm.createSymbolicLink(atPath: src.appending(path: "near.stl").path,
                                  withDestinationPath: "STL/part.stl")
        try fm.createSymbolicLink(atPath: src.appending(path: "guide.pdf").path,
                                  withDestinationPath: secret.path)
        let archive = dir.appending(path: "evil.tgz")
        try Self.tgz(of: src, to: archive)

        let out = try await ArchiveImport.expand(archive, engine: try KhaytEngine())
        defer { try? FileManager.default.removeItem(at: out.scratch) }
        #expect(out.models.map(\.lastPathComponent) == ["part.stl"], Comment(rawValue:
            "\(out.models.map(\.lastPathComponent)) — a link came out as a model"))
        #expect(out.documents.isEmpty, "a linked PDF came out as a guide")
    }

    @Test("a pack of nothing but links has no models")
    func onlyLinks() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appending(path: "links")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: src.appending(path: "a.stl").path,
                                                   withDestinationPath: "/etc/hosts")
        let archive = dir.appending(path: "links.tgz")
        try Self.tgz(of: src, to: archive)
        await #expect(throws: ArchiveImport.Failure.self) {
            _ = try await ArchiveImport.expand(archive, engine: try KhaytEngine())
        }
    }

    @Test("only a regular file inside the scratch counts")
    func regularFileCheck() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.stl")
        try Data("x".utf8).write(to: file)
        #expect(ArchiveImport.isOwnRegularFile(file, under: dir))
        // The temporary directory is itself behind a symlink (/var → /private/var):
        // that must not make a real member look outside.
        #expect(ArchiveImport.isOwnRegularFile(file.resolvingSymlinksInPath(), under: dir))
        let other = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(!ArchiveImport.isOwnRegularFile(file, under: other))
        #expect(!ArchiveImport.isOwnRegularFile(dir, under: dir.deletingLastPathComponent()))
        #expect(!ArchiveImport.isOwnRegularFile(URL(fileURLWithPath: "/dev/zero"),
                                                under: URL(fileURLWithPath: "/dev")))
        #expect(!LibraryImport.isRegularFile(URL(fileURLWithPath: "/dev/zero")))
        let link = dir.appending(path: "l.stl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(!ArchiveImport.isOwnRegularFile(link, under: dir))
        #expect(!LibraryImport.isRegularFile(link))
    }

    @Test("a folder the shop picks gives up its files, not its links")
    func folderWalkSkipsLinks() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("solid a\nendsolid\n".utf8).write(to: dir.appending(path: "real.stl"))
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: "zero.stl").path,
                                                   withDestinationPath: "/dev/zero")
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: "key.3mf").path,
                                                   withDestinationPath: "/etc/hosts")
        let found = Shop.modelsUnder([dir], skippingAll: [])
        #expect(found.map(\.url.lastPathComponent) == ["real.stl"])
    }

    @Test("the cloud tier walk offers regular files only")
    func tierWalkSkipsLinks() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = root.appending(path: "PF-1")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data("solid a\nendsolid\n".utf8).write(to: item.appending(path: "real.stl"))
        try FileManager.default.createSymbolicLink(atPath: item.appending(path: "ssh.stl").path,
                                                   withDestinationPath: "/etc/hosts")
        let files = CloudLibrary.libraryFiles(root: root.path)
        #expect(files.map(\.filename) == ["real.stl"])
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
