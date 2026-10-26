import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Applying the vault against a real (temporary) book and library folder:
/// the re-measure through the shop's own Measure path, and the banner's two
/// answers to a kept-both copy. An extension of `LibraryEditPerfTests`, which
/// is serialized: installing a book sets a shared static.
extension LibraryEditPerfTests {

    /// One small book with `record` as its only model, its file(s) put in the
    /// model's folder in the book's own library.
    static func withVaultBook(_ record: [String: JSONValue], files: [String: Data],
                              _ body: (Shop, URL) async throws -> Void) async throws {
        var root = PerfBook.synthesize(models: 0)
        root["printFiles"] = .array([.object(record)])
        _ = try PerfBook.install(root)
        let spotlight = UserDefaults.standard.object(forKey: Spotlight.defaultsKey)
        UserDefaults.standard.set(false, forKey: Spotlight.defaultsKey)
        let shop = Shop()
        shop.useEngine(OperatorLockTests.sharedEngine)
        shop.storageScannedBooks.insert(StoreReader.Build.shipped.rawValue)
        do {
            await shop.load(.store(.shipped))
            let roots = try #require(shop.libraryRoots)
            guard case .string(let id)? = record["id"] else { throw VaultStubLess.noId }
            let folder = URL(fileURLWithPath: roots.primary).appending(path: LibraryLocation.itemDirName(id))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, data) in files { try data.write(to: folder.appending(path: name)) }
            try await body(shop, folder)
        } catch {
            Issue.record(error)
        }
        await shop.settleLibraryWrites()
        await shop.load(.sample)
        StoreReader.Build.supportFolderForTests = nil
        UserDefaults.standard.set(spotlight, forKey: Spotlight.defaultsKey)
    }

    enum VaultStubLess: Error { case noId }

    /// A real tetrahedron, 10 mm on a side at the corner.
    static let tetra = Data("""
    solid t
    facet normal 0 0 -1
    outer loop
    vertex 0 0 0
    vertex 0 10 0
    vertex 10 0 0
    endloop
    endfacet
    facet normal 0 -1 0
    outer loop
    vertex 0 0 0
    vertex 10 0 0
    vertex 0 0 10
    endloop
    endfacet
    facet normal -1 0 0
    outer loop
    vertex 0 0 0
    vertex 0 0 10
    vertex 0 10 0
    endloop
    endfacet
    facet normal 1 1 1
    outer loop
    vertex 10 0 0
    vertex 0 10 0
    vertex 0 0 10
    endloop
    endfacet
    endsolid t

    """.utf8)

    static func hash(_ d: Data) -> String { VaultCrypto.hex(VaultCrypto.sha256(d)) }

    @Test("Vault: a version that replaced the copy here is measured again by the Measure path, and the mark goes")
    func vaultRemeasure() async throws {
        let record: [String: JSONValue] = [
            "id": .string("PF-vr"), "name": .string("Tetra"),
            "sourceFile": .object(["filename": .string("m.stl"), "ext": .string("stl"), "size": .number(1)]),
            "contentHash": .string(Self.hash(Self.tetra)), "figuresStaleFor": .string(Self.hash(Self.tetra)),
            "geometryKey": .string("1:1.0:1x1x1"), "geometryReader": .number(1),
            "parsed": .object(["printTimeMins": .number(999), "filamentGrams": .number(500)]),
        ]
        try await Self.withVaultBook(record, files: ["m.stl": Self.tetra]) { shop, _ in
            #expect(shop.files.first?.figuresStale == true)
            let n = await shop.remeasureStaleVaultModels(build: .shipped, engine: shop.engine!, roots: shop.libraryRoots!)
            #expect(n == 1)
            await shop.load(.store(.shipped))
            let file = try #require(shop.files.first)
            #expect(!file.figuresStale)
            #expect(file.geometryKey != nil && file.geometryKey != "1:1.0:1x1x1", "measured from the new bytes")
            #expect(file.parsed?.printTimeMins != 999, "the old file's slicer time is gone")
        }
    }

    @Test("Vault: Use the vault's puts its copy in place, the shop's goes to the Trash, the figures are redone")
    func vaultUseTheVaults() async throws {
        let mine = Data("solid mine\nendsolid mine\n".utf8)
        let record: [String: JSONValue] = [
            "id": .string("PF-vc"), "name": .string("Tetra"), "contentHash": .string(Self.hash(mine)),
            "sourceFile": .object(["filename": .string("m.stl"), "ext": .string("stl"), "size": .number(1)]),
        ]
        try await Self.withVaultBook(record, files: ["m.stl": mine, "m (vault v2).stl": Self.tetra]) { shop, folder in
            let copy = folder.appending(path: "m (vault v2).stl")
            try JSONEncoder().encode(VaultApply.KeptMarker(of: "m.stl", fileId: "f", version: 2))
                .write(to: VaultApply.keptMarkerURL(for: copy))
            let kept = try #require(Shop.vaultKeptCopies(rows: shop.fileRows, roots: shop.libraryRoots!).first)
            shop.vaultKeptCopies = [kept]
            await shop.resolveVaultConflict(kept, keepMine: false)
            #expect(try Data(contentsOf: folder.appending(path: "m.stl")) == Self.tetra)
            #expect(!FileManager.default.fileExists(atPath: copy.path))
            #expect(!FileManager.default.fileExists(atPath: VaultApply.keptMarkerURL(for: copy).path))
            #expect(shop.vaultKeptCopies.isEmpty)
            let file = try #require(shop.files.first)
            #expect(file.contentHash == Self.hash(Self.tetra))
            #expect(!file.figuresStale && file.geometryKey != nil, "measured again at once")
        }
    }

    @Test("Vault: Keep this Mac's sends the vault's copy and its marker to the Trash and leaves the shop's file")
    func vaultKeepMine() async throws {
        let mine = Data("solid mine\nendsolid mine\n".utf8)
        let record: [String: JSONValue] = [
            "id": .string("PF-vk"), "name": .string("Tetra"), "contentHash": .string(Self.hash(mine)),
            "sourceFile": .object(["filename": .string("m.stl"), "ext": .string("stl"), "size": .number(1)]),
        ]
        try await Self.withVaultBook(record, files: ["m.stl": mine, "m (vault v2).stl": Self.tetra]) { shop, folder in
            let copy = folder.appending(path: "m (vault v2).stl")
            try JSONEncoder().encode(VaultApply.KeptMarker(of: "m.stl", fileId: "f", version: 2))
                .write(to: VaultApply.keptMarkerURL(for: copy))
            let kept = try #require(Shop.vaultKeptCopies(rows: shop.fileRows, roots: shop.libraryRoots!).first)
            await shop.resolveVaultConflict(kept, keepMine: true)
            #expect(try Data(contentsOf: folder.appending(path: "m.stl")) == mine)
            #expect(!FileManager.default.fileExists(atPath: copy.path))
            #expect(Shop.vaultKeptCopies(rows: shop.fileRows, roots: shop.libraryRoots!).isEmpty)
            #expect(shop.files.first?.contentHash == Self.hash(mine))
        }
    }
}
