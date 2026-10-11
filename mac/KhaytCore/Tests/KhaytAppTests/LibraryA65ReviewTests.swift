import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// The alpha.65 pre-release review of the storage pass and the delete choices
/// (Oct 2026): each test is one finding, failing before its fix.
@MainActor
@Suite(.serialized)
struct LibraryA65ReviewTests {

    typealias Bench = LibraryImportEndToEndTests.Bench
    typealias T = LibraryStorageTests

    let config = S3Config(endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "lib",
                          accessKeyId: "k", secretAccessKey: "s")

    func stl(_ size: Double) -> Data { MeshTests.binarySTL(MeshTests.boxFacets(size, size, size)) }

    // MARK: - Free Up Space and backups never touch the shop's own folders

    @Test("tiering and whole-library backups list only record folders, never a shop folder adopted in place")
    func tierSkipsShopFolders() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try T.model(root.appending(path: "PF-a/a.stl"))
        try T.model(root.appending(path: "Dragon/dragon.stl"))     // the shop's, adopted in place
        try T.model(root.appending(path: "PF-gone/old.stl"))      // a record deleted elsewhere
        let listed = CloudLibrary.libraryFiles(root: root.path)
        #expect(Set(listed.compactMap(\.id)) == ["PF-a", "Dragon", "PF-gone"], "the raw listing walks every folder")
        let rows: [JSONValue] = [
            .object(["id": .string("PF-a")]),
            .object(["id": .string("PF-x"), "externalPath": .string(root.appending(path: "Dragon/dragon.stl").path)]),
        ]
        let mine = CloudLibrary.ownFoldersOnly(listed, printFiles: rows, orders: [])
        #expect(mine.map(\.id) == ["PF-a"], "\(mine.map(\.id))")
        // And the two paths that upload or free use it.
        let source = try LockRound3Tests.source("CloudLibrary.swift")
        #expect(source.components(separatedBy: "CloudLibrary.ownFoldersOnly(").count - 1 == 2)
    }

    // MARK: - The storage walk never adopts Khayt's own copies

    @Test("a record folder or the mirror nested in a shop folder is not walked — no versions adopted as models")
    func nestedKhaytFoldersFenced() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try T.model(root.appending(path: "Projects/keep.stl"), size: 10)
        try T.model(root.appending(path: "Projects/old/PF-abc/v2.stl"), size: 11)   // a record folder copied in
        try T.model(root.appending(path: "Projects/unsorted/x.stl"), size: 12)
        let mirror = root.appending(path: "Backups/mirror")
        try T.model(mirror.appending(path: "PF-q/q.stl"), size: 13)
        try T.model(mirror.appending(path: "Loose/q2.stl"), size: 14)
        let found = Shop.untrackedInStorage(root, rows: [], ignored: [], excluding: [mirror.path]).files
        let names = Set(found.map(\.url.lastPathComponent))
        #expect(names == ["keep.stl"], "\(names)")
    }

    // MARK: - Odd bucket keys

    @Test("a bucket key with an empty segment is not adopted: the request would address a different object")
    func emptySegmentKeysSkipped() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        try T.write([], to: bench)
        let bucket = FakeBucket()
        bucket.seed("/lib/Dragons//dragon.stl", stl(12))
        bucket.seed("/lib/Dragons/dragon.stl", stl(13))
        let report = try await Shop.adoptFromBucket(config, provider: config.endpoint, root: bench.library,
                                                    storeURL: bench.store, fetch: bucket.fetch,
                                                    owns: { true }, whoHasIt: { nil }, progress: { _, _, _ in })
        #expect(report.added == 1, "\(report)")
        let book = try #require(Shop.readBook(bench.store))
        let ledger = Shop.StorageLedger.read(Shop.settings(book))
        #expect(ledger.adopted == ["bucket:lib/Dragons/dragon.stl"], "\(ledger.adopted)")
    }

    // MARK: - Delete Completely

    func plan(online: [String: [String]], buckets: [String: String] = [:]) -> LibraryDeletePlan {
        var p = LibraryDeletePlan()
        p.ids = online.keys.sorted()
        p.cloudOnly = p.ids
        p.online = online
        p.markerBuckets = buckets
        return p
    }

    @Test("a hand-placed object is deleted only from the bucket its marker names")
    func markerBucketMustMatch() async throws {
        let bucket = FakeBucket()
        bucket.seed("/lib/Mine/d.stl", Data([1, 2, 3]))
        let p = plan(online: ["PF-d": ["bucket:Mine/d.stl"]], buckets: ["bucket:Mine/d.stl": "old-bucket"])
        let r = await Shop.deleteOnlineCopies(p, ids: p.ids, remote: .bucket(config), bucket: .bucket(config),
                                              remoteTag: "bucket:", fetch: bucket.fetch)
        #expect(r.failed.keys.sorted() == ["PF-d"] && r.done.isEmpty)
        #expect(bucket.object("/lib/Mine/d.stl") != nil, "an object in the bucket set up NOW is not the marker's")
        let same = plan(online: ["PF-d": ["bucket:Mine/d.stl"]], buckets: ["bucket:Mine/d.stl": "lib"])
        let ok = await Shop.deleteOnlineCopies(same, ids: same.ids, remote: .bucket(config), bucket: .bucket(config),
                                               remoteTag: "bucket:", fetch: bucket.fetch)
        #expect(ok.done == ["PF-d"] && bucket.object("/lib/Mine/d.stl") == nil)
    }

    @Test("an object another model still names is kept; a key with an empty segment is refused")
    func sharedAndOddKeys() async throws {
        let bucket = FakeBucket()
        bucket.seed("/lib/Mine/d.stl", Data([1, 2, 3]))
        bucket.seed("/lib/a/b.stl", Data([4]))
        let p = plan(online: ["PF-1": ["bucket:Mine/d.stl"], "PF-2": ["bucket:a//b.stl"]])
        let r = await Shop.deleteOnlineCopies(p, ids: p.ids, remote: .bucket(config), bucket: .bucket(config),
                                              remoteTag: "bucket:", keptFor: ["Mine/d.stl"], fetch: bucket.fetch)
        #expect(r.done == ["PF-1"], "its record goes; the object is the other model's too")
        #expect(bucket.object("/lib/Mine/d.stl") != nil)
        #expect(r.failed.keys.sorted() == ["PF-2"])
        #expect(bucket.object("/lib/a/b.stl") != nil, "`a//b.stl` must never become a DELETE of `a/b.stl`")
    }

    @Test("the keys other models name are read from every root, leaving out the ones being deleted")
    func keysNamedElsewhere() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for (dir, key) in [("PF-1", "Mine/d.stl"), ("PF-2", "Mine/d.stl"), ("PF-3", "Mine/e.stl")] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            let m = Shop.OnlineMarker(key: key, size: 1, etag: "", bucket: "lib", provider: "", at: "")
            try JSONEncoder().encode(m).write(to: root.appending(path: "\(dir)/x.stl" + Shop.onlineExt))
        }
        #expect(Shop.keysNamedOnDisk(roots: [root.path], except: ["PF-1"]) == ["Mine/d.stl", "Mine/e.stl"])
        #expect(Shop.keysNamedOnDisk(roots: [root.path], except: ["PF-1", "PF-2"]) == ["Mine/e.stl"])
    }

    @Test("Delete Completely is given the keys other models still name")
    func completeIsWired() throws {
        let source = try LockRound3Tests.source("LibraryDelete.swift")
        #expect(source.contains("keptFor: keptFor"))
        let window = try LockRound3Tests.source("ShopWindow.swift")
        // The second lock, asked in the button before its task.
        #expect(window.components(separatedBy: "guard shop.stillTheQuestion(plan) else { return }").count - 1 == 3)
    }

    // MARK: - The question's words

    @Test("one model is spoken of as one, in both languages — never \"1 have\" or a numeral before a word")
    func countedLines() async throws {
        let engine = try KhaytEngine()
        let en = Words(); await en.load("en", engine: engine)
        let ar = Words(); await ar.load("ar", engine: engine)
        var single = LibraryDeletePlan()
        single.ids = ["PF-a"]; single.keptOnline = ["PF-a"]; single.online = ["PF-a": ["bucket:k"]]
        let one = Shop.deletePlanLines(single, words: en)
        #expect(one.first?.hasPrefix("This model has an online copy") == true, "\(one)")
        #expect(one.contains("Delete Completely also deletes its online copy."), "\(one)")
        #expect(Shop.deletePlanLines(single, words: ar).first?.hasPrefix("لهذا النموذج") == true)

        var many = LibraryDeletePlan()
        many.ids = ["a", "b", "c", "d"]
        many.keptOnline = ["a"]; many.onlyHere = ["b", "c"]; many.cloudOnly = ["d"]; many.handPlaced = ["d"]
        many.online = ["a": ["bucket:x"], "d": ["bucket:y"]]
        let lines = Shop.deletePlanLines(many, words: en)
        #expect(lines.contains { $0.hasPrefix("One has an online copy") }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("2 of these 4 are only on this Mac") }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("One is online only") }, "\(lines)")
        #expect(lines.contains("That includes one file you put in the bucket yourself."), "\(lines)")
        for line in lines + Shop.deletePlanLines(many, words: ar) {
            #expect(!line.contains("{"), "an unfilled placeholder: \(line)")
            #expect(!line.hasPrefix("1 ") && !line.contains(" 1 "), "a bare numeral one: \(line)")
        }
        let arLines = Shop.deletePlanLines(many, words: ar)
        #expect(arLines.contains { $0.hasPrefix("اثنان من هذه الـ4") }, "the dual: \(arLines)")
        #expect(Shop.say(en, "mac.delete_only_here_too", 1) == "Remove, and Delete the One Only on This Mac")
        #expect(Shop.say(en, "mac.delete_only_here_too", 3) == "Remove, and Delete the 3 Only on This Mac")

        var all = LibraryDeletePlan()
        all.ids = ["a", "b"]; all.onlyHere = ["a", "b"]
        #expect(Shop.deletePlanLines(all, words: en) == ["None of these has an online copy — deleting them removes them for good."])
    }

    // MARK: - The ledger

    @Test("a pass's ledger keeps what another writer added while it ran")
    func ledgerMergesInside() {
        var read = Shop.StorageLedger()
        read.adopted = ["/a"]
        var next = read
        next.adopted = ["/a", "bucket:lib/new.stl"]
        var onDisk = read
        onDisk.adopted = ["/a", "/added-meanwhile"]
        onDisk.seenDuplicates = ["/d|1|2"]
        let out = Shop.ledgerMerged(next, over: read, into: onDisk)
        #expect(Set(out.adopted) == ["/a", "bucket:lib/new.stl", "/added-meanwhile"])
        #expect(out.seenDuplicates == ["/d|1|2"])
    }

    // MARK: - Photos are decoded off the main actor

    @Test("a photo decodes from a nonisolated context — the backfill and imports run it on a dispatch queue")
    func photosOffMain() async throws {
        let dir = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pic = dir.appending(path: "p.jpg")
        try T.picture(pic)
        let uri = await PinWork.run { LibraryImport.firstPhoto([pic]) }
        #expect(uri?.hasPrefix("data:image/jpeg;base64,") == true)
        let storage = try LockRound3Tests.source("LibraryStorage.swift")
        let start = try #require(storage.range(of: "static func backfillPhotos("))
        let body = String(storage[start.lowerBound...].prefix(4000))
        let pin = try #require(body.range(of: "await PinWork.run {"))
        let decode = try #require(body.range(of: "LibraryImport.firstPhoto("))
        #expect(pin.lowerBound < decode.lowerBound, "the decode is inside the dispatch-queue closure")
    }
    // MARK: - A stray `<model>.online.cloud` (the desktop's tier sweep)

    @Test("a stray <model>.online.cloud is never a model, never tiered, and only ever a sidecar of the MARKER")
    func strayOnlineCloud() async throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: "PF-d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let markerURL = dir.appending(path: "d.stl" + Shop.onlineExt)
        let marker = Shop.OnlineMarker(key: "Mine/d.stl", size: 5, etag: "x", bucket: "lib", provider: "", at: "")
        let markerBytes = try JSONEncoder().encode(marker)
        try markerBytes.write(to: markerURL)
        // What the desktop's sweep leaves when its size floor is 0.
        let engine = try KhaytEngine()
        let strayKey = "print-files/PF-d/d.stl.online"
        let side = try await engine.sidecarText(size: markerBytes.count, sha256: S3.sha256Hex(markerBytes),
                                                key: strayKey, provider: config.endpoint, at: "2026-10-11T00:00:00Z")
        let stray = CloudLibrary.sidecar(for: markerURL)
        #expect(stray.lastPathComponent == "d.stl.online.cloud")
        try Data(side.utf8).write(to: stray)

        // Never the model.
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(Shop.soleModel(in: contents) == nil)
        // Never offered for tiering again, even with no size floor.
        let listed = CloudLibrary.libraryFiles(root: root.path)
        #expect(listed.map(\.filename) == ["d.stl.online.cloud"], "\(listed.map(\.filename))")
        let plan = try await engine.tierPlan(listed, policy: .object(["enabled": .bool(true), "keepDays": .number(0),
                                                                      "minBytes": .number(0)]),
                                             now: Date().addingTimeInterval(400 * 86_400))
        #expect(plan.candidates.isEmpty, "\(plan.candidates.map(\.filename))")
        // The delete question still sees an online-only, hand-placed model.
        let rec = try JSONDecoder().decode(LibraryFile.self, from: JSONSerialization.data(withJSONObject:
            ["id": "PF-d", "name": "D", "sourceFile": ["filename": "d.stl"]]))
        let bucket = FakeBucket()
        let p = await Shop.planDelete([rec], roots: [root.path], remote: .bucket(config), prefix: "",
                                      remoteTag: "bucket:", engine: engine, fetch: bucket.fetch,
                                      modelFile: { _ in nil })
        #expect(p.cloudOnly == ["PF-d"] && p.handPlaced == ["PF-d"] && p.onlyHere.isEmpty)
        #expect(p.online["PF-d"]?.contains("bucket:Mine/d.stl") == true)

        // Bring Back with the marker present leaves it alone…
        bucket.seed("/lib/" + strayKey, markerBytes)
        let real = CloudLibrary.fetch
        CloudLibrary.fetch = bucket.fetch
        defer { CloudLibrary.fetch = real }
        try await CloudLibrary.bringBack(markerURL, remotes: { _ in [.bucket(config)] }, engine: engine)
        #expect(try Data(contentsOf: markerURL) == markerBytes)
        // …and with the marker gone, it puts the MARKER back, verified — never a model.
        try FileManager.default.removeItem(at: markerURL)
        try await CloudLibrary.bringBack(markerURL, remotes: { _ in [.bucket(config)] }, engine: engine)
        #expect(try Data(contentsOf: markerURL) == markerBytes)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "d.stl").path))
    }
}
