import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// Deleting from THIS MAC by default, COMPLETELY when asked — and the only
/// copy of anything is never lost without the person seeing the count.
@MainActor
@Suite(.serialized)
struct LibraryDeleteChoiceTests {

    let config = S3Config(endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "lib",
                          accessKeyId: "k", secretAccessKey: "s")

    func record(_ json: [String: Any]) throws -> LibraryFile {
        try JSONDecoder().decode(LibraryFile.self, from: JSONSerialization.data(withJSONObject: json))
    }

    struct Fixture {
        let root: URL
        let bucket: FakeBucket
        let files: [LibraryFile]
        let paths: [String: URL]
    }

    /// Four models, one of each kind:
    /// * `PF-a` — in the vault, with a matching backup in the bucket;
    /// * `PF-b` — in the vault, never backed up: only on this Mac;
    /// * `PF-c` — the shop's own file in its own folder, backed up too;
    /// * `PF-d` — cloud-only, put in the bucket by the shop by hand.
    func fixture() throws -> Fixture {
        let root = try LibraryImportTests.tempDir()
        let bucket = FakeBucket()
        let fm = FileManager.default
        var paths: [String: URL] = [:]
        for (id, name, size) in [("PF-a", "a.stl", 10.0), ("PF-b", "b.stl", 11.0)] {
            let url = root.appending(path: "\(id)/\(name)")
            try LibraryStorageTests.model(url, size: size)
            paths[id] = url
        }
        bucket.seed("/lib/print-files/PF-a/a.stl", try Data(contentsOf: paths["PF-a"]!))
        let own = root.deletingLastPathComponent().appending(path: "own-\(UUID().uuidString)/c.stl")
        try LibraryStorageTests.model(own, size: 12)
        try fm.createDirectory(at: root.appending(path: "PF-c"), withIntermediateDirectories: true)
        bucket.seed("/lib/print-files/PF-c/c.stl", try Data(contentsOf: own))
        paths["PF-c"] = own
        try fm.createDirectory(at: root.appending(path: "PF-d"), withIntermediateDirectories: true)
        let marker = Shop.OnlineMarker(key: "Mine/d.stl", size: 5, etag: "x", bucket: "lib",
                                       provider: config.endpoint, at: "now")
        try JSONEncoder().encode(marker).write(to: root.appending(path: "PF-d/d.stl" + Shop.onlineExt))
        bucket.seed("/lib/Mine/d.stl", Data([1, 2, 3, 4, 5]))
        let files = [
            try record(["id": "PF-a", "name": "A", "sourceFile": ["filename": "a.stl"]]),
            try record(["id": "PF-b", "name": "B", "sourceFile": ["filename": "b.stl"]]),
            try record(["id": "PF-c", "name": "C", "externalPath": own.path]),
            try record(["id": "PF-d", "name": "D", "sourceFile": ["filename": "d.stl"]]),
        ]
        return Fixture(root: root, bucket: bucket, files: files, paths: paths)
    }

    func plan(_ f: Fixture) async throws -> LibraryDeletePlan {
        await Shop.planDelete(f.files, roots: [f.root.path], remote: .bucket(config), prefix: "",
                              remoteTag: "bucket:", engine: try KhaytEngine(), fetch: f.bucket.fetch,
                              modelFile: { f.paths[$0.id] })
    }

