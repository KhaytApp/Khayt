import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// The storage pass's second round: a delete in any app stays deleted, a
/// duplicate is not hashed twice, past locations are copied in, the mirror is
/// left alone, the bucket's own files become cloud-only models, and the
/// models already in the library get their photo — once.
@MainActor
@Suite(.serialized)
struct LibraryStorageGapsTests {

    typealias Bench = LibraryImportEndToEndTests.Bench
    typealias T = LibraryStorageTests

    static func ledger(_ bench: Bench) throws -> Shop.StorageLedger {
        let book = try #require(Shop.readBook(bench.store))
        return Shop.StorageLedger.read(Shop.settings(book))
    }

    /// Take a record out of the book the way any app's delete does — the file
    /// it pointed at is left exactly where it was.
    static func deleteRecord(_ bench: Bench, at file: URL) throws {
        var book = try #require(Shop.readBook(bench.store))
        let want = Shop.canonical(file)
        let rows = Shop.rows(book, "printFiles").filter { row in
            guard case .object(let o) = row, case .string(let p)? = o["externalPath"] else { return true }
            return Shop.canonical(URL(fileURLWithPath: p)) != want
        }
        book["printFiles"] = .array(rows)
        try JSONEncoder().encode(book).write(to: bench.store)
    }

    // MARK: - 1. The ledger

