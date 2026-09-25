import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// Folders indexed where they are: the files are the shop's and stay put.
@MainActor
struct LinkedFolderTests {
    @Test("a linked model is indexed in place: the file stays, the record points at it, the vault holds no copy")
    func inPlace() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let nas = bench.dir.appending(path: "NAS/Dragons")
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        let model = nas.appending(path: "dragon.stl")
        let bytes = MeshTests.binarySTL(MeshTests.boxFacets(10, 10, 10))
        try bytes.write(to: model)

        let report = await LibraryImport.addMany(
            [LibraryImport.Incoming(url: model, group: nil)],
            storeURL: bench.store, libraryRoot: bench.library, knownHashes: [], nameOfExisting: { _ in nil },
            engine: try KhaytEngine(), keepOriginal: true, inPlace: true,
            owns: { true }, whoHasIt: { nil })
        #expect(report.moved == 1)
        #expect(try Data(contentsOf: model) == bytes, "the shop's file is exactly where it was")

        let row = try #require(try LibraryImportEndToEndTests.printFiles(in: bench).first)
        guard case .object(let o) = row, case .string(let id)? = o["id"] else { Issue.record("shape"); return }
        #expect(o["externalPath"] == .string(model.standardizedFileURL.path))
        #expect(o["geometryKey"] != nil && o["geometryKey"] != .null, "measured where it sits")
        // The vault folder holds at most a picture — nothing a delete could
        // take from the shop.
        let vault = bench.library.appending(path: LibraryLocation.itemDirName(id))
        let inside = (try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? []
        #expect(inside.allSatisfy { ["png", "jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) },
                "a copy of the model went into the vault: \(inside)")
    }

    @Test("a linked model is found at its path, and nowhere else when that path is gone")
    func lookup() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appending(path: "a.stl")
        try Data([1, 2, 3]).write(to: model)
        let json: [String: Any] = ["id": "PF-x", "name": "a", "externalPath": model.path]
        let file = try JSONDecoder().decode(LibraryFile.self, from: JSONSerialization.data(withJSONObject: json))
        let shop = Shop()
        await shop.load(.sample)
        #expect(file.isLinked)
        #expect(shop.modelFile(for: file) == URL(fileURLWithPath: model.path))
        try FileManager.default.removeItem(at: model)
        #expect(shop.modelFile(for: file) == nil, "an unplugged drive is 'not here', never another file")
    }

    /// THE LINE BETWEEN "INDEXED" AND "OURS". A root is somewhere the app may
    /// write, move and — through the Trash — remove; a linked folder is the
    /// shop's and must never become one, in this app or the other. Both
    /// sessions agreed this (Sep 2026): the day `linked` joins the roots is
    /// the day a NAS original falls inside delete's reach.
    @Test("a linked folder is never a library root")
    func neverARoot() {
        let roots = LibraryLocation.resolveRoots(
            settings: .object(["root": .string("/Users/x/lib"), "linked": .array([.string("/Volumes/NAS/models")]),
                               "history": .array([.string("/Users/x/old")])]),
            defaultRoot: "/Users/x/vault")
        #expect(!roots.roots.contains { LibraryMove.under($0, "/Volumes/NAS/models") })
        #expect(LibraryMove.sources(roots: roots.roots, primary: roots.primary, mirror: roots.mirror)
            .allSatisfy { !$0.hasPrefix("/Volumes/NAS") })
    }
}
