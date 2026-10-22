import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The per-device cloud state index (`LibrarySyncIndex`): built from the
/// sidecars, kept beside the library folder and out of the book, read by the
/// tiles and the Show menu without asking the disk.
@MainActor
struct LibrarySyncIndexTests {

    /// A library folder under a fresh temporary support folder, never the
    /// real one.
    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "khayt-sync-\(UUID().uuidString)/print-files-vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func folder(_ root: URL, _ id: String, _ names: [String]) throws {
        let dir = root.appending(path: LibraryLocation.itemDirName(id))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: dir.appending(path: name)) }
    }

    @Test("what a folder's names say")
    func stateOfNames() {
        #expect(LibrarySyncIndex.state(of: ["a.3mf"]) == .local)
        #expect(LibrarySyncIndex.state(of: ["a.3mf.cloud"]) == .online)
        #expect(LibrarySyncIndex.state(of: ["a.3mf", "a.3mf.cloud"]) == .backedUp, "a crash between sidecar and removal")
        #expect(LibrarySyncIndex.state(of: ["a.3mf.online"]) == .online)
        #expect(LibrarySyncIndex.state(of: ["a.3mf.online.cloud"]) == .online)
        #expect(LibrarySyncIndex.state(of: []) == .local)
    }

    @Test("first launch reads the sidecars, keeps them, and writes the index beside the root")
    func migrates() throws {
        let root = try Self.root()
        try Self.folder(root, "PF-1", ["a.3mf"])
        try Self.folder(root, "PF-2", ["b.stl.cloud"])
        try Self.folder(root, "PF-3", ["c.3mf.online"])
        try Self.folder(root, "PF-4", ["d.3mf", "d.3mf.cloud"])
        let probes = ["PF-1", "PF-2", "PF-3", "PF-4", "PF-5"].map { LibrarySyncIndex.Probe(id: $0, externalPath: nil) }
        #expect(LibrarySyncIndex.open(primary: root.path) == nil, "no index yet")
        let index = LibrarySyncIndex.migrate(primary: root.path, roots: [root.path], models: probes)
        #expect(index.state("PF-1") == .local)
        #expect(index.state("PF-2") == .online)
        #expect(index.state("PF-3") == .online)
        #expect(index.state("PF-4") == .backedUp)
        #expect(index.state("PF-5") == .local, "a model with no folder here")
        #expect(index.migratedAt != nil)
        // Beside the library root, not inside it, and not the book.
        #expect(index.url == root.deletingLastPathComponent().appending(path: "library-sync.json"))
        #expect(FileManager.default.fileExists(atPath: index.url.path))
        // The sidecars are the fallback and stay.
        let side = root.appending(path: LibraryLocation.itemDirName("PF-2")).appending(path: "b.stl.cloud")
        #expect(FileManager.default.fileExists(atPath: side.path))

        let again = try #require(LibrarySyncIndex.open(primary: root.path))
        #expect(again.snapshot == index.snapshot)
        // A library moved elsewhere is not described by the old file.
        #expect(LibrarySyncIndex.open(primary: root.path + "-moved") == nil)
    }

    @Test("changes persist; reconcile reads only new models and drops the gone")
    func changesAndReconcile() throws {
        let root = try Self.root()
        let index = LibrarySyncIndex.migrate(primary: root.path, roots: [root.path],
                                             models: [.init(id: "PF-1", externalPath: nil)])
        index.set("PF-1", .backedUp)
        index.setKeep("PF-1", true)
        let reopened = try #require(LibrarySyncIndex.open(primary: root.path))
        #expect(reopened.state("PF-1") == .backedUp)
        #expect(reopened.isKept("PF-1"))

        try Self.folder(root, "PF-2", ["x.3mf.cloud"])
        // PF-1's folder says nothing now, and must not be re-read over what was recorded.
        let changed = reopened.reconcile(roots: [root.path], models: [.init(id: "PF-2", externalPath: nil)])
        #expect(changed)
        #expect(reopened.state("PF-2") == .online)
        #expect(reopened.state("PF-1") == nil, "a model gone from the book is dropped")
        #expect(!reopened.reconcile(roots: [root.path], models: [.init(id: "PF-2", externalPath: nil)]),
                "nothing new: no work, no write")
    }

    static func shop(with root: URL) async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendLibrary((1...6).map { i in
            .object(["id": .string("PF-\(i)"), "name": .string("Model \(i)")])
        })
        try? folder(root, "PF-1", ["a.3mf.cloud"])
        try? folder(root, "PF-2", ["b.3mf.online"])
        try? folder(root, "PF-3", ["c.3mf", "c.3mf.cloud"])
        shop.syncIndex = LibrarySyncIndex.migrate(primary: root.path, roots: [root.path],
                                                  models: (1...6).map { .init(id: "PF-\($0)", externalPath: nil) })
        shop.libraryHasRemote = true
        shop.syncIndexChanged()
        shop.clearLibraryFilter()
        shop.shelf = .library(nil)
        shop.libraryFlat = true
        return shop
    }

    @Test("the Show menu's pair filters and counts from the index alone")
    func filters() async throws {
        let shop = await Self.shop(with: try Self.root())
        shop.libraryRows = shop.files.map { .object(["id": .string($0.id), "name": .string($0.name)]) }
        shop.libraryStorage = .onlineOnly
        #expect(shop.shownFiles.map(\.id).sorted() == ["PF-1", "PF-2"])
        shop.libraryStorage = .thisMacOnly
        #expect(shop.shownFiles.map(\.id).sorted() == ["PF-4", "PF-5", "PF-6"], "backed up is not this Mac only")
        #expect(shop.libraryFilterOn)
        shop.libraryStorage = nil
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.onlineOnly == 2)
        #expect(shop.libraryFacets.thisMacOnly == 3)
        // A change to the index moves the list without a reload.
        shop.libraryStorage = .onlineOnly
        _ = shop.shownFiles
        shop.recordSync(["PF-4": .online])
        #expect(shop.shownFiles.map(\.id).sorted() == ["PF-1", "PF-2", "PF-4"])
    }

    @Test("a tile's badge is a lookup, and says nothing for a shop with no cloud")
    func badges() async throws {
        let shop = await Self.shop(with: try Self.root())
        let byId = Dictionary(uniqueKeysWithValues: shop.files.map { ($0.id, $0) })
        #expect(shop.storageBadge(for: byId["PF-1"]!) == .online)
        #expect(shop.storageBadge(for: byId["PF-3"]!) == .backedUp)
        #expect(shop.storageBadge(for: byId["PF-6"]!) == .local)
        shop.libraryHasRemote = false
        #expect(shop.storageBadge(for: byId["PF-6"]!) == nil)
        #expect(shop.storageBadge(for: byId["PF-1"]!) == .online)
        // The index answers "online" before any folder is listed.
        #expect(shop.isInCloudOnly(byId["PF-1"]!))
        // Every state has its words, in both languages, for VoiceOver.
        for state in [LibrarySyncIndex.State.local, .backedUp, .online] {
            let entry = try #require(Words.own[Shop.storageWordKey(state)])
            #expect(entry["en"]?.isEmpty == false && entry["ar"]?.isEmpty == false)
        }
    }

    @Test("Keep on this Mac takes a model out of Free up space")
    func keptIsNotTiered() async throws {
        let shop = await Self.shop(with: try Self.root())
        shop.syncIndex?.setKeep("PF-6", true)
        let files = ["PF-5", "PF-6"].map {
            KhaytEngine.TierFile(filename: "m.3mf", fullPath: "/x/\($0)/m.3mf", size: 10, mtimeMs: 0,
                                 id: LibraryLocation.itemDirName($0), lastUsedMs: nil)
        }
        #expect(shop.notKept(files).map(\.fullPath) == ["/x/PF-5/m.3mf"])
    }

    @Test("the tile, the inspector and the Show menu are wired to it, and every move records it")
    func wired() throws {
        func src(_ name: String) throws -> String {
            try String(contentsOf: GroupFromRightClickTests.source(name), encoding: .utf8)
        }
        #expect(try src("LibraryGrid.swift").contains("storage: shop.storageBadge(for: file)"))
        #expect(try src("LibraryInspector.swift").contains("StorageSection(shop: shop, file: file)"))
        #expect(try src("LibraryFilterBar.swift").contains("\"online-only\", \"this-mac-only\"]"))
        let cloud = try src("CloudLibrary.swift")
        #expect(cloud.contains("recordSync([id: .online])"), "Free up space does not record the move")
        #expect(cloud.contains("recordSync([file.id: .backedUp])"), "Bring Back does not record it")
        #expect(cloud.contains("recordSync([id: .backedUp])"), "a marker brought down is not recorded")
        #expect(cloud.contains("notKept(plan.candidates)"))
        #expect(try src("LibraryDelete.swift").contains("recordSync([id: .online])"))
        #expect(try src("Shop.swift").contains("openSyncIndex()"))
    }
}

