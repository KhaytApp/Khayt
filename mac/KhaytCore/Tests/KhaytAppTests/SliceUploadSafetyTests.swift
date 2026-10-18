import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A customer's 3MF reaches the slicer as shapes only: its own settings,
/// where a `post_process` command lives, are taken out first.
@MainActor
struct SliceUploadSafetyTests {

    static func file(_ members: [ZipWrite.Member]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "slice-safe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "upload.3mf")
        try ZipWrite.archive(members).write(to: url)
        return url
    }

    @Test("settings, G-code and pictures are dropped; the content types, relationships and model stay")
    func strips() throws {
        let url = try Self.file([
            .init("[Content_Types].xml", Data("<Types/>".utf8)),
            .init("_rels/.rels", Data("<Relationships/>".utf8)),
            .init("3D/3dmodel.model", Data("<model/>".utf8)),
            .init("3D/Objects/object_1.model", Data("<model/>".utf8)),
            .init("3D/_rels/3dmodel.model.rels", Data("<Relationships/>".utf8)),
            .init("Metadata/project_settings.config", Data(#"{"post_process":["/bin/sh -c evil"]}"#.utf8)),
            .init("Metadata/Slic3r_PE.config", Data("; post_process = /bin/sh evil".utf8)),
            .init("Metadata/plate_1.gcode", Data("G28".utf8)),
            .init("Metadata/thumbnail.png", Data([0x89, 0x50])),
        ])
        try SlicerRun.keepOnlyTheModel(url)
        let names = Set(try Zip.entries(of: url).map(\.name))
        #expect(names == ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model",
                          "3D/Objects/object_1.model", "3D/_rels/3dmodel.model.rels"])
        let model = try #require(try Zip.entries(of: url).first { $0.name == "3D/3dmodel.model" })
        #expect(try Zip.data(of: model, in: url) == Data("<model/>".utf8))
    }

    @Test("a 3MF with no model part is refused, not sliced")
    func noModel() throws {
        let url = try Self.file([.init("Metadata/project_settings.config", Data("{}".utf8))])
        #expect(throws: SlicerRun.Failure.missingModel) { try SlicerRun.keepOnlyTheModel(url) }
    }

    @Test("the LAN upload path strips a 3MF before it slices")
    func wired() throws {
        let source = try QuoteSheetStatusTests.source("LanServer.swift")
        #expect(source.contains("SlicerRun.keepOnlyTheModel(model)"))
    }
}
