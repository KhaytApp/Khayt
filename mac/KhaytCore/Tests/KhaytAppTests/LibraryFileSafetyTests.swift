import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// The library's FILE data-loss risks, one test per way a model was lost.
@MainActor
@Suite(.serialized)
struct LibraryFileSafetyTests {

    static let day = 86_400_000.0
    static let now = Date(timeIntervalSince1970: 1_790_000_000)   // Sep 2026
    static var nowMs: Double { now.timeIntervalSince1970 * 1000 }

    static func record(_ id: String, created: Date, lastPrinted: String? = nil) throws -> LibraryFile {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string("Model \(id)"),
                                      "createdAt": .string(ISO8601DateFormatter().string(from: created))]
        if let lastPrinted { o["lastPrinted"] = .string(lastPrinted) }
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(o)))
    }

    static func job(_ status: String, date: String, files: [String]) throws -> Order {
        let parts = files.enumerated().map { i, id in
            JSONValue.object(["id": .string("p\(i)"), "name": .string("part"), "printFileId": .string(id)])
        }
        return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(JSONValue.object([
            "id": .string("J-\(status)-\(date)"), "status": .string(status), "date": .string(date),
            "parts": .array(parts),
        ])))
    }

    static func tierFile(_ id: String, ageDays: Double) -> KhaytEngine.TierFile {
        .init(filename: "\(id).3mf", fullPath: "/lib/\(id)/\(id).3mf", size: 80e6,
              mtimeMs: nowMs - ageDays * day, id: id)
    }

    // MARK: 1 — "Free up space now"

    @Test("a model imported this month is not 'unused for 90 days' because its copied mtime is old")
    func importDateCounts() async throws {
        let engine = try KhaytEngine()
        let fresh = try Self.record("PF-new", created: Self.now.addingTimeInterval(-5 * 86_400))
        let cold = try Self.record("PF-cold", created: Self.now.addingTimeInterval(-400 * 86_400))
        let usage = CloudLibrary.usage(files: [fresh, cold], orders: [])
        let listed = [Self.tierFile("PF-new", ageDays: 700), Self.tierFile("PF-cold", ageDays: 700)]
        let plan = try await engine.tierPlan(CloudLibrary.annotate(listed, usage: usage),
                                             policy: .object(["enabled": .bool(true), "keepDays": .number(90)]),
                                             now: Self.now)
        #expect(plan.candidates.map(\.id) == ["PF-cold"])
        #expect(plan.skipped["too-recent"] == 1)
    }

    @Test("a model on an unfinished job is never moved off; a finished or cancelled job only dates it")
    func openJobsKeepTheirModels() async throws {
        let engine = try KhaytEngine()
        let old = Self.now.addingTimeInterval(-900 * 86_400)
        let files = try ["PF-q", "PF-done", "PF-x"].map { try Self.record($0, created: old) }
        let orders = try [
            Self.job("pending", date: "2024-01-01", files: ["PF-q"]),
            Self.job("completed", date: "2024-01-01", files: ["PF-done"]),
            Self.job("cancelled", date: "2024-01-01", files: ["PF-x"]),
        ]
        let usage = CloudLibrary.usage(files: files, orders: orders)
        #expect(usage["PF-q"]?.inUse == true)
        #expect(usage["PF-done"]?.inUse == false)
        #expect(usage["PF-x"]?.inUse == false)
        let listed = ["PF-q", "PF-done", "PF-x"].map { Self.tierFile($0, ageDays: 900) }
        let plan = try await engine.tierPlan(CloudLibrary.annotate(listed, usage: usage),
                                             policy: .object(["enabled": .bool(true), "keepDays": .number(90)]),
                                             now: Self.now)
        #expect(Set(plan.candidates.compactMap(\.id)) == ["PF-done", "PF-x"])
        #expect(plan.skipped["in-use"] == 1)
    }

    @Test("a recent print or a recent job makes an old model recent")
    func recentUseCounts() throws {
        let old = Self.now.addingTimeInterval(-900 * 86_400)
        let printed = try Self.record("PF-p", created: old, lastPrinted: "2026-09-10")
        let jobbed = try Self.record("PF-j", created: old)
        let usage = CloudLibrary.usage(files: [printed, jobbed],
                                       orders: [try Self.job("delivered", date: "2026-09-12", files: ["PF-j"])])
        let sep = try #require(Order.day("2026-09-01")).timeIntervalSince1970 * 1000
        #expect((usage["PF-p"]?.lastUsedMs ?? 0) > sep)
        #expect((usage["PF-j"]?.lastUsedMs ?? 0) > sep)
    }

    @Test("the confirmation names the first few and counts the rest")
    func firstNames() {
        let more = { (n: Int) in "and \(n) more" }
        #expect(CloudLibrary.firstNames(["a", "b"], more: more) == "a, b")
        #expect(CloudLibrary.firstNames(["a", "b", "c", "d", "e", "f", "g"], more: more) == "a, b, c, d, e and 2 more")
    }

    @Test("the settings copy no longer promises models come back by themselves")
    func honestCopy() {
        let en = Words().callIt("mac.cloudlib_opt_move_why")
        #expect(!en.contains("come back when you open"))
        #expect(en.contains("Bring back"))
    }

    // MARK: 2 & 3 — where a moved model is, and bringing it back from there

    @Test("the sidecar's provider picks the remote asked first; empty falls back to the one in use")
    func routing() {
        #expect(CloudLibrary.remoteOrder(provider: "gdrive", current: .bucket) == [.drive, .bucket])
        #expect(CloudLibrary.remoteOrder(provider: "https://acc.r2.cloudflarestorage.com", current: .drive) == [.bucket, .drive])
        #expect(CloudLibrary.remoteOrder(provider: "", current: .drive) == [.drive, .bucket])
        #expect(CloudLibrary.remoteOrder(provider: nil, current: .bucket) == [.bucket, .drive])
    }

    @Test("switching remote is refused while models moved to the other one are out there")
    func strandedCount() {
        let providers: [String?] = ["gdrive", "gdrive", "https://acc.r2.cloudflarestorage.com", ""]
        #expect(CloudLibrary.stranded(switchingTo: .bucket, providers: providers, current: .drive) == 3)
        #expect(CloudLibrary.stranded(switchingTo: .drive, providers: providers, current: .drive) == 1)
        #expect(CloudLibrary.stranded(switchingTo: .drive, providers: [], current: .bucket) == 0)
    }

    @Test("a model moved to the old bucket is brought back from there, not refused by the new one")
    func bringBackFromWhereItWent() async throws {
        let bucket = FakeBucket()
        CloudLibrary.fetch = bucket.fetch
        let engine = try KhaytEngine()
        let old = S3Config(endpoint: "https://old.r2.cloudflarestorage.com", bucket: "old", accessKeyId: "k", secretAccessKey: "s")
        let new = S3Config(endpoint: "https://new.r2.cloudflarestorage.com", bucket: "new", accessKeyId: "k", secretAccessKey: "s")
        let dir = FileManager.default.temporaryDirectory.appending(path: "fs-\(UUID().uuidString)/PF-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Benchy.3mf")
        let original = Data((0..<4096).map { UInt8($0 % 251) })
        try original.write(to: url)
        let key = "print-files/PF-1/Benchy.3mf"
        let proved = try await CloudLibrary.ensureInBucket(.bucket(old), key: key, file: url, engine: engine)
        // The NEW bucket holds something else under the same key: refused by
        // the hash, and the old one is asked next.
        try await LibraryRemote.bucket(new).put(key, data: Data(repeating: 7, count: 4096), fetch: bucket.fetch)
        let text = try await engine.sidecarText(size: proved.size, sha256: proved.sha256, key: key,
                                                provider: old.endpoint, at: "2026-09-24T00:00:00.000Z")
        try Data(text.utf8).write(to: CloudLibrary.sidecar(for: url))
        try FileManager.default.removeItem(at: url)

        // Only the one in use, as before: refused, nothing written.
        await #expect(throws: (any Error).self) {
            try await CloudLibrary.bringBack(url, remotes: { _ in [.bucket(new)] }, engine: engine)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Routed: the new one first, then the old — and it comes back intact.
        var askedWith: String?
        try await CloudLibrary.bringBack(url, remotes: { side in
            askedWith = side.provider
            return [.bucket(new), .bucket(old)]
        }, engine: engine)
        #expect(askedWith == old.endpoint)
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: CloudLibrary.sidecar(for: url).path))
    }

    // MARK: 4 — adding models

    @Test("adding models keeps the originals unless the shop chose to move them")
    func keepIsTheDefault() {
        let d = UserDefaults.standard
        let was = d.object(forKey: Shop.importMovesOriginalsKey)
        defer { if let was { d.set(was, forKey: Shop.importMovesOriginalsKey) } else { d.removeObject(forKey: Shop.importMovesOriginalsKey) } }
        d.removeObject(forKey: Shop.importMovesOriginalsKey)
        let shop = Shop()
        #expect(shop.importMovesOriginals == false)
        d.set(true, forKey: Shop.importMovesOriginalsKey)
        #expect(shop.importMovesOriginals == true)
    }

    @Test("the window's import passes keep-original through and skips linked folders")
    func importWiring() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "func addModelsToLibrary(_ chosen: [URL]"))
        let body = String(source[start.lowerBound...].prefix(6000))
        #expect(body.contains("keepOriginal: keepOriginal,"))
        #expect(body.contains("+ linkedFolders)"))
    }

    @Test("a linked folder is never walked by an import")
    func linkedFoldersSkipped() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lk-\(UUID().uuidString)")
        let linked = base.appending(path: "Dropbox/Models")
        let loose = base.appending(path: "Downloads")
        for d in [linked, loose] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data([1]).write(to: linked.appending(path: "a.stl"))
        try Data([1]).write(to: loose.appending(path: "b.stl"))
        let found = Shop.modelsUnder([base], skippingAll: ["/nowhere", linked.path])
        #expect(found.map(\.url.lastPathComponent) == ["b.stl"])
    }

    // MARK: 5 — moving the library

    @Test("moving the library takes back only record folders from an old root, never the shop's other files")
    func strandedOnlyRecordDirs() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mv-\(UUID().uuidString)")
        let fm = FileManager.default
        for d in ["PF-abc", "my_record", "Taxes", "Photos/2025"] {
            try fm.createDirectory(at: root.appending(path: d), withIntermediateDirectories: true)
        }
        try Data([1]).write(to: root.appending(path: "PF-abc/model.3mf"))
        try Data([1]).write(to: root.appending(path: "my_record/model.stl"))
        try Data([1]).write(to: root.appending(path: "Taxes/2025.pdf"))
        try Data([1]).write(to: root.appending(path: "Photos/2025/beach.jpg"))
        try Data([1]).write(to: root.appending(path: "loose.stl"))
        let rels = Set(LibraryMove.walk(root.path, recordDirs: ["my_record"]).map(\.rel))
        #expect(rels == ["PF-abc/model.3mf", "my_record/model.stl"])
        #expect(LibraryMove.walk(root.path).count == 5, "the unrestricted walk still sees everything")
    }
}