    @Test("each model is counted for what deleting it means: kept online, only here, the shop's own, online-only")
    func planCounts() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let p = try await plan(f)
        #expect(p.keptOnline == ["PF-a"])
        #expect(p.onlyHere == ["PF-b"], "no online copy: counted, and needs its own confirmation")
        #expect(p.inPlace == ["PF-c"])
        #expect(p.cloudOnly == ["PF-d"] && p.handPlaced == ["PF-d"])
        #expect(p.online["PF-d"] == ["bucket:Mine/d.stl"])
        #expect(p.local["PF-c"] == nil, "the shop's own file is never a local copy to remove")
        let en = Words(); await en.load("en", engine: try KhaytEngine())
        let lines = Shop.deletePlanLines(p, words: en)
        #expect(lines.contains { $0.contains("One of these 4 is only on this Mac") }, "\(lines)")
    }

    /// A selection was planned one HEAD after another, each with its own
    /// request timeout: the question waited minutes on a slow remote, and for
    /// ever on one that never answered.
    @Test("the backups are asked about a few at a time, and the whole plan is bounded")
    func planIsConcurrentAndBounded() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        final class Flight: @unchecked Sendable {
            let lock = NSLock(); var now = 0; var most = 0
            func enter() { lock.withLock { now += 1; most = max(most, now) } }
            func leave() { lock.withLock { now -= 1 } }
        }
        let flight = Flight()
        let hangs: S3.Fetch = { _ in
            flight.enter()
            defer { flight.leave() }
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        var many = f.files
        for i in 0..<8 {
            let id = "PF-x\(i)"
            let url = f.root.appending(path: "\(id)/x.stl")
            try LibraryStorageTests.model(url, size: 9)
            many.append(try record(["id": id, "name": id, "sourceFile": ["filename": "x.stl"]]))
        }
        let started = ContinuousClock.now
        let p = await Shop.planDelete(many, roots: [f.root.path], remote: .bucket(config), prefix: "",
                                      remoteTag: "bucket:", engine: try KhaytEngine(), fetch: hangs,
                                      patience: .milliseconds(400),
                                      modelFile: { file in
                                          f.paths[file.id] ?? f.root.appending(path: "\(file.id)/x.stl")
                                      })
        // Each remote hangs for 60 s; a plan that waited on one would take a
        // minute. 30 s, not 10: under the whole suite's load the 400 ms
        // patience alone stretched past 10 (beta.1 batch run).
        #expect(ContinuousClock.now - started < .seconds(30), "the plan waited on the remote")
        #expect(flight.most > 1 && flight.most <= Shop.deleteCheckWidth, "\(flight.most) at once")
        #expect(p.keptOnline.isEmpty, "nothing is kept online on a copy nobody saw")
        #expect(p.onlyHere.contains("PF-a") && p.ids.count == many.count)
    }

    @Test("Remove from This Mac: the file goes only once the online copy is proved, and the copy stays")
    func removeLocalKeepsOnline() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let p = try await plan(f)
        let copy = try #require(p.local["PF-a"])
        try await Shop.removeLocalCopy(copy, remote: .bucket(config), provider: config.endpoint,
                                       engine: try KhaytEngine(), fetch: f.bucket.fetch)
        #expect(!FileManager.default.fileExists(atPath: copy.model.path))
        #expect(FileManager.default.fileExists(atPath: CloudLibrary.sidecar(for: copy.model).path),
                "it stays in the library as an online model")
        #expect(f.bucket.object("/lib/print-files/PF-a/a.stl") != nil)
    }

    @Test("a copy that turns out not to be there keeps the local file")
    func removeLocalRefusesUnproved() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let p = try await plan(f)
        let copy = try #require(p.local["PF-a"])
        f.bucket.remove("/lib/print-files/PF-a/a.stl")
        f.bucket.lie = .dropsPut
        await #expect(throws: (any Error).self) {
            try await Shop.removeLocalCopy(copy, remote: .bucket(config), provider: config.endpoint,
                                           engine: try KhaytEngine(), fetch: f.bucket.fetch)
        }
        #expect(FileManager.default.fileExists(atPath: copy.model.path))
    }

    @Test("Delete Completely removes the online copies, the shop's hand-placed object included")
    func completeDeletesOnline() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let p = try await plan(f)
        let r = await Shop.deleteOnlineCopies(p, ids: p.ids, remote: .bucket(config), bucket: .bucket(config),
                                              remoteTag: "bucket:", fetch: f.bucket.fetch)
        #expect(Set(r.done) == Set(p.ids) && r.failed.isEmpty)
        #expect(f.bucket.object("/lib/print-files/PF-a/a.stl") == nil)
        #expect(f.bucket.object("/lib/print-files/PF-c/c.stl") == nil)
        #expect(f.bucket.object("/lib/Mine/d.stl") == nil)
        #expect(FileManager.default.fileExists(atPath: f.paths["PF-c"]!.path), "never the shop's own file")
    }

    /// A backup keeps more than the model under the model's own folder —
    /// versions, thumbs, guides — and Delete Completely left all of it.
    @Test("Delete Completely empties the model's own online folder, and only its own")
    func completeEmptiesTheFolder() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.bucket.seed("/lib/print-files/PF-a/versions/v1.stl", Data([1]))
        f.bucket.seed("/lib/print-files/PF-a/thumb.png", Data([2]))
        f.bucket.seed("/lib/print-files/PF-ab/x.stl", Data([3]))   // another model, the same first letters
        f.bucket.seed("/lib/print-files/PF-b/guide.pdf", Data([4])) // PF-b's backup was never found
        let p = try await plan(f)
        let r = await Shop.deleteOnlineCopies(p, ids: ["PF-a", "PF-b"], remote: .bucket(config),
                                              bucket: .bucket(config), remoteTag: "bucket:", prefix: "",
                                              fetch: f.bucket.fetch)
        #expect(Set(r.done) == ["PF-a", "PF-b"] && r.failed.isEmpty, "\(r.failed)")
        for gone in ["/lib/print-files/PF-a/a.stl", "/lib/print-files/PF-a/versions/v1.stl",
                     "/lib/print-files/PF-a/thumb.png", "/lib/print-files/PF-b/guide.pdf"] {
            #expect(f.bucket.object(gone) == nil, "\(gone) was left in the bucket")
        }
        #expect(f.bucket.object("/lib/print-files/PF-ab/x.stl") != nil, "another model's file went too")
        #expect(f.bucket.object("/lib/print-files/PF-c/c.stl") != nil, "a model not chosen was touched")
    }

    @Test("an online delete that fails keeps that model whole, and the others go")
    func completeFailureIsConsistent() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let p = try await plan(f)
        let inner = f.bucket.fetch
        let failing: S3.Fetch = { request in
            if request.httpMethod == "DELETE", request.url?.path.contains("Mine") == true {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            return try await inner(request)
        }
        let r = await Shop.deleteOnlineCopies(p, ids: p.ids, remote: .bucket(config), bucket: .bucket(config),
                                              remoteTag: "bucket:", fetch: failing)
        #expect(r.failed.keys.sorted() == ["PF-d"])
        #expect(!r.done.contains("PF-d"), "its record is kept: it still points at an object that is there")
        #expect(f.bucket.object("/lib/Mine/d.stl") != nil)
        #expect(r.done.contains("PF-a"))
    }

    @Test("with nowhere online to delete from, a model with online copies is kept, not half-deleted")
    func completeWithNoRemote() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let p = try await plan(f)
        let r = await Shop.deleteOnlineCopies(p, ids: ["PF-b", "PF-d"], remote: nil, bucket: nil,
                                              remoteTag: "bucket:", fetch: f.bucket.fetch)
        #expect(r.done == ["PF-b"], "nothing online: nothing to fail")
        #expect(r.failed.keys.sorted() == ["PF-d"])
    }

    @Test("the question offers the choices, in both languages")
    func wired() async throws {
        let window = try LockRound3Tests.source("ShopWindow.swift")
        #expect(window.contains("shop.removeFromThisMac(plan, includingOnlyHere: false)"))
        #expect(window.contains("shop.removeFromThisMac(plan, includingOnlyHere: true)"))
        #expect(window.contains("shop.deleteCompletely(plan)"))
        #expect(window.contains("await shop.planDeletes("))
        let engine = try KhaytEngine()
        let english = Words(); await english.load("en", engine: engine)
        let arabic = Words(); await arabic.load("ar", engine: engine)
        for key in ["mac.delete_from_mac", "mac.delete_only_here_too", "mac.delete_completely",
                    "mac.delete_kept_online", "mac.delete_only_here", "mac.delete_in_place",
                    "mac.delete_completely_says", "mac.delete_hand_placed", "mac.delete_local_done",
                    "mac.delete_online_failed", "mac.delete_checking"] {
            #expect(english.callIt(key) != key && arabic.callIt(key) != key
                    && english.callIt(key) != arabic.callIt(key), "\(key) is missing a language")
        }
    }
}
