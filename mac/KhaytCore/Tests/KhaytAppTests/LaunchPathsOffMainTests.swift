import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Where each model's file is, found off the main actor at launch.
///
/// Two launch passes — the slicer figures and the designer/licence read —
/// asked `modelFile(for:)` for every model in the library on the main actor:
/// a stat per library root per model, ten thousand models in one shop, and on
/// a NAS or a Google Drive folder each stat is a round trip (Oct 2026: 30 ms
/// on a local disk for 10,000, measured). The answer must not change by
/// moving, so the off-main resolver is checked against every case the
/// on-main one handles.
@MainActor
struct LaunchPathsOffMainTests {

    static func file(_ id: String, filename: String? = nil, external: String? = nil) -> LibraryFile {
        var record: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
        if let filename { record["sourceFile"] = .object(["filename": .string(filename)]) }
        if let external { record["externalPath"] = .string(external) }
        return try! JSONDecoder().decode(
            LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(record)))
    }

    @Test("the off-main resolver finds what the on-main one found")
    func sameAnswers() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "khayt-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appending(path: "one"), second = base.appending(path: "two")
        let fm = FileManager.default
        func folder(_ root: URL, _ id: String, _ names: [String]) throws {
            let dir = root.appending(path: LibraryLocation.itemDirName(id))
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in names { try Data("x".utf8).write(to: dir.appending(path: n)) }
        }
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try folder(first, "named", ["named.3mf", "guide.pdf"])
        try folder(second, "insecond", ["insecond.stl"])
        try folder(first, "sole", ["something-else.gcode", "thumb.jpg"])
        try folder(first, "two", ["a.stl", "b.stl"])
        try folder(first, "pdfonly", ["guide.pdf"])
        let outside = base.appending(path: "linked.3mf")
        try Data("x".utf8).write(to: outside)
        let roots = [first.path, second.path]

        let cases: [(LibraryFile, URL?)] = [
            (Self.file("named", filename: "named.3mf"),
             first.appending(path: LibraryLocation.itemDirName("named")).appending(path: "named.3mf")),
            (Self.file("insecond", filename: "insecond.stl"),
             second.appending(path: LibraryLocation.itemDirName("insecond")).appending(path: "insecond.stl")),
            (Self.file("sole", filename: "renamed.gcode"),
             first.appending(path: LibraryLocation.itemDirName("sole")).appending(path: "something-else.gcode")),
            (Self.file("two", filename: "c.stl"), nil),
            (Self.file("pdfonly"), nil),
            (Self.file("missing", filename: "m.stl"), nil),
            (Self.file("linked", external: outside.path), URL(fileURLWithPath: outside.path)),
            (Self.file("unplugged", external: "/Volumes/Gone/x.3mf"), nil),
        ]
        for (file, want) in cases {
            let got = Shop.modelFile(for: file, roots: roots)
            #expect(got?.standardizedFileURL.path == want?.standardizedFileURL.path,
                    Comment(rawValue: file.id))
        }
        #expect(Shop.modelFile(for: Self.file("named", filename: "named.3mf"), roots: nil) == nil)
    }

    @Test("neither launch pass resolves model files on the main actor")
    func launchPassesResolveOffMain() throws {
        let here = URL(fileURLWithPath: #filePath)
        let src = try String(contentsOf: here.deletingLastPathComponent()
            .appending(path: "../../Sources/KhaytApp/Shop+Library.swift").standardized, encoding: .utf8)
        for name in ["func readSlicerFiguresIfDue()", "func readProvenanceFromFiles()"] {
            let start = try #require(src.range(of: name), Comment(rawValue: name))
            let body = src[start.upperBound...].prefix(3_000)
            let off = try #require(body.range(of: "PinWork.run"), Comment(rawValue: name))
            #expect(!body[..<off.lowerBound].contains("modelFile("), Comment(rawValue: name))
            #expect(body[off.lowerBound...].contains("Shop.modelFile(for:"), Comment(rawValue: name))
        }
    }
}
