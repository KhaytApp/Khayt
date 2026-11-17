import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac's own readers of a stranger's zip and 3MF (beta.40 full review,
/// security area): a stored member is read at the size its bytes are, never
/// the size it declares; a model part's unterminated tag is carried at most
/// 64 KB; an archive that unpacks to thousands of files is stopped; and a
/// webhook's refusal says nothing about the app's insides.
@MainActor
struct ReaderHardeningTests {

    static func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "khayt-harden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("a stored member whose two sizes disagree is refused before a byte is read")
    func storedSizesMustAgree() throws {
        let d = try Self.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let zip = try ZipTests.makeZip(in: d, named: "s.zip", files: [("a.model", Data(repeating: 0x61, count: 50_000))],
                                       stored: true)
        let real = try #require(try Zip.entries(of: zip).first { $0.name == "a.model" })
        #expect(real.method == 0 && real.size == real.compressedSize)
        #expect(try Zip.data(of: real, in: zip).count == 50_000, "an honest stored member reads")
        // The same bytes, the directory claiming one.
        let lying = Zip.Entry(name: real.name, compressedSize: real.compressedSize, size: 1, method: 0, offset: real.offset)
        #expect(throws: Zip.Failure.self) { _ = try Zip.data(of: lying, in: zip, limit: .max) }
        #expect(throws: Zip.Failure.self) { try Zip.stream(lying, in: zip) { _ in true } }
        // The stream's limit holds for a stored member too.
        var seen = 0
        #expect(throws: Zip.Failure.self) {
            try Zip.stream(real, in: zip, totalLimit: 10_000) { seen += $0.count; return true }
        }
        #expect(seen == 0, "refused before reading")
    }

    @Test("only an unterminated tag is carried, and one past 64 KB makes the part corrupt")
    func tagCarry() throws {
        let b = Array("<a x=\"1\">text<b y".utf8)
        #expect(Mesh.unterminated(b, from: 0) == 13, "the `<b` after `<a x=\"1\">text`")
        #expect(Mesh.unterminated(Array("<a>text only".utf8), from: 0) == nil, "text between tags is not carried")
        #expect(Mesh.unterminated(Array("no tags at all".utf8), from: 0) == nil)

        let d = try Self.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let head = "<?xml version=\"1.0\"?><model unit=\"millimeter\"><resources><object id=\"1\" type=\"model\"><mesh><vertices>"
        // A real part, with a long text node, still measures.
        let good = head + "<vertex x=\"0\" y=\"0\" z=\"0\"/><vertex x=\"10\" y=\"0\" z=\"0\"/><vertex x=\"0\" y=\"10\" z=\"0\"/>"
            + "</vertices><triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh></object></resources>"
            + "<build><item objectid=\"1\"/></build><metadata name=\"Description\">" + String(repeating: "d", count: 3_000_000)
            + "</metadata></model>"
        let okZip = try ZipTests.makeZip(in: d, named: "ok.3mf", files: [("3D/3dmodel.model", Data(good.utf8))])
        let measured = try Mesh.measure3MF(okZip)
        #expect(measured?.triangleCount == 1, "a long text node is not a long tag")
        // `<` and 3 MB with no `>`: refused, quickly, not carried and rescanned.
        let bad = head + "<" + String(repeating: "a", count: 3_000_000)
        let badZip = try ZipTests.makeZip(in: d, named: "bad.3mf", files: [("3D/3dmodel.model", Data(bad.utf8))])
        let start = Date()
        #expect(throws: (any Error).self) { _ = try Mesh.measure3MF(badZip) }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("an unpacked archive is stopped past the file count, as past the byte budget")
    func fileCount() throws {
        let d = try Self.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        for i in 0..<(ArchiveImport.mostFiles) { FileManager.default.createFile(atPath: d.appending(path: "f\(i)").path, contents: nil) }
        #expect(!ArchiveImport.tooMuch(under: d), "exactly the cap is allowed")
        FileManager.default.createFile(atPath: d.appending(path: "one-more").path, contents: nil)
        #expect(ArchiveImport.tooMuch(under: d))
        #expect(ArchiveImport.mostFiles == 2048, "lib/upload-scan.js MAX_ENTRIES")
    }

    @Test("a webhook that fails says so without the error's own words")
    func webhookSaysNothingInside() {
        let src = MenuCoverageTests.source("LanServer.swift")
        #expect(!src.contains("Self.errorBody(String(describing: error))"))
        #expect(src.components(separatedBy: "Self.errorBody(\"The event could not be recorded\")").count - 1 == 2)
    }
}
