import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// "Smart enough to know when to create a folder and when not, as there would
/// be multiple projects, some with folders and some not, and sub folders with
/// multiple projects in the same situation" — the shop, Sep 2026.
struct SmartFoldersTests {

    static let root = URL(fileURLWithPath: "/tmp/Downloads")
    static func f(_ path: String) -> URL { root.appending(path: path) }

    @Test("a folder with one model is not a folder; a folder with several is a project, at every depth")
    func placements() {
        let files = [
            "loose.stl",                                     // at the top, no folder
            "Dragon/dragon_v2_final.stl",                    // one model in its folder
            "Saudi Kings/King Abdulaziz/crown.stl",          // each king in his own folder…
            "Saudi Kings/King Saud/crown.stl",
            "Saudi Kings/King Faisal/STL/presupported/crown.stl",   // …format folders ignored
            "MyProject/base.stl",                            // a project with its own parts
            "MyProject/pose 1/arm.stl",                      // and sub-projects of several models
            "MyProject/pose 1/leg.stl",
            "MyProject/pose 2/Grey/body.stl",                // a sub-folder of one
        ].map(Self.f)
        let p = ImportGrouping.placements(for: files, chosen: Self.root)
        func at(_ s: String) -> ImportGrouping.Placement? { p[Self.f(s)] }

        #expect(at("loose.stl") == .init(group: nil, title: nil))
        #expect(at("Dragon/dragon_v2_final.stl") == .init(group: nil, title: "Dragon"),
                "a folder of one model is the model's name, not a group of one")
        #expect(at("Saudi Kings/King Abdulaziz/crown.stl") == .init(group: "Saudi Kings", title: "King Abdulaziz"),
                "seven kings are one project, each titled by his folder, not seven 'crown's")
        #expect(at("Saudi Kings/King Faisal/STL/presupported/crown.stl") == .init(group: "Saudi Kings", title: "King Faisal"))
        #expect(at("MyProject/base.stl") == .init(group: "MyProject", title: nil))
        #expect(at("MyProject/pose 1/arm.stl") == .init(group: "MyProject/pose 1", title: nil),
                "a sub-folder with several models keeps its place under the project")
        #expect(at("MyProject/pose 2/Grey/body.stl") == .init(group: "MyProject", title: "pose 2 – Grey"),
                "folders of one collapse into the nearest project and name the model")
    }

    @Test("the chosen folder itself is a project only when it holds several models")
    func chosenFolder() {
        let one = ImportGrouping.placements(for: [URL(fileURLWithPath: "/tmp/Vase/vase.stl")],
                                            chosen: URL(fileURLWithPath: "/tmp/Vase"))
        #expect(one[URL(fileURLWithPath: "/tmp/Vase/vase.stl")] == .init(group: nil, title: "Vase"))
        let two = ImportGrouping.placements(for: [URL(fileURLWithPath: "/tmp/Set/a.stl"), URL(fileURLWithPath: "/tmp/Set/b.stl")],
                                            chosen: URL(fileURLWithPath: "/tmp/Set"))
        #expect(two[URL(fileURLWithPath: "/tmp/Set/a.stl")] == .init(group: "Set", title: nil))
    }

    @Test("a zip of one model is that model, named after the zip; a zip of several is a project")
    func archives() {
        let one = ImportGrouping.incoming(archive: [URL(fileURLWithPath: "/tmp/x/dragon.stl")],
                                          group: "Dragon", documents: [])
        #expect(one.count == 1 && one[0].group == nil && one[0].title == "Dragon")
        let two = ImportGrouping.incoming(archive: [URL(fileURLWithPath: "/tmp/x/a.stl"), URL(fileURLWithPath: "/tmp/x/b.stl")],
                                          group: "Chess set", documents: [])
        #expect(two.allSatisfy { $0.group == "Chess set" && $0.title == nil })
    }

    @Test("the title reaches the record; the file's own name stays its original name")
    @MainActor
    func titleIsWritten() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let folder = bench.dir.appending(path: "King Abdulaziz")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appending(path: "crown.stl")
        try MeshTests.binarySTL(MeshTests.boxFacets(10, 10, 10)).write(to: source)
        let files = ImportGrouping.incoming([source], chosen: folder)
        #expect(files.first?.title == "King Abdulaziz")
        let report = await LibraryImport.addMany(files, storeURL: bench.store, libraryRoot: bench.library,
                                                   knownHashes: [], nameOfExisting: { _ in nil },
                                                   engine: try KhaytEngine(),
                                                   owns: { true }, whoHasIt: { nil })
        #expect(report.moved == 1)
        let row = try #require(try LibraryImportEndToEndTests.printFiles(in: bench).first)
        guard case .object(let o) = row else { Issue.record("not an object"); return }
        #expect(o["name"] == .string("King Abdulaziz"))
        #expect(o["originalName"] == .string("crown.stl"))
    }

    @Test("the importer's own walk places a real folder tree by the rule")
    @MainActor
    func walk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "smart-\(UUID().uuidString)/Downloads")
        for path in ["loose.stl", "Dragon/dragon.stl", "Kings/Faisal/crown.stl", "Kings/Khalid/crown.stl",
                     "Chess/king.stl", "Chess/queen.stl", "Chess/.hidden.stl"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("solid x\nendsolid x\n".utf8).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let found = Shop.modelsUnder([root], skippingAll: [])
        func at(_ p: String) -> LibraryImport.Incoming? {
            found.first { $0.url.standardizedFileURL.path == root.appending(path: p).standardizedFileURL.path }
        }
        #expect(found.count == 6, "a hidden file is not a model")
        #expect(at("Dragon/dragon.stl")?.group != at("Kings/Faisal/crown.stl")?.group)
        #expect(at("Dragon/dragon.stl")?.title == "Dragon")
        #expect(at("Kings/Faisal/crown.stl")?.title == "Faisal")
        #expect(at("Kings/Khalid/crown.stl")?.group == at("Kings/Faisal/crown.stl")?.group)
        #expect(at("Chess/king.stl")?.title == nil)
        #expect((at("Chess/king.stl")?.group ?? "").hasSuffix("Chess"))
    }
}
