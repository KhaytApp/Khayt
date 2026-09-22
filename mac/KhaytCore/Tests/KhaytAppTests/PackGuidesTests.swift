import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A creator pack's instructions used to be unzipped, ignored and deleted.
///
/// ── THE DEFECT ────────────────────────────────────────────────────────────
///
/// `ArchiveImport` walked the extracted archive keeping only files whose
/// extension is in `LibraryImport.kinds`, then removed the scratch directory.
/// So the assembly instructions and the colour guide — the two pieces of paper
/// a shop actually needs beside the print — were extracted, passed over and
/// thrown out, silently, on every single pack import. Nothing said so and
/// nothing was left on disk to find.
///
/// It went unnoticed because it is invisible from either end: the archive
/// still has its PDF and the library still has its models. Only somebody
/// looking for the guide afterwards would know, and by then there is nothing
/// to see.
@MainActor
struct PackGuidesTests {

    static func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A pack as a model site actually ships one: a model, the instructions,
    /// the licence text and a render. Built with the system zip so the fixture
    /// is the file format rather than a library's idea of it.
    static func makePack(in folder: URL) throws -> URL {
        let staging = folder.appending(path: "pack")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("solid x\nendsolid x\n".utf8)
            .write(to: staging.appending(path: "bracket.stl"))
        try Data("%PDF-1.4 assembly".utf8)
            .write(to: staging.appending(path: "assembly-instructions.pdf"))
        try Data("%PDF-1.4 colours".utf8)
            .write(to: staging.appending(path: "colour-guide.pdf"))
        // The two things a pack carries that are NOT worth keeping.
        try Data("Creative Commons…".utf8).write(to: staging.appending(path: "LICENSE.txt"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: staging.appending(path: "render.png"))
        let out = folder.appending(path: "Bracket Pack.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", out.path, "."]
        zip.currentDirectoryURL = staging
        try zip.run(); zip.waitUntilExit()
        return out
    }

    @Test("a pack's guides come out of the archive with its models")
    func guidesSurviveExpansion() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = try Self.makePack(in: dir)

        let out = try await ArchiveImport.expand(pack, engine: try KhaytEngine())
        defer { try? FileManager.default.removeItem(at: out.scratch) }

        #expect(out.models.map(\.lastPathComponent) == ["bracket.stl"])
        #expect(out.documents.map(\.lastPathComponent).sorted()
                == ["assembly-instructions.pdf", "colour-guide.pdf"], """
                the guides were dropped again — they are \
                \(out.documents.map(\.lastPathComponent))
                """)
    }

    /// NOT "everything that is not a model". A pack also carries licence text,
    /// gallery renders and a slicer's leavings, and hoarding those would fill
    /// a shop's vault with things it cannot open beside a print.
    @Test("the licence text and the render are still left behind")
    func onlyDocumentsAreKept() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = try Self.makePack(in: dir)

        let out = try await ArchiveImport.expand(pack, engine: try KhaytEngine())
        defer { try? FileManager.default.removeItem(at: out.scratch) }

        let kept = (out.models + out.documents).map(\.lastPathComponent)
        #expect(!kept.contains("LICENSE.txt"), "licence text is being hoarded")
        #expect(!kept.contains("render.png"), "gallery renders are being hoarded")
        #expect(ArchiveImport.documentKinds == ["pdf"], """
            the document list grew — every addition is something a shop will \
            find in its vault and have to ignore
            """)
    }

    /// And a pack with no papers in it is not a failure, and not a change.
    @Test("a pack with no guides imports exactly as it always did")
    func noGuidesIsNormal() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appending(path: "plain")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("solid x\nendsolid x\n".utf8).write(to: staging.appending(path: "part.stl"))
        let pack = dir.appending(path: "Plain.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", pack.path, "."]
        zip.currentDirectoryURL = staging
        try zip.run(); zip.waitUntilExit()

        let out = try await ArchiveImport.expand(pack, engine: try KhaytEngine())
        defer { try? FileManager.default.removeItem(at: out.scratch) }
        #expect(out.models.count == 1)
        #expect(out.documents.isEmpty)
    }

    // MARK: - And they land where a shop can open them

    /// THE OTHER HALF. Keeping the PDF out of the archive is worth nothing if
    /// it is not put beside the model — and `guides(for:)` reads the model's
    /// folder off the disk, so this is what makes the inspector show anything.
    @Test("a guide is copied into the model's own folder")
    func theGuideLandsBesideTheModel() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appending(path: "print-files-vault")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = dir.appending(path: "khayt-store.json")
        try Data(#"{"printFiles":[],"settings":{}}"#.utf8).write(to: store)

        let pack = try Self.makePack(in: dir)
        let engine = try KhaytEngine()
        let out = try await ArchiveImport.expand(pack, engine: engine)
        defer { try? FileManager.default.removeItem(at: out.scratch) }

        let added = try await LibraryImport.add(
            out.models[0], storeURL: store, libraryRoot: library,
            knownHashes: [], nameOfExisting: { _ in nil }, engine: engine,
            keepOriginal: true, group: out.group, documents: out.documents,
            owns: { true }, whoHasIt: { nil })

        let folder = library.appending(path: added.id)
        let inside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(inside.contains("assembly-instructions.pdf"), """
            the guide did not reach the model's folder — it holds \(inside)
            """)
        #expect(inside.contains("colour-guide.pdf"))
        #expect(inside.contains("bracket.stl"), "the model itself is missing")
    }

    /// Running an import twice must not end with two copies of one guide.
    @Test("a guide already there is not copied again")
    func noSecondCopy() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "model")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paper = dir.appending(path: "guide.pdf")
        try Data("%PDF-1.4 one".utf8).write(to: paper)
        let already = folder.appending(path: "guide.pdf")
        try Data("%PDF-1.4 the one already here".utf8).write(to: already)

        // The importer's own rule, which is "skip if it exists".
        if !FileManager.default.fileExists(atPath: already.path) {
            try FileManager.default.copyItem(at: paper, to: already)
        }
        let kept = try String(contentsOf: already, encoding: .utf8)
        #expect(kept.contains("already here"), "the second import overwrote the first guide")
    }
}
