import Foundation
import Testing
@testable import KhaytCore

/// A zip64 container, which is not about size.
///
/// The reader refused the zip64 markers on the note that no 3MF it reads is
/// near 4 GB. True, and beside the point: some writers emit zip64 for every
/// archive. Thirteen of this shop's eighty-five 3MFs were such files, the
/// smallest 34 KB, and every one was refused — no thumbnail, no measurement,
/// no key. `lib/zip-read.js` refused them the same way, so the two apps agreed
/// on those files perfectly and were both wrong.
@Suite struct Zip64Tests {

    /// A real zip64 archive from the system's own `zip`, not bytes written by
    /// hand: `-fz` forces the zip64 records on, and the test refuses to run
    /// against a fixture that did not get them.
    static func zip64Fixture(in dir: URL) throws -> URL {
        let staging = dir.appending(path: "s/3D")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("<model unit=\"millimeter\"/>".utf8).write(to: staging.appending(path: "3dmodel.model"))
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: dir.appending(path: "s/thumb.png"))
        let archive = dir.appending(path: "small.3mf")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-fz", "-q", "-r", archive.path, "."]
        zip.currentDirectoryURL = dir.appending(path: "s")
        zip.standardOutput = Pipe(); zip.standardError = Pipe()
        try zip.run(); zip.waitUntilExit()
        return archive
    }

    @Test("a zip64 archive lists and reads, however small it is")
    func smallZip64() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-zip64-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Self.zip64Fixture(in: dir)

        let bytes = try Data(contentsOf: archive)
        #expect(bytes.range(of: Data([0x50, 0x4b, 0x06, 0x06])) != nil,
                "the fixture is not zip64 — `zip -fz` did not do what this test needs")

        // `zip -r` writes an entry for the folder itself; a reader that lists
        // it is right to, and it is not a member anything opens.
        let entries = try Zip.entries(of: archive).filter { !$0.name.hasSuffix("/") }
        #expect(Set(entries.map(\.name)) == ["3D/3dmodel.model", "thumb.png"],
                "listed \(entries.map(\.name))")
        let model = try #require(entries.first { $0.name == "3D/3dmodel.model" })
        #expect(model.size == "<model unit=\"millimeter\"/>".utf8.count,
                "the real size came from the zip64 extra, not the marker")
        let text = String(decoding: try Zip.data(of: model, in: archive), as: UTF8.self)
        #expect(text == "<model unit=\"millimeter\"/>")
    }

    @Test("a zip64 archive whose locator points outside the file is refused, not guessed at")
    func brokenLocator() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-zip64-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Self.zip64Fixture(in: dir)
        var bytes = try Data(contentsOf: archive)
        let loc = try #require(bytes.range(of: Data([0x50, 0x4b, 0x06, 0x07])))
        // The record offset, eight bytes in: send it past the end.
        var past = UInt64(bytes.count + 4096).littleEndian
        withUnsafeBytes(of: &past) { bytes.replaceSubrange(loc.lowerBound + 8 ..< loc.lowerBound + 16, with: $0) }
        let broken = dir.appending(path: "broken.3mf")
        try bytes.write(to: broken)
        #expect(throws: (any Error).self) { try Zip.entries(of: broken) }
    }

    /// The shop's own files, when this Mac has them.
    @Test("every zip64 3MF in the vault lists its members")
    func theVaultsOwn() throws {
        let vault = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/khayt/print-files-vault")
        guard let walk = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil) else { return }
        var seen = 0
        for case let url as URL in walk where url.pathExtension.lowercased() == "3mf" {
            guard let bytes = try? Data(contentsOf: url),
                  bytes.range(of: Data([0x50, 0x4b, 0x06, 0x06])) != nil else { continue }
            let entries = try Zip.entries(of: url)
            #expect(entries.contains { $0.name.lowercased().hasSuffix(".model") },
                    "\(url.lastPathComponent) listed no model part")
            seen += 1
        }
        if seen > 0 { print("Zip64Tests: \(seen) zip64 3MFs in the vault listed") }
    }
}
