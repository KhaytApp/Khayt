import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `Khayt --import` — the arguments, which are pure and therefore the half
/// worth testing exhaustively. What they lead to is `LibraryImport.addMany`,
/// tested below against real files.
@MainActor
struct ImportCommandTests {

    static func parse(_ line: String) -> ImportCommand.Parsed {
        // argv[0] is the executable, as it is in a real launch.
        ImportCommand.parse(["/Applications/Khayt.app/Contents/MacOS/Khayt"]
                            + line.split(separator: " ").map(String.init))
    }

    @Test("an ordinary launch is left alone")
    func notAsked() {
        #expect(Self.parse("") == .notAsked)
        // A file opened from the Finder is not an import request.
        #expect(Self.parse("/Users/someone/thing.3mf") == .notAsked)
    }

    @Test("a folder to import")
    func simple() {
        #expect(Self.parse("--import /models") == .run(.init(paths: ["/models"])))
    }

    @Test("several paths, and both flags")
    func everything() {
        #expect(Self.parse("--import /a /b --dry-run --keep-originals")
                == .run(.init(paths: ["/a", "/b"], keepOriginals: true, dryRun: true)))
        // Order is not part of the grammar.
        #expect(Self.parse("--dry-run --import /a") == .run(.init(paths: ["/a"], dryRun: true)))
    }

    @Test("--import with nothing to import says so rather than doing nothing")
    func needsAPath() {
        guard case .usage(let message) = Self.parse("--import") else {
            Issue.record("accepted an import with no path"); return
        }
        #expect(message.contains("at least one"))
    }

    /// A mistyped flag must not be read as a PATH. `--dryrun` silently treated
    /// as a folder name would walk nothing, find nothing, and look like an
    /// import that ran — for a command whose whole job is moving files.
    @Test("an option Khayt does not know is refused, not treated as a folder")
    func unknownOption() {
        for wrong in ["--dryrun", "--keep", "-n", "--import-all"] {
            guard case .usage = Self.parse("--import /a \(wrong)") else {
                Issue.record("\(wrong) was accepted"); return
            }
        }
    }

    /// AppKit adds its own arguments to a launched bundle, and Finder adds
    /// `-psn_…`. Read as paths they would each be reported as missing and the
    /// run would refuse before importing anything.
    @Test("the arguments AppKit adds are ignored")
    func systemArguments() {
        #expect(Self.parse("--import /a -psn_0_12345") == .run(.init(paths: ["/a"])))
        #expect(Self.parse("--import /a -NSDocumentRevisionsDebugMode")
                == .run(.init(paths: ["/a"])))
    }

    @Test("the usage line names every option it accepts")
    func usageIsComplete() {
        for flag in ["--import", "--keep-originals", "--dry-run"] {
            #expect(ImportCommand.usage.contains(flag), "\(flag) is undocumented")
        }
    }
}

/// The batch loop, which the File menu and `--import` share.
@MainActor
struct AddManyTests {

    static func stl(_ dir: URL, _ name: String, size: Double = 10) throws -> URL {
        let url = dir.appending(path: name)
        try MeshTests.binarySTL(MeshTests.boxFacets(size, size, size)).write(to: url)
        return url
    }

    static func run(_ files: [URL], _ bench: LibraryImportEndToEndTests.Bench,
                    stop: @escaping () -> Bool = { false }) async throws -> LibraryImport.Report {
        await LibraryImport.addMany(files, storeURL: bench.store, libraryRoot: bench.library,
                                    knownHashes: [], nameOfExisting: { _ in "one you have" },
                                    engine: try KhaytEngine(),
                                    owns: { true }, whoHasIt: { nil }, shouldStop: stop)
    }

    /// The reason `known` grows inside the loop: the same model downloaded
    /// twice under two names, both in one selection.
    @Test("two copies of one model in a single batch: one goes in")
    func duplicatesWithinTheBatch() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let a = try Self.stl(bench.dir, "cube.stl")
        let b = try Self.stl(bench.dir, "cube copy.stl")

        let report = try await Self.run([a, b], bench)
        #expect(report.moved == 1)
        #expect(report.duplicates == 1)
        #expect(try LibraryImportEndToEndTests.printFiles(in: bench).count == 1)
        // And the refused one is still on the desk, as every refusal must be.
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    /// One bad file in a run of three thousand must not end the run.
    @Test("a file that cannot be read is named, and the batch carries on")
    func oneBadFile() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let good = try Self.stl(bench.dir, "good.stl")
        let empty = bench.dir.appending(path: "empty.stl")
        try Data().write(to: empty)
        let alsoGood = try Self.stl(bench.dir, "also.stl", size: 20)

