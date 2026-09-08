import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// Reading members out of a zip.
///
/// Against archives built here by `/usr/bin/zip`, not against a checked-in
/// fixture: the thing being tested is agreement with what every other tool
/// writes, and a fixture is only ever agreement with whatever wrote it once.
@MainActor
struct ZipTests {

    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a zip with `/usr/bin/zip`, so the bytes are somebody else's idea of
    /// the format rather than this reader's.
    @discardableResult
    static func makeZip(in dir: URL, named: String, files: [(String, Data)],
                        stored: Bool = false) throws -> URL {
        let staging = dir.appending(path: "staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, data) in files {
            let path = staging.appending(path: name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: path)
        }
        let archive = dir.appending(path: named)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r"] + (stored ? ["-0"] : []) + [archive.path, "."]
        process.currentDirectoryURL = staging
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return archive
    }

    // MARK: - The directory

    @Test("every member is listed, with its name, size and method")
    func listsMembers() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Compressible, so `zip` deflates it rather than storing it.
        let xml = Data(String(repeating: "<triangle v1=\"1\" v2=\"2\" v3=\"3\"/>", count: 400).utf8)
        let url = try Self.makeZip(in: dir, named: "a.zip", files: [
            ("Metadata/plate_1.png", Data(repeating: 0xAB, count: 2048)),
            ("3D/3dmodel.model", xml),
        ])

        let entries = try Zip.entries(of: url)
        let names = Set(entries.map(\.name))
        #expect(names.contains("Metadata/plate_1.png"))
        #expect(names.contains("3D/3dmodel.model"))

        let model = try #require(entries.first { $0.name == "3D/3dmodel.model" })
        #expect(model.size == xml.count)
        #expect(model.method == 8, "repetitive XML should have been deflated")
        #expect(model.compressedSize < model.size)
    }

    @Test("a file that is not a zip is refused rather than misread")
    func notAZip() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "not.zip")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        #expect(throws: Zip.Failure.notAZip) { _ = try Zip.entries(of: url) }

        // And something far too short to hold even an end-of-directory record.
        let stub = dir.appending(path: "stub.zip")
        try Data([0x50, 0x4b]).write(to: stub)
        #expect(throws: Zip.Failure.notAZip) { _ = try Zip.entries(of: stub) }
    }

    // MARK: - The bytes

    @Test("a stored member comes back exactly as it went in")
    func storedRoundTrip() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A PNG in a 3MF is stored — it is already compressed — so this is the
        // path the preview actually takes.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data((0..<5000).map { UInt8($0 % 251) }))
        let url = try Self.makeZip(in: dir, named: "s.zip",
                                   files: [("Metadata/plate_1.png", png)], stored: true)

        let entry = try #require(try Zip.entries(of: url).first { $0.name.hasSuffix("plate_1.png") })
        #expect(entry.method == 0)
        #expect(try Zip.data(of: entry, in: url) == png)
    }

    @Test("a deflated member is inflated to exactly what it was")
    func deflatedRoundTrip() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = Data(String(repeating: "\"filament_colour\": [\"#FF0000\",\"#00FF00\"]\n",
                                 count: 300).utf8)
        let url = try Self.makeZip(in: dir, named: "d.zip",
                                   files: [("Metadata/project_settings.config", config)])

        let entry = try #require(try Zip.entries(of: url).first { $0.name.hasSuffix(".config") })
        #expect(entry.method == 8)
        #expect(try Zip.data(of: entry, in: url) == config)
    }

    @Test("an empty member is an empty answer, not a crash")
    func emptyMember() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.makeZip(in: dir, named: "e.zip", files: [("empty.txt", Data())])
        let entry = try #require(try Zip.entries(of: url).first { $0.name.hasSuffix("empty.txt") })
        #expect(try Zip.data(of: entry, in: url).isEmpty)
    }

    // MARK: - The cap

    /// THE ONE THAT MATTERS.
    ///
    /// This shop's `KING-Saud-ART-200mm-U1.3mf` is 46 MB on disk and its
    /// `3D/Objects/object_1.model` member is 436 MB uncompressed. A reader that
    /// inflates whatever it is pointed at turns a 46 MB file into 436 MB of
    /// memory, and a hostile one into as much as it likes.
    ///
    /// The cap is checked against the size the DIRECTORY claims, before any
    /// byte is read — so a member that says it is enormous costs a comparison.
    @Test("a member past the cap is refused before it is read")
    func refusesTheBomb() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two megabytes of zeros compresses to almost nothing — the shape of a
        // decompression bomb, in miniature.
        let big = Data(count: 2 * 1024 * 1024)
        let url = try Self.makeZip(in: dir, named: "b.zip", files: [("big.bin", big)])
        let entry = try #require(try Zip.entries(of: url).first { $0.name.hasSuffix("big.bin") })
        #expect(entry.compressedSize < 20_000, "the fixture is not compressible enough to test this")

        #expect(throws: Zip.Failure.self) {
            _ = try Zip.data(of: entry, in: url, limit: 64 * 1024)
        }
        // …and reads fine when it is allowed to.
        #expect(try Zip.data(of: entry, in: url, limit: 4 * 1024 * 1024).count == big.count)
    }

    // MARK: - This shop's own files

    /// Against a real 3MF if one is on this machine, and skipped when not.
    ///
    /// The fixtures above are what `/usr/bin/zip` writes. A slicer's 3MF is what
    /// OrcaSlicer writes, and the two are not the same program — this is the
    /// only place that difference shows up.
    @Test("a slicer's own 3MF reads: a preview, and the configs the colours come from")
    func realArchive() throws {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "kingfix/KING-Saud-ART-200mm-U1.3mf"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return }   // not this machine; the fixtures above still ran

        let entries = try Zip.entries(of: url)
        #expect(entries.count > 3)

        // The preview `thumbnail-extract` picks: the biggest metadata PNG.
        let pngs = entries.filter { $0.name.lowercased().hasPrefix("metadata/")
                                 && $0.name.lowercased().hasSuffix(".png") }
        let biggest = try #require(pngs.max { $0.size < $1.size })
        let png = try Zip.data(of: biggest, in: url)
        #expect(png.count == biggest.size)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                "that is not a PNG")

        // The config `parse3mfColors` reads, deflated and small.
        if let config = entries.first(where: { $0.name == "Metadata/project_settings.config" }) {
            let text = String(decoding: try Zip.data(of: config, in: url), as: UTF8.self)
            #expect(text.contains("filament"), "the settings config should mention filament")
        }

        // And the mesh, which is the whole reason for the cap: present, listed,
        // and never read.
        if let mesh = entries.first(where: { $0.name.hasSuffix(".model")
                                          && $0.name.contains("Objects") }) {
            #expect(mesh.size > 100_000_000, "this shop's meshes are hundreds of megabytes")
            #expect(throws: Zip.Failure.self) { _ = try Zip.data(of: mesh, in: url) }
        }
    }
}