extension CloudLibraryTests {

    @Test("one model's Free up space: the local copy goes only after the copy online is proved")
    func moveOutOne() async throws {
        let bucket = FakeBucket()
        CloudLibrary.fetch = bucket.fetch
        CloudLibrary.download = S3.download(over: bucket.fetch)
        let engine = try KhaytEngine()
        let shop = Shop()
        let c = CloudLibrary.Config(remote: .bucket(config), prefix: "", backsUp: false,
                                    provider: config.endpoint, tier: .null, tierEnabled: false)

        let url = try model()
        let size = try await shop.moveOut(url, key: "print-files/PF-1/Benchy.3mf", config: c, engine: engine)
        #expect(size == 4096)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(bucket.object("/lib/print-files/PF-1/Benchy.3mf")?.count == 4096)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(LibrarySyncIndex.state(of: names) == .online, "the sidecar is written, so the fallback agrees")

        bucket.lie = .wrongEtag
        let kept = try model()
        await #expect(throws: (any Error).self) {
            _ = try await shop.moveOut(kept, key: "print-files/PF-2/Benchy.3mf", config: c, engine: engine)
        }
        #expect(FileManager.default.fileExists(atPath: kept.path), "a copy not proved must not cost the local one")
    }
}

/// In the serialised suite that owns the test support folder.
extension LibraryEditPerfTests {

    @Test("a real book opens its index on load, beside its own library folder")
    func indexOpensOnLoad() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 12)) { shop, url in
            await shop.settleSyncIndex()
            let index = try #require(shop.syncIndex)
            let primary = try #require(shop.libraryRoots?.primary)
            #expect(index.root == primary)
            #expect(index.url.deletingLastPathComponent().path
                    == URL(fileURLWithPath: primary).deletingLastPathComponent().path)
            #expect(index.url != url, "the index is not the book")
            #expect(index.count == shop.files.count)
            // Not in the book.
            let book = try String(contentsOf: url, encoding: .utf8)
            #expect(!book.contains("library-sync"))
        }
    }
}