        let report = try await Self.run([good, empty, alsoGood], bench)
        #expect(report.moved == 2, "the batch stopped at the bad file")
        #expect(report.failures.count == 1)
        #expect(report.failures[0].hasPrefix("empty.stl:"))
        #expect(report.total == 3)
    }

    @Test("Stop stops between files, not halfway through one")
    func stops() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let files = try (1...4).map { try Self.stl(bench.dir, "m\($0).stl", size: Double($0) * 5) }

        var seen = 0
        let report = await LibraryImport.addMany(
            files, storeURL: bench.store, libraryRoot: bench.library,
            knownHashes: [], nameOfExisting: { _ in nil }, engine: try KhaytEngine(),
            owns: { true }, whoHasIt: { nil },
            shouldStop: { seen >= 2 },
            progress: { _, _, _ in seen += 1 })

        #expect(report.stopped)
        #expect(report.moved == 2, "moved \(report.moved)")
        // The two it never reached are untouched, records and files alike.
        #expect(FileManager.default.fileExists(atPath: files[3].path))
        #expect(try LibraryImportEndToEndTests.printFiles(in: bench).count == 2)
    }

    @Test("progress counts every file, in order, before it is imported")
    func progressReports() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let files = try (1...3).map { try Self.stl(bench.dir, "m\($0).stl", size: Double($0) * 5) }

        var reported: [String] = []
        var totals: Set<Int> = []
        _ = await LibraryImport.addMany(
            files, storeURL: bench.store, libraryRoot: bench.library,
            knownHashes: [], nameOfExisting: { _ in nil }, engine: try KhaytEngine(),
            owns: { true }, whoHasIt: { nil },
            progress: { _, total, file in
                reported.append(file.lastPathComponent); totals.insert(total)
            })
        #expect(reported == ["m1.stl", "m2.stl", "m3.stl"])
        #expect(totals == [3], "the total moved during the run")
    }
}

/// Catching up a library that came in before the app could do everything.
@MainActor
struct CatchUpTests {

    static func file(ext: String, thumb: String?, key: String?) throws -> LibraryFile {
        var o: [String: JSONValue] = [
            "id": .string("PF-1"), "name": .string("m"),
            "sourceFile": .object(["filename": .string("m.\(ext)"), "ext": .string(ext)]),
        ]
        if let thumb { o["thumbFile"] = .string(thumb) }
        if let key { o["geometryKey"] = .string(key) }
        return try JSONDecoder().decode(LibraryFile.self,
                                        from: try JSONEncoder().encode(JSONValue.object(o)))
    }

    /// EITHER is enough. Fifteen of the shop's models were missing both,
    /// because a text STL written on Windows read as no triangles at all — it
    /// drew nothing and measured as nothing, from the same cause.
    @Test("a model missing a picture, a measurement, or both is caught up")
    func eitherIsEnough() throws {
        #expect(ImportCommand.needsCatchingUp(try Self.file(ext: "stl", thumb: nil, key: nil)))
        #expect(ImportCommand.needsCatchingUp(try Self.file(ext: "stl", thumb: nil, key: "12:1:1x1x1")))
        #expect(ImportCommand.needsCatchingUp(try Self.file(ext: "stl", thumb: "thumb.png", key: nil)))
        // An empty string is as missing as an absent one.
        #expect(ImportCommand.needsCatchingUp(try Self.file(ext: "stl", thumb: "", key: "")))
    }

    /// So it is safe to run twice, and the second run does nothing.
    @Test("a model that has both is left alone")
    func idempotent() throws {
        #expect(!ImportCommand.needsCatchingUp(
            try Self.file(ext: "stl", thumb: "thumb.png", key: "12:1:1x1x1")))
    }

    /// Only the formats whose triangles this app can actually read.
    ///
    /// This said "only STLs" until the mesh reader learned OBJ. That was not a
    /// preference — it was the honest limit at the time, and offering to catch
    /// up a format nothing could read would have been a promise this could not
    /// keep. A 3MF is still excluded for the opposite reason: it arrives with a
    /// picture its slicer made and is measured on the way in, so there is
    /// nothing to catch up.
    @Test("only the formats whose triangles can be read are offered")
    func onlyMeshesItCanRead() throws {
        for ext in ["stl", "STL", "obj", "OBJ"] {
            #expect(ImportCommand.needsCatchingUp(try Self.file(ext: ext, thumb: nil, key: nil)),
                    "\(ext) can be read and was not offered")
        }
        for ext in ["3mf", "gcode", "stp", "step"] {
            #expect(!ImportCommand.needsCatchingUp(try Self.file(ext: ext, thumb: nil, key: nil)),
                    "\(ext) was offered and cannot be caught up")
        }
    }
}