/// Streaming a member out, which is how a mesh is read.
@MainActor
struct ZipStreamTests {

    @Test("streaming a big member gives back exactly what went in")
    func streamRoundTrip() throws {
        let dir = try ZipTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Several megabytes of varied text, so it spans many inflate chunks and
        // compresses like XML rather than like a run of zeros.
        // Built with `map`/`joined` rather than by appending to a String:
        // repeated concatenation of 200,000 pieces spent four minutes in the
        // fixture and seconds in the code under test.
        let original = Data((0..<120_000).map {
            "<vertex x=\"\(Double($0) * 1.5)\" y=\"\(-Double($0))\" z=\"0.\($0 % 997)\"/>"
        }.joined(separator: "\n").utf8)
        let url = try ZipTests.makeZip(in: dir, named: "big.zip", files: [("part.xml", original)])
        let entry = try #require(try Zip.entries(of: url).first { $0.name.hasSuffix("part.xml") })
        #expect(entry.method == 8, "the fixture must be deflated to test inflating")

        var out = Data()
        try Zip.stream(entry, in: url) { chunk in
            out.append(contentsOf: chunk.bindMemory(to: UInt8.self))
            return true
        }
        #expect(out.count == original.count,
                "streamed \(out.count) of \(original.count) bytes")
        #expect(out == original)
    }

    @Test("a stored member streams too")
    func streamStored() throws {
        let dir = try ZipTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let url = try ZipTests.makeZip(in: dir, named: "s.zip",
                                       files: [("blob.bin", original)], stored: true)
        let entry = try #require(try Zip.entries(of: url).first { $0.name.hasSuffix("blob.bin") })
        var out = Data()
        try Zip.stream(entry, in: url) { chunk in
            out.append(contentsOf: chunk.bindMemory(to: UInt8.self)); return true
        }
        #expect(out == original)
    }
}
