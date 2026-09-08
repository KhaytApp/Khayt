import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// Writing a zip.
///
/// A writer is only correct if something ELSE can read what it produced, so
/// most of this file checks the archive against readers that know nothing about
/// it: the system `unzip`, and `lib/zip-read.js` — the Node implementation the
/// other app uses. A round trip through our own reader would pass just as
/// happily on two matching misunderstandings of the format.
@MainActor
struct ZipWriteTests {

    static func temp(_ name: String = "zip") -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-zip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(name).zip")
    }

    /// XML, which is most of a 3MF and compresses about ten to one.
    static func xml(_ times: Int = 400) -> Data {
        Data(String(repeating: "<vertex x=\"1.5\" y=\"2.25\" z=\"3.125\"/>", count: times).utf8)
    }

    /// Runs a command and returns its output, or nil when it is not installed.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (code: Int32, out: String)? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // ── the format itself ─────────────────────────────────────────────────

    /// The vector every CRC-32 implementation is checked against.
    @Test("CRC-32 agrees with the rest of the world")
    func crc() {
        #expect(ZipWrite.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipWrite.crc32(Data()) == 0)
        #expect(ZipWrite.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test("what goes in comes back out")
    func roundTrip() throws {
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let mesh = Self.xml()
        let png = Data([0x89, 0x50, 0x4E, 0x47] + (0..<500).map { UInt8($0 % 251) })

        try ZipWrite.archive([
            .init("3D/3dmodel.model", mesh),
            .init("Metadata/thumbnail.png", png),
            .init("[Content_Types].xml", Data("<Types/>".utf8)),
        ]).write(to: url)

        let entries = try Zip.entries(of: url)
        #expect(entries.map(\.name) == ["3D/3dmodel.model", "Metadata/thumbnail.png",
                                        "[Content_Types].xml"])
        #expect(try Zip.data(of: entries[0], in: url) == mesh)
        #expect(try Zip.data(of: entries[1], in: url) == png)
        #expect(try Zip.data(of: entries[2], in: url) == Data("<Types/>".utf8))
    }

    /// XML deflates; random bytes do not, and a member that would GROW is kept
    /// as it is. A repack that made the file bigger is one a shop notices.
    @Test("each member is stored or deflated by whichever is smaller")
    func perMemberChoice() {
        let compressible = ZipWrite.squeeze(.init("m.model", Self.xml()))
        #expect(compressible.method == 8)
        #expect(compressible.body.count < Self.xml().count / 4)

        var noise = Data(count: 4096)
        for i in noise.indices { noise[i] = UInt8.random(in: 0...255) }
        let incompressible = ZipWrite.squeeze(.init("thumb.png", noise))
        #expect(incompressible.method == 0, "deflating noise made the member bigger")
        #expect(incompressible.body == noise)

        // And a caller that already knows is believed without trying.
        #expect(ZipWrite.squeeze(.init("m.model", Self.xml(), store: true)).method == 0)
        #expect(ZipWrite.squeeze(.init("empty", Data())).method == 0)
    }

    @Test("an empty member and an empty archive are both legal")
    func empties() throws {
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ZipWrite.archive([.init("nothing.txt", Data())]).write(to: url)
        let entries = try Zip.entries(of: url)
        #expect(entries.count == 1)
        #expect(try Zip.data(of: entries[0], in: url) == Data())
        #expect(try ZipWrite.archive([]).count == 22, "an empty archive is just its EOCD")
    }

    /// The same members twice must give the same bytes, or a content hash of a
    /// repacked file means nothing. That is why the stamp is fixed rather than
    /// the time of day.
    @Test("repacking the same members twice gives the same file")
    func deterministic() throws {
        let members: [ZipWrite.Member] = [.init("a.model", Self.xml()), .init("b.txt", Data("x".utf8))]
        #expect(try ZipWrite.archive(members) == (try ZipWrite.archive(members)))
    }

    @Test("a name in Arabic survives the trip")
    func utf8Names() throws {
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ZipWrite.archive([.init("نماذج/قاعدة.model", Self.xml(20))]).write(to: url)
        #expect(try Zip.entries(of: url).first?.name == "نماذج/قاعدة.model")
    }

    @Test("a member with no name is refused rather than written")
    func refusals() {
        #expect(throws: ZipWrite.Failure.noName) { try ZipWrite.archive([.init("", Data("x".utf8))]) }
    }

    // ── read by something that is not us ──────────────────────────────────

    /// The system's own `unzip`, which has never heard of this code.
    @Test("the system unzip finds the archive sound")
    func systemUnzip() throws {
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ZipWrite.archive([
            .init("3D/3dmodel.model", Self.xml()),
            .init("Metadata/project_settings.config", Data("{\"a\":1}".utf8)),
        ]).write(to: url)

        guard let test = Self.run("/usr/bin/unzip", ["-t", url.path]) else { return }
        #expect(test.code == 0, "unzip refused it:\n\(test.out)")
        #expect(test.out.contains("No errors detected"), "\(test.out)")
    }

    /// AND THE OTHER WAY ROUND. A 3MF repacked in Electron has to open here,
    /// or the two apps can each write a file the other cannot read — which is
    /// worse than neither being able to write one.
    @Test("a zip written by lib/zip-write.js opens here")
    func readsTheNodeWriter() throws {
        let url = Self.temp("from-node")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = """
            const w = require('\(repo.path)/lib/zip-write.js');
            const fs = require('fs');
            const xml = '<vertex x="1.5"/>'.repeat(400);
            fs.writeFileSync('\(url.path)', w.writeZip([
              { name: '3D/3dmodel.model', data: Buffer.from(xml) },
              { name: 'thumb.png', data: Buffer.from([0x89,0x50,0x4e,0x47]) },
            ]));
            """
        guard let node = Self.run("/usr/bin/env", ["node", "-e", script]) else { return }
        #expect(node.code == 0, "the Node writer failed:\n\(node.out)")

        let entries = try Zip.entries(of: url)
        #expect(entries.map(\.name) == ["3D/3dmodel.model", "thumb.png"])
        let mesh = try Zip.data(of: entries[0], in: url)
        #expect(String(decoding: mesh, as: UTF8.self)
                == String(repeating: "<vertex x=\"1.5\"/>", count: 400))
        #expect(try Zip.data(of: entries[1], in: url) == Data([0x89, 0x50, 0x4e, 0x47]))
    }

    /// `lib/zip-read.js` — the OTHER implementation, the one Electron uses. If
    /// the Mac repacks a 3MF the app next door has to be able to open it.
    @Test("Khayt's own Node reader gets the same bytes back")
    func nodeReader() throws {
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let mesh = Self.xml()
        let config = Data("{\"printer\":\"Snapmaker U1\"}".utf8)
        try ZipWrite.archive([
            .init("3D/3dmodel.model", mesh),
            .init("Metadata/project_settings.config", config),
        ]).write(to: url)

        // Four levels up from Tests/KhaytAppTests: the repo root.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = """
            const zip = require('\(repo.path)/lib/zip-read.js');
            const fs = require('fs');
            const z = zip.openZip(fs.readFileSync('\(url.path)'));
            const out = {};
            for (const e of z.entries) out[e.name] = z.file(e.name).toString('utf8');
            process.stdout.write(JSON.stringify(out));
            """
        guard let node = Self.run("/usr/bin/env", ["node", "-e", script]) else { return }
        #expect(node.code == 0, "the Node reader failed:\n\(node.out)")
        guard let json = try? JSONSerialization.jsonObject(with: Data(node.out.utf8))
                as? [String: String] else {
            Issue.record("could not read what node printed: \(node.out)"); return
        }
        #expect(json["3D/3dmodel.model"] == String(decoding: mesh, as: UTF8.self))
        #expect(json["Metadata/project_settings.config"] == String(decoding: config, as: UTF8.self))
    }
}