    @Test("a model deleted after adoption — by any app, with no notAdopted entry — is not adopted again")
    func deletedAnywhereStaysDeleted() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let file = bench.library.appending(path: "Shelf/vase.stl")
        try T.model(file)
        #expect(try await T.adopt(bench).added == 1)
        #expect(try Self.ledger(bench).adopted.contains(Shop.canonical(file)))
        try Self.deleteRecord(bench, at: file)
        #expect(try Self.ledger(bench).notAdopted.isEmpty, "the other app writes no notAdopted")
        let again = try await T.adopt(bench)
        #expect(again.added == 0 && again.duplicates == 0, "\(again)")
        #expect(FileManager.default.fileExists(atPath: file.path), "the shop's file is untouched")
    }

    @Test("a loose duplicate is recorded once and not hashed again while it is unchanged")
    func duplicateNotRehashed() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        try T.model(bench.library.appending(path: "a.stl"), size: 10)
        let copy = bench.library.appending(path: "Copies/a copy.stl")
        try T.model(copy, size: 10)
        let first = try await T.adopt(bench)
        #expect(first.added == 1 && first.duplicates == 1, "\(first)")
        let led = try Self.ledger(bench)
        #expect(led.seenDuplicates.contains(try #require(Shop.signature(copy))))
        // Not even a candidate on the next walk: nothing to hash.
        let rows = try T.rows(bench)
        #expect(Shop.untrackedInStorage(bench.library, rows: rows, ignored: led.skipped,
                                        seen: led.duplicateSet).files.isEmpty)
        let again = try await T.adopt(bench)
        #expect(again.duplicates == 0 && again.added == 0, "\(again)")
        // Changed, it is looked at again.
        try T.model(copy, size: 33)
        #expect(Shop.untrackedInStorage(bench.library, rows: rows, ignored: led.skipped,
                                        seen: led.duplicateSet).files.count == 1)
    }

    // MARK: - 2. Past locations and the mirror

    @Test("a model in a past location is COPIED into the library and the original kept")
    func pastLocationCopied() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let old = bench.dir.appending(path: "OldLibrary")
        let file = old.appending(path: "Owls/owl.stl")
        try T.model(file, size: 9)
        try T.model(old.appending(path: "PF-stranded/gone.stl"), size: 8)   // a record folder: never
        let bytes = try Data(contentsOf: file)
        let report = try await T.adopt(bench, past: [old])
        #expect(report.added == 1, "\(report)")
        #expect(try Data(contentsOf: file) == bytes, "the original is where it was")
        guard case .object(let o)? = try T.rows(bench).first, case .string(let id)? = o["id"] else {
            Issue.record("no record"); return
        }
        #expect(o["externalPath"] == .null, "a copy, not a pointer into a folder the other app moves")
        let inside = try FileManager.default.contentsOfDirectory(
            atPath: bench.library.appending(path: LibraryLocation.itemDirName(id)).path)
        #expect(inside.contains("owl.stl"))
        #expect(try Self.ledger(bench).adopted.contains(Shop.canonical(file)))
        let again = try await T.adopt(bench, past: [old])
        #expect(again.added == 0 && again.duplicates == 0, "\(again)")
    }

    @Test("the mirror and the built-in vault are not past locations")
    func mirrorIgnored() {
        let roots = LibraryLocation.resolveRoots(
            settings: .object(["root": .string("/Users/x/lib"), "mirror": .string("/Volumes/Backup/lib"),
                               "history": .array([.string("/Users/x/old")])]),
            defaultRoot: "/Users/x/vault")
        #expect(Shop.pastLocations(roots, builtIn: "/Users/x/vault") == ["/Users/x/old"])
    }

    // MARK: - 3. The bucket

    let config = S3Config(endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "lib",
                          accessKeyId: "k", secretAccessKey: "s")

    func stl(_ size: Double) -> Data { MeshTests.binarySTL(MeshTests.boxFacets(size, size, size)) }

    func bucketBench() throws -> (Bench, FakeBucket) {
        let bench = try LibraryImportEndToEndTests.bench()
        try T.write([.object(["id": .string("PF-live"), "name": .string("Live")])], to: bench)
        let bucket = FakeBucket()
        bucket.seed("/lib/print-files/PF-live/live.stl", stl(10))        // the library's own copy
        bucket.seed("/lib/print-files/PF-gone/old.stl", stl(11))         // a deleted model's backup
        bucket.seed("/lib/print-files/_khayt-check/probe.bin", Data([1]))
        bucket.seed("/lib/Dragons/dragon.stl", stl(12))                  // the shop's, by hand
        bucket.seed("/lib/Dragons/copy-of-live.stl", stl(10))            // same bytes as the library's
        bucket.seed("/lib/Dragons/notes.txt", Data("hi".utf8))
        return (bench, bucket)
    }

    func adoptBucket(_ bench: Bench, _ bucket: FakeBucket) async throws -> Shop.StorageReport {
        try await Shop.adoptFromBucket(config, provider: config.endpoint, root: bench.library, storeURL: bench.store,
                                       fetch: bucket.fetch, owns: { true }, whoHasIt: { nil },
                                       progress: { _, _, _ in })
    }

    @Test("a hand-placed bucket object becomes a cloud-only model — nothing downloaded, orphans and copies skipped, once")
    func bucketAdoption() async throws {
        let (bench, bucket) = try bucketBench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let report = try await adoptBucket(bench, bucket)
        #expect(report.added == 1 && report.duplicates == 1, "\(report)")
        #expect(!bucket.gets.contains { $0.hasSuffix(".stl") }, "no model was downloaded: \(bucket.gets)")
        let rows = try T.rows(bench)
        #expect(rows.count == 2)
        guard case .object(let o)? = rows.first, case .string(let id)? = o["id"] else { Issue.record("shape"); return }
        #expect(o["originalName"] == .string("dragon.stl"))
        #expect(o["contentHash"] == .null, "not hashed: the bytes have not been here")
        let dir = bench.library.appending(path: LibraryLocation.itemDirName(id))
        let inside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(inside == ["dragon.stl" + Shop.onlineExt], "\(inside)")
        let marker = try JSONDecoder().decode(Shop.OnlineMarker.self,
                                              from: Data(contentsOf: dir.appending(path: inside[0])))
        #expect(marker.key == "Dragons/dragon.stl" && marker.size == stl(12).count && !marker.etag.isEmpty)
        // The listing of the library's files the tiering and backups walk
        // never sees the marker.
        #expect(!CloudLibrary.libraryFiles(root: bench.library.path).contains { $0.filename.hasSuffix(Shop.onlineExt) })

        let again = try await adoptBucket(bench, bucket)
        #expect(again.added == 0 && again.duplicates == 0, "\(again)")
        #expect(try T.rows(bench).count == 2)
    }

    @Test("a bucket model deleted from the library stays deleted, and its object is untouched")
    func bucketDeleteStays() async throws {
        let (bench, bucket) = try bucketBench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        _ = try await adoptBucket(bench, bucket)
        // The library's delete: the record and its folder, nothing else.
        var book = try #require(Shop.readBook(bench.store))
        guard case .object(let o)? = Shop.rows(book, "printFiles").first, case .string(let id)? = o["id"] else {
            Issue.record("shape"); return
        }
        book["printFiles"] = .array(Shop.rows(book, "printFiles").filter { Shop.recordId($0) != id })
        try JSONEncoder().encode(book).write(to: bench.store)
        try FileManager.default.removeItem(at: bench.library.appending(path: LibraryLocation.itemDirName(id)))
        #expect(bucket.object("/lib/Dragons/dragon.stl") != nil)
        let again = try await adoptBucket(bench, bucket)
        #expect(again.added == 0, "\(again)")
        // The delete path itself never talks to a bucket.
        let source = try LockRound3Tests.source("Shop+Customers.swift")
        let start = try #require(source.range(of: "func deleteLibraryFiles("))
        let body = source[start.lowerBound...].prefix(2500)
        #expect(!body.contains("S3.") && !body.contains("remote.delete"))
    }

    @Test("Bring Back fetches a cloud-only model, checks it, then hashes and measures it")
    func bringDownFills() async throws {
        let (bench, bucket) = try bucketBench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        _ = try await adoptBucket(bench, bucket)
        guard case .object(let o)? = try T.rows(bench).first, case .string(let id)? = o["id"] else {
            Issue.record("shape"); return
        }
        let dir = bench.library.appending(path: LibraryLocation.itemDirName(id))
        let marker = dir.appending(path: "dragon.stl" + Shop.onlineExt)
        let engine = try KhaytEngine()
        let model = try await Shop.bringDown(marker, config: config, engine: engine, download: S3.download(over: bucket.fetch))
        #expect(try Data(contentsOf: model) == stl(12))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try await Shop.fillDownloaded(id: id, file: model, storeURL: bench.store, engine: engine,
                                      owns: { true }, whoHasIt: { nil })
        guard case .object(let filled)? = try T.rows(bench).first(where: { Shop.recordId($0) == id }) else {
            Issue.record("gone"); return
        }
        #expect(filled["contentHash"] == .string(try #require(try LibraryImport.contentHash(of: model))))
        if case .string(let k)? = filled["geometryKey"] { #expect(!k.isEmpty) } else { Issue.record("not measured") }
        #expect(filled["thumbFile"] == .string("thumb.png"))
        #expect(bucket.object("/lib/Dragons/dragon.stl") != nil, "the shop's object stays where it is")
    }

    @Test("a download that is not what the listing said is refused, and the marker kept")
    func bringDownRefusesWrongBytes() async throws {
        let (bench, bucket) = try bucketBench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        _ = try await adoptBucket(bench, bucket)
        guard case .object(let o)? = try T.rows(bench).first, case .string(let id)? = o["id"] else { return }
        bucket.seed("/lib/Dragons/dragon.stl", stl(13))      // changed since the listing
        let marker = bench.library.appending(path: LibraryLocation.itemDirName(id))
            .appending(path: "dragon.stl" + Shop.onlineExt)
        // The download lands in a file (never the whole model in memory), and
        // a refused one leaves nothing behind: no download, no `.part`.
        let landed = Landed()
        let inner = S3.download(over: bucket.fetch)
        await #expect(throws: (any Error).self) {
            _ = try await Shop.bringDown(marker, config: config, engine: try KhaytEngine(), download: { request in
                let got = try await inner(request)
                landed.add(got.0)
                return got
            })
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(landed.files.count == 1)
        #expect(landed.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "the download was left behind")
        let left = try FileManager.default.contentsOfDirectory(atPath: marker.deletingLastPathComponent().path)
        #expect(!left.contains { $0.contains(".part-") }, "\(left)")
    }

    @Test("bring-down, bring-back and the read-back proof never GET a model into memory whole")
    func noWholeObjectGets() {
        let library = MenuCoverageTests.source("LibraryStorage.swift")
        let from = library.range(of: "static func bringDown(")?.lowerBound ?? library.endIndex
        let bringDown = String(library[from...]).components(separatedBy: "/// What a model's own bytes say")[0]
        #expect(bringDown.contains("S3.getFile("))
        #expect(!bringDown.contains("S3.get("))
        let cloud = MenuCoverageTests.source("CloudLibrary.swift")
        #expect(!cloud.contains("remote.get(side.key"), "bring-back must use getFile")
        #expect(!cloud.contains("c.get(key, fetch: fetch)"), "the read-back proof must use getFile")
    }

    @Test("a bucket model's photo is a small picture beside it — fetched, the model not")
    func bucketPhoto() async throws {
        let (bench, bucket) = try bucketBench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let pic = bench.dir.appending(path: "dragon.jpg")
        try T.picture(pic)
        bucket.seed("/lib/Dragons/dragon.jpg", try Data(contentsOf: pic))
        let report = try await adoptBucket(bench, bucket)
        #expect(report.photos == 1, "\(report)")
        guard case .object(let o)? = try T.rows(bench).first, case .string(let photo)? = o["userPhoto"] else {
            Issue.record("no photo"); return
        }
        #expect(photo.hasPrefix("data:image/jpeg"))
        #expect(bucket.gets == ["/lib/Dragons/dragon.jpg"])
    }

    @Test("photo keys follow the folder rules over a listing")
    func photoKeys() {
        let keys = ["Robot/files/head.stl", "Robot/files/arm.stl", "Robot/images/head.png", "Robot/images/cover.jpg",
                    "Lamp/files/lamp.stl", "Lamp/images/1.jpg"]
        let models = keys.filter { $0.hasSuffix(".stl") }
        #expect(Shop.photoKeys(for: "Robot/files/head.stl", among: keys, models: models) == ["Robot/images/head.png"])
        #expect(Shop.photoKeys(for: "Robot/files/arm.stl", among: keys, models: models).isEmpty)
        #expect(Shop.photoKeys(for: "Lamp/files/lamp.stl", among: keys, models: models) == ["Lamp/images/1.jpg"])
    }

    // MARK: - 4. Photos for models already in the library

    @Test("the backfill sets a photo once, and never again after the shop removes it")
    func backfillOnce() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let file = bench.library.appending(path: "Mine/owl.stl")
        try T.model(file)
        try T.picture(bench.library.appending(path: "Mine/owl.jpg"))
        // A vault model whose folder holds only the app's own thumb.
        let vault = bench.library.appending(path: "PF-vault")
        try T.model(vault.appending(path: "cat.stl"))
        try T.picture(vault.appending(path: "thumb.png"))
        try T.write([
            .object(["id": .string("PF-owl"), "name": .string("Owl"), "externalPath": .string(file.path),
                     "userPhoto": .null, "rev": .number(3)]),
            .object(["id": .string("PF-vault"), "name": .string("Cat"), "thumbFile": .string("thumb.png"),
                     "sourceFile": .object(["filename": .string("cat.stl")]), "rev": .number(5)]),
        ], to: bench)
        let roots = [bench.library.path]
        let set = await Shop.backfillPhotos(storeURL: bench.store, roots: roots, linked: [],
                                            owns: { true }, whoHasIt: { nil })
        #expect(set == 1)
        let rows = try T.rows(bench)
        guard case .object(let owl)? = rows.first(where: { Shop.recordId($0) == "PF-owl" }),
              case .object(let cat)? = rows.first(where: { Shop.recordId($0) == "PF-vault" }) else { return }
        guard case .string(let photo)? = owl["userPhoto"] else { Issue.record("no photo"); return }
        #expect(photo.hasPrefix("data:image/"))
        #expect(owl["rev"] == .number(4), "a record that gained a photo is stamped")
        #expect(cat["userPhoto"] == nil || cat["userPhoto"] == .null, "the app's own thumb is not a photo")
        #expect(cat["photoLookedFor"] != nil)
        #expect(cat["rev"] == .number(5), "only looked at: not an edit to sync")

        // The shop takes the photo off. It does not come back.
        var book = try #require(Shop.readBook(bench.store))
        book["printFiles"] = .array(Shop.rows(book, "printFiles").map { row in
            guard Shop.recordId(row) == "PF-owl", case .object(var o) = row else { return row }
            o["userPhoto"] = .null
            return .object(o)
        })
        try JSONEncoder().encode(book).write(to: bench.store)
        let again = await Shop.backfillPhotos(storeURL: bench.store, roots: roots, linked: [],
                                              owns: { true }, whoHasIt: { nil })
        #expect(again == 0)
        guard case .object(let after)? = try T.rows(bench).first(where: { Shop.recordId($0) == "PF-owl" }) else { return }
        #expect(after["userPhoto"] == .null)
    }

    @Test("a model not on this Mac is not marked: it is looked at once it arrives")
    func backfillWaitsForTheFile() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        try T.write([.object(["id": .string("PF-away"), "name": .string("Away"),
                              "externalPath": .string("/Volumes/NotMounted/away.stl")])], to: bench)
        _ = await Shop.backfillPhotos(storeURL: bench.store, roots: [bench.library.path], linked: [],
                                      owns: { true }, whoHasIt: { nil })
        guard case .object(let o)? = try T.rows(bench).first else { return }
        #expect(o["photoLookedFor"] == nil)
    }
}

/// The files a test's download handed back.
final class Landed: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var files: [URL] { lock.withLock { urls } }
}
