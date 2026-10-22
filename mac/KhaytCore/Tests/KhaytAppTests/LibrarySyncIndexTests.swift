import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The per-device cloud state index (`LibrarySyncIndex`): built from the
/// sidecars, kept per file in the app's own support folder and out of the
/// book, read by the tiles and the Show menu without asking the disk — and
/// overruled by the disk wherever a file is looked at.
@MainActor
struct LibrarySyncIndexTests {

    /// A library folder and a support folder under a fresh temporary folder,
    /// never the real ones.
    static func folders() throws -> (root: URL, support: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "khayt-sync-\(UUID().uuidString)")
        let root = base.appending(path: "Library/print-files-vault")
        let support = base.appending(path: "Support/khayt")
        for dir in [root, support] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return (root, support)
    }

    @discardableResult
    static func folder(_ root: URL, _ id: String, _ names: [String]) throws -> URL {
        let dir = root.appending(path: LibraryLocation.itemDirName(id))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: dir.appending(path: name)) }
        return dir
    }

    static let remote = "s3:https://acc.r2.example/lib/shop"

    @Test("a folder's names, file by file")
    func filesOfNames() {
        func f(_ names: [String], _ at: String?) -> [String: LibrarySyncIndex.FileEntry] {
            LibrarySyncIndex.files(of: names, at: at)
        }
        #expect(f(["a.3mf"], nil).mapValues(\.state) == ["a.3mf": .local])
        #expect(f(["a.3mf.cloud"], nil).mapValues(\.state) == ["a.3mf": .online])
        #expect(f(["a.3mf", "a.3mf.cloud"], nil).mapValues(\.state) == ["a.3mf": .local],
                "a crash between sidecar and removal proves no remote")
        #expect(f(["a.3mf.online"], nil).mapValues(\.state) == ["a.3mf": .online])
        #expect(f(["a.3mf.online.cloud"], nil).mapValues(\.state) == ["a.3mf": .online])
        #expect(f(["thumb.jpg", "guide.pdf"], nil).isEmpty, "pictures and papers are not the model")
    }

    @Test("a pack with one file moved out is not online only; backed up needs this remote")
    func modelState() {
        typealias E = LibrarySyncIndex.FileEntry
        func state(_ files: [E], _ remote: String?) -> LibrarySyncIndex.State {
            LibrarySyncIndex.modelState(files, remote: remote)
        }
        let proved = E(state: .backedUp, remote: Self.remote)
        #expect(state([E(state: .online), E(state: .local)], Self.remote) == .local)
        #expect(state([E(state: .online), E(state: .online)], Self.remote) == .online)
        #expect(state([proved, E(state: .online)], Self.remote) == .backedUp)
        #expect(state([proved], "gdrive:Other") == .local, "proved on another remote")
        #expect(state([proved], nil) == .local, "no remote at all")
        #expect(state([E(state: .online)], nil) == .online, "online only is still not here")
    }

    @Test("the index lives in the support folder, one per library, and the old file beside the root is taken in")
    func location() throws {
        let (root, support) = try Self.folders()
        let url = LibrarySyncIndex.location(primary: root.path, folder: support)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == support.standardizedFileURL.path)
        #expect(url.lastPathComponent.hasPrefix("library-sync-") && url.lastPathComponent.hasSuffix(".json"))
        #expect(url != LibrarySyncIndex.location(primary: root.path + "2", folder: support))

        // What the first build wrote beside the library folder.
        let legacy = LibrarySyncIndex.legacyLocation(primary: root.path)
        let old = #"{"v":1,"root":"\#(root.path)","models":{"PF-1":{"state":"local","keep":true},"PF-2":{"state":"online"}}}"#
        try Data(old.utf8).write(to: legacy)
        // Beside a library folder that is not this Mac's own support folder
        // — a NAS, a cloud drive: removed, but its keeps are not taken.
        #expect(LibrarySyncIndex.takeLegacy(primary: root.path, folder: support, ids: ["PF-1"]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "left where another Mac may read it")
        // One that names another library is not ours to delete.
        let other = #"{"v":1,"root":"/Volumes/NAS/elsewhere","models":{"PF-1":{"state":"local","keep":true}}}"#
        try Data(other.utf8).write(to: legacy)
        #expect(LibrarySyncIndex.takeLegacy(primary: root.path, folder: support, ids: ["PF-1"]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        try Data("not json".utf8).write(to: legacy)
        #expect(LibrarySyncIndex.takeLegacy(primary: root.path, folder: support, ids: ["PF-1"]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: legacy.path), "a file it cannot read is left alone")
        // The built-in vault: the legacy file sat in this Mac's own support
        // folder. Its keeps are taken — for models in this book only.
        try Data(old.utf8).write(to: legacy)
        let keep = LibrarySyncIndex.takeLegacy(primary: root.path, folder: legacy.deletingLastPathComponent(),
                                               ids: ["PF-1", "PF-2"])
        #expect(keep == ["PF-1"])
        try Data(old.utf8).write(to: legacy)
        #expect(LibrarySyncIndex.takeLegacy(primary: root.path, folder: legacy.deletingLastPathComponent(),
                                            ids: ["PF-2"]).isEmpty, "a keep for a model not in this book")

        try Self.folder(root, "PF-1", ["a.3mf"])
        try Self.folder(root, "PF-2", ["b.stl.cloud", "c.stl"])
        let index = LibrarySyncIndex.migrate(primary: root.path, folder: support, roots: [root.path],
                                             models: [.init(id: "PF-1", externalPath: nil), .init(id: "PF-2", externalPath: nil)],
                                             keep: keep)
        #expect(index.url == url && FileManager.default.fileExists(atPath: url.path))
        #expect(index.isKept("PF-1"))
        #expect(index.state("PF-2", remote: Self.remote) == .local, "one file of two moved out")
        #expect(index.entry("PF-2")?.files["b.stl"]?.state == LibrarySyncIndex.State.online)
        let side = root.appending(path: LibraryLocation.itemDirName("PF-2")).appending(path: "b.stl.cloud")
        #expect(FileManager.default.fileExists(atPath: side.path), "the sidecars stay")
        #expect(LibrarySyncIndex.open(primary: root.path, folder: support)?.snapshot == index.snapshot)
        #expect(LibrarySyncIndex.open(primary: root.path + "-moved", folder: support) == nil)
    }

    @Test("a backed-up file edited since reads as on this Mac only after the next load")
    func staleBackup() throws {
        let (root, support) = try Self.folders()
        let dir = try Self.folder(root, "PF-1", ["a.3mf"])
        let probe = LibrarySyncIndex.Probe(id: "PF-1", externalPath: nil)
        let index = LibrarySyncIndex.migrate(primary: root.path, folder: support, roots: [root.path], models: [probe])
        let file = dir.appending(path: "a.3mf")
        index.record(["PF-1": ["a.3mf": LibrarySyncIndex.backedUp(file, remote: Self.remote)]])
        #expect(index.state("PF-1", remote: Self.remote) == .backedUp)
        #expect(!index.reconcile(roots: [root.path], models: [probe]), "unchanged: no work, no write")
        try Data("changed bytes".utf8).write(to: file)
        #expect(index.reconcile(roots: [root.path], models: [probe]))
        #expect(index.state("PF-1", remote: Self.remote) == .local)
    }

    @Test("reconcile reads only new models, drops the gone, and keeps a keep")
    func reconcile() throws {
        let (root, support) = try Self.folders()
        let index = LibrarySyncIndex.migrate(primary: root.path, folder: support, roots: [root.path],
                                             models: [.init(id: "PF-1", externalPath: nil)])
        index.setKeep("PF-1", true)
        try Self.folder(root, "PF-2", ["x.3mf.cloud"])
        #expect(index.reconcile(roots: [root.path], models: [.init(id: "PF-2", externalPath: nil)]))
        #expect(index.state("PF-2", remote: nil) == .online)
        #expect(index.entry("PF-1") == nil)
    }

    @Test("saves from many threads: the file on disk is the last state, never an older snapshot")
    func savesAreSerialised() async throws {
        let (root, support) = try Self.folders()
        let index = LibrarySyncIndex.migrate(primary: root.path, folder: support, roots: [root.path], models: [])
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask {
                    index.record(["PF-\(i)": ["m.3mf": .init(state: .online)]])
                }
            }
        }
        let back = try #require(LibrarySyncIndex.open(primary: root.path, folder: support))
        #expect(back.count == 64)
        #expect(back.snapshot == index.snapshot)
    }

    static func shop(_ root: URL, _ support: URL) async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendLibrary((1...6).map { i in
            .object(["id": .string("PF-\(i)"), "name": .string("Model \(i)")])
        })
        try? folder(root, "PF-1", ["a.3mf.cloud"])
        try? folder(root, "PF-2", ["b.3mf.online"])
        let three = try? folder(root, "PF-3", ["c.3mf"])
        for i in 4...6 { try? folder(root, "PF-\(i)", ["m\(i).3mf"]) }
        let index = LibrarySyncIndex.migrate(primary: root.path, folder: support, roots: [root.path],
                                             models: (1...6).map { .init(id: "PF-\($0)", externalPath: nil) })
        if let three {
            index.record(["PF-3": ["c.3mf": LibrarySyncIndex.backedUp(three.appending(path: "c.3mf"), remote: remote)]])
        }
        shop.syncIndex = index
        shop.libraryRemoteId = remote
        shop.libraryHasRemote = true
        shop.syncIndexChanged()
        shop.clearLibraryFilter()
        shop.shelf = .library(nil)
        shop.libraryFlat = true
        return shop
    }

    @Test("the Show menu's pair filters and counts from the index alone, with one search per recount")
    func filters() async throws {
        let (root, support) = try Self.folders()
        let shop = await Self.shop(root, support)
        shop.libraryRows = shop.files.map { .object(["id": .string($0.id), "name": .string($0.name)]) }
        shop.libraryStorage = .onlineOnly
        #expect(shop.shownFiles.map(\.id).sorted() == ["PF-1", "PF-2"])
        shop.libraryStorage = .thisMacOnly
        #expect(shop.shownFiles.map(\.id).sorted() == ["PF-4", "PF-5", "PF-6"], "backed up is not this Mac only")
        // The same backup, read against another remote, is on this Mac only.
        shop.libraryRemoteId = "gdrive:Other"
        shop.syncIndexChanged()
        #expect(shop.shownFiles.map(\.id).sorted() == ["PF-3", "PF-4", "PF-5", "PF-6"])
        shop.libraryRemoteId = Self.remote
        shop.libraryStorage = nil
        shop.search = "model"
        await shop.settleLibraryFacets()
        let before = shop.libraryMemo.work.facetSearches
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        #expect(shop.libraryMemo.work.facetSearches == before + 1, "the search ran once per pool again")
        #expect(shop.libraryFacets.onlineOnly == 2)
        #expect(shop.libraryFacets.thisMacOnly == 3)
        shop.search = ""
        // A pass's changes land at once and move the list without a reload.
        shop.libraryStorage = .onlineOnly
        _ = shop.shownFiles
        shop.recordSync(["PF-4": ["m4.3mf": .init(state: .online)], "PF-5": ["m5.3mf": .init(state: .online)]])
        #expect(shop.shownFiles.map(\.id).sorted() == ["PF-1", "PF-2", "PF-4", "PF-5"])
    }

    @Test("the remote is read again whenever the settings change")
    func remoteFollowsSettings() async {
        let shop = Shop()
        await shop.load(.sample)
        shop.settingsValue = .object([:])
        #expect(!shop.libraryHasRemote && shop.libraryRemoteId == nil)
        shop.settingsValue = .object(["printLibrary": .object(["s3": .object([
            "enabled": .bool(true), "endpoint": .string("https://ACC.r2.example/"), "bucket": .string("lib"),
            "prefix": .string("shop/"), "accessKeyId": .string("k"), "secretAccessKey": .string("s"),
        ])])])
        #expect(shop.libraryHasRemote)
        #expect(shop.libraryRemoteId == "s3:https://acc.r2.example/lib/shop")
        #expect(shop.libraryRemoteId == CloudLibrary.remoteIdentity(
            of: .bucket(S3Config(endpoint: "https://acc.r2.example", bucket: "lib", region: "auto",
                                 accessKeyId: "k", secretAccessKey: "s", prefix: "shop")),
            settings: shop.settingsDict), "a file brought back from the bucket in use is stamped the same")
        // Drive: the account (its sign-in) is part of it, not only the folder.
        let one = DriveClient.Config(clientId: "c", clientSecret: "s", refreshToken: "account-1", folderName: "F")
        let two = DriveClient.Config(clientId: "c", clientSecret: "s", refreshToken: "account-2", folderName: "F")
        #expect(CloudLibrary.driveIdentity(one, folder: "F") != CloudLibrary.driveIdentity(two, folder: "F"))
        #expect(CloudLibrary.driveIdentity(one, folder: "F") == CloudLibrary.driveIdentity(one, folder: "F"))
    }

    @Test("a tile's badge is a lookup, and says nothing for a shop with no cloud")
    func badges() async throws {
        let (root, support) = try Self.folders()
        let shop = await Self.shop(root, support)
        let byId = Dictionary(uniqueKeysWithValues: shop.files.map { ($0.id, $0) })
        #expect(shop.storageBadge(for: byId["PF-1"]!) == .online)
        #expect(shop.storageBadge(for: byId["PF-3"]!) == .backedUp)
        #expect(shop.storageBadge(for: byId["PF-6"]!) == .local)
        shop.libraryHasRemote = false
        #expect(shop.storageBadge(for: byId["PF-6"]!) == nil)
        for state in [LibrarySyncIndex.State.local, .backedUp, .online] {
            let entry = try #require(Words.own[Shop.storageWordKey(state)])
            #expect(entry["en"]?.isEmpty == false && entry["ar"]?.isEmpty == false)
        }
        #expect(Words.own["mac.storage_state_online"]?["en"] == "Online only", "one term everywhere")
        #expect(Words.own["mac.storage_free_one_help"]?["ar"]?.contains("«أعده من السحابة»") == true)
    }

    @Test("Keep on this Mac takes a model out of Free up space, and the delete question names it")
    func kept() async throws {
        let (root, support) = try Self.folders()
        let shop = await Self.shop(root, support)
        shop.syncIndex?.setKeep("PF-6", true)
        let files = ["PF-5", "PF-6"].map {
            KhaytEngine.TierFile(filename: "m.3mf", fullPath: "/x/\($0)/m.3mf", size: 10, mtimeMs: 0,
                                 id: LibraryLocation.itemDirName($0), lastUsedMs: nil)
        }
        #expect(shop.notKept(files).map(\.fullPath) == ["/x/PF-5/m.3mf"])
        var plan = LibraryDeletePlan()
        plan.keptOnline = ["PF-5"]
        #expect(shop.deleteKeptLine(plan) == nil)
        plan.keptOnline = ["PF-5", "PF-6"]
        #expect(shop.deleteKeptLine(plan) == shop.words.callIt("mac.delete_kept_single"))
    }

    @Test("one model's files: the record's own folder in the primary root, never a symlink or elsewhere")
    func freeUpGuards() throws {
        let (root, _) = try Self.folders()
        let dir = try Self.folder(root, "PF-1", ["a.3mf"])
        #expect(CloudLibrary.files(in: dir, root: root.path, includingMarkers: false).map(\.filename) == ["a.3mf"])
        // A folder that is a link to somewhere else on this Mac.
        let elsewhere = try Self.folders().root
        try Self.folder(elsewhere, "PF-2", ["b.3mf"])
        let link = root.appending(path: LibraryLocation.itemDirName("PF-2"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL:
            elsewhere.appending(path: LibraryLocation.itemDirName("PF-2")))
        #expect(CloudLibrary.files(in: link, root: root.path, includingMarkers: false).isEmpty)
        // A folder in another root (an old library folder) is not the primary's.
        #expect(CloudLibrary.files(in: elsewhere.appending(path: LibraryLocation.itemDirName("PF-2")),
                                   root: root.path, includingMarkers: false).isEmpty)
        // A file inside that is a symlink.
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "c.3mf"),
                                                   withDestinationURL: elsewhere.appending(path: "x"))
        #expect(CloudLibrary.files(in: dir, root: root.path, includingMarkers: false).map(\.filename) == ["a.3mf"])
    }

    @Test("a known folder that gained a file is read again on the next load")
    func reconcileReReadsChangedFolder() throws {
        let (root, support) = try Self.folders()
        let dir = try Self.folder(root, "PF-1", ["a.3mf"])
        let probe = LibrarySyncIndex.Probe(id: "PF-1", externalPath: nil)
        let index = LibrarySyncIndex.migrate(primary: root.path, folder: support, roots: [root.path], models: [probe])
        #expect(!index.reconcile(roots: [root.path], models: [probe]))
        // A folder's mtime has a resolution; make sure it moves.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: dir.path)
        #expect(index.reconcile(roots: [root.path], models: [probe]), "an mtime change is noted")
        try Data("x".utf8).write(to: dir.appending(path: "b.3mf.cloud"))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        #expect(index.reconcile(roots: [root.path], models: [probe]))
        #expect(index.entry("PF-1")?.files["b.3mf"]?.state == LibrarySyncIndex.State.online)
        #expect(!index.reconcile(roots: [root.path], models: [probe]), "read again only once")
    }

    @Test("tags changed on another device: the counts follow, though the files revision did not move")
    func countsFollowNewRows() async throws {
        let shop = Shop()
        await shop.load(.sample)
        func rows(_ tag: String) -> [JSONValue] {
            (1...4).map { .object(["id": .string("PF-\($0)"), "name": .string("M\($0)"), "tags": .array([.string(tag)])]) }
        }
        shop.pretendLibrary(rows("dragon"))
        shop.libraryRows = rows("dragon")
        shop.clearLibraryFilter()
        shop.shelf = .library(nil)
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.tags.map(\.name) == ["dragon"])
        // The book's rows replaced as a sync would, `files` untouched.
        shop.libraryRows = rows("egg")
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.tags.map(\.name) == ["egg"], "the cached counts of the old rows were shown")
    }

    @Test("wired: tile, inspector, Show menu, every move recorded once per pass, guards on the one-model path")
    func wired() throws {
        func src(_ name: String) throws -> String {
            try String(contentsOf: GroupFromRightClickTests.source(name), encoding: .utf8)
        }
        #expect(try src("LibraryGrid.swift").contains("storage: shop.storageBadge(for: file)"))
        let inspector = try src("LibraryInspector.swift")
        #expect(inspector.contains("StorageSection(shop: shop, file: file)"))
        #expect(inspector.contains("shop.freeUpSpace(model: file, anyway: true)"), "an open job is not asked about")
        #expect(try src("LibraryFilterBar.swift").contains("\"online-only\", \"this-mac-only\"]"))
        let cloud = try src("CloudLibrary.swift")
        #expect(cloud.contains("notKept(plan.candidates)"))
        #expect(cloud.contains("defer { recordSync(sync) }"), "a bulk pass records model by model")
        #expect(cloud.contains("CloudLibrary.remoteIdentity(of: from, settings: settings)"),
                "Bring Back does not stamp the remote the bytes came from")
        #expect(!cloud.contains("recordSync([id: .online])"))
        let sync = try src("Shop+LibrarySync.swift")
        #expect(sync.contains("guard !cloudLibraryBusy else"))
        #expect(sync.contains("pendingFreeUp = file"))
        #expect(sync.contains("CloudLibrary.files(in: folder, root: primary"))
        let delete = try src("LibraryDelete.swift")
        #expect(delete.contains("syncIndex?.setKeep(Set(keptAmong(plan.keptOnline)), false)"))
        #expect(try src("ShopWindow.swift").contains("shop.deleteKeptLine(plan)"))
        let shop = try src("Shop.swift")
        #expect(shop.contains("didSet { refreshLibraryRemote() }"))
        let settingsAt = try #require(shop.range(of: "settingsValue = root[\"settings\"] ?? .object([:]) }"))
        let openAt = try #require(shop.range(of: "openSyncIndex()"))
        #expect(settingsAt.lowerBound < openAt.lowerBound, "the index is opened before the settings are read")
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
        #expect(LibrarySyncIndex.files(of: names)["Benchy.3mf"]?.state == .online,
                "the sidecar is written, so the fallback agrees")

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

    @Test("a real book opens its index on load, in its support folder; the disk overrules it")
    func indexOpensOnLoad() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 12)) { shop, url in
            await shop.settleSyncIndex()
            let index = try #require(shop.syncIndex)
            let primary = try #require(shop.libraryRoots?.primary)
            #expect(index.root == primary)
            #expect(index.url.deletingLastPathComponent() == url.deletingLastPathComponent(),
                    "beside the book, in the app's own folder")
            #expect(index.url != url, "the index is not the book")
            #expect(index.count == shop.files.count)
            #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("library-sync"))

            // The index says online; the file is here. The file wins, and the
            // index is put right.
            let file = try #require(shop.files.first { !$0.isLinked })
            let dir = URL(fileURLWithPath: primary).appending(path: LibraryLocation.itemDirName(file.id))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("solid x".utf8).write(to: dir.appending(path: file.sourceFile?.filename ?? "m.3mf"))
            index.record([file.id: [file.sourceFile?.filename ?? "m.3mf": .init(state: .online)]])
            #expect(index.state(file.id, remote: nil) == .online)
            #expect(!shop.isInCloudOnly(file))
            for _ in 0..<50 where index.state(file.id, remote: nil) == .online {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(index.state(file.id, remote: nil) == .local, "the index was not corrected from the disk")
        }
    }

    @Test("a record's own file moved out beside two others: online only, agreed once, and never written again")
    func ownFileMovedOutBesideOthers() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 6)) { shop, _ in
            await shop.settleSyncIndex()
            let index = try #require(shop.syncIndex)
            let file = try #require(shop.files.first { !$0.isLinked })
            let own = try #require(file.sourceFile?.filename)
            let primary = try #require(shop.libraryRoots?.primary)
            let dir = URL(fileURLWithPath: primary).appending(path: LibraryLocation.itemDirName(file.id))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // The layout that looped: no sole model, so the old disk rule said
            // cloud-only while the per-file re-read said local.
            for name in [own + ".cloud", "part-a.stl", "part-b.stl"] {
                try Data("x".utf8).write(to: dir.appending(path: name))
            }
            @MainActor func settle() async throws {
                for _ in 0..<50 where !shop.syncCorrecting.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(shop.isInCloudOnly(file), "the record's own file is not here")
            try await settle()
            #expect(index.entry(file.id)?.files[own]?.state == LibrarySyncIndex.State.online)
            #expect(shop.storageState(for: file) == .local, "the pack's other files are here")
            let revision = shop.librarySyncRevision
            let written = try FileManager.default.attributesOfItem(atPath: index.url.path)[.modificationDate] as? Date
            for _ in 0..<3 {
                #expect(shop.isInCloudOnly(file))
                try await settle()
            }
            #expect(shop.librarySyncRevision == revision, "a reading both agree on redrew the library")
            let after = try FileManager.default.attributesOfItem(atPath: index.url.path)[.modificationDate] as? Date
            #expect(after == written, "a reading both agree on wrote the index")
            #expect(shop.syncCorrecting.isEmpty)
        }
    }

    @Test("restoring an original whose conversion is still there says you will have both")
    func restoreSupersededWarns() async throws {
        var book = PerfBook.synthesize(models: 6)
        guard case .array(var rows)? = book["printFiles"],
              case .object(var original) = rows[0], case .object(let converted) = rows[1],
              case .string(let convertedId)? = converted["id"] else { Issue.record("no rows"); return }
        original["archivedAt"] = .string("2026-10-01T09:00:00.000Z")
        original["supersededBy"] = .string(convertedId)
        rows[0] = .object(original)
        book["printFiles"] = .array(rows)
        try await withPerfBook(book) { shop, _ in
            let aside = try #require(shop.files.first { $0.isArchived })
            shop.importNote = nil
            #expect(shop.unarchive([aside.id]))
            await shop.settleLibraryWrites()
            #expect(shop.importNote == shop.words.callIt("mac.unarchive_both_one"))
        }
    }
}
