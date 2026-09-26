import Foundation
import Testing
@testable import KhaytCore

/// A destination that lives in memory, and can be told to misbehave.
actor MemoryDestination: OffsiteDestination {
    var files: [String: Data] = [:]
    var mangle = false
    var refuseDeletes = false
    private(set) var puts = 0

    init(_ files: [String: Data] = [:]) { self.files = files }

    func setMangle(_ on: Bool) { mangle = on }
    func put(_ name: String, data: Data) async throws {
        puts += 1
        files[name] = mangle ? data.prefix(data.count / 2) : data
    }
    func get(_ name: String) async throws -> Data? { files[name] }
    func list() async throws -> [OffsiteBackup.Entry] {
        files.map { OffsiteBackup.Entry(name: $0.key, bytes: $0.value.count, modified: nil) }
    }
    func delete(_ name: String) async throws {
        if refuseDeletes { throw URLError(.cannotRemoveFile) }
        files[name] = nil
    }
}

struct OffsiteBackupTests {

    static let dek = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
    /// A book as it sits on disk — key order and number formatting that a
    /// decode-and-re-encode would change.
    static let book = Data(#"{"version":10,"settings":{"bizEn":"The Shop","z":1.50},"orders":[{"id":"O-1","price":120}]}"#.utf8)

    // MARK: - Encrypt, then decrypt

    @Test("a sealed backup opens with the same key, byte for byte")
    func roundTrip() throws {
        let sealed = try OffsiteBackup.seal(Self.book, dek: Self.dek, createdAt: "2026-09-26T01:00:00Z")
        #expect(try OffsiteBackup.open(sealed, dek: Self.dek) == Self.book)
    }

    @Test("what leaves the Mac carries none of the book in the clear")
    func ciphertextOnly() throws {
        let sealed = try OffsiteBackup.seal(Self.book, dek: Self.dek, createdAt: "2026-09-26T01:00:00Z")
        let text = String(decoding: sealed, as: UTF8.self)
        #expect(!text.contains("The Shop"))
        #expect(!text.contains("O-1"))
        #expect(text.contains(OffsiteBackup.format))
    }

    @Test("a different key does not open it, and says so")
    func wrongKey() throws {
        let sealed = try OffsiteBackup.seal(Self.book, dek: Self.dek, createdAt: "x")
        var other = Self.dek
        other[0] ^= 0xFF
        #expect(throws: OffsiteBackup.Failure.wrongKey) { try OffsiteBackup.open(sealed, dek: other) }
    }

    @Test("a file that is not one of these is refused by name")
    func notABackup() {
        #expect(throws: OffsiteBackup.Failure.notABackup) {
            try OffsiteBackup.open(Data(#"{"version":10}"#.utf8), dek: Self.dek)
        }
    }

    // MARK: - No key, no upload

    @Test("with no key nothing is sealed and nothing is uploaded")
    func refusesWithoutKey() async throws {
        #expect(throws: OffsiteBackup.Failure.noKey) {
            try OffsiteBackup.seal(Self.book, dek: nil, createdAt: "x")
        }
        #expect(throws: OffsiteBackup.Failure.noKey) {
            try OffsiteBackup.seal(Self.book, dek: Data(), createdAt: "x")
        }
        let destination = MemoryDestination()
        await #expect(throws: OffsiteBackup.Failure.noKey) {
            try await OffsiteBackup.run(book: Self.book, dek: nil, day: "2026-09-26", createdAt: "x", to: destination)
        }
        #expect(await destination.puts == 0, "an unencrypted book reached the destination")
        #expect(await destination.files.isEmpty)
    }

    // MARK: - A night's run

    @Test("a run uploads, proves the upload, and names it by the day")
    func run() async throws {
        let destination = MemoryDestination()
        let outcome = try await OffsiteBackup.run(book: Self.book, dek: Self.dek, day: "2026-09-26",
                                                  createdAt: "2026-09-26T01:00:00Z", to: destination)
        #expect(outcome.name == "khayt-book-2026-09-26.khaytbak")
        let stored = try #require(await destination.files[outcome.name])
        #expect(outcome.bytes == stored.count)
        #expect(try OffsiteBackup.open(stored, dek: Self.dek) == Self.book)
    }

    @Test("a destination that mangles the file fails the run, and prunes nothing")
    func mangled() async throws {
        var old: [String: Data] = [:]
        for d in 1...31 { old[OffsiteBackup.filename(day: String(format: "2026-08-%02d", d))] = Data([1]) }
        let destination = MemoryDestination(old)
        await destination.setMangle(true)
        await #expect(throws: OffsiteBackup.Failure.readBackDiffers) {
            try await OffsiteBackup.run(book: Self.book, dek: Self.dek, day: "2026-09-26", createdAt: "x", to: destination)
        }
        #expect(await destination.files.count == 32, "a failed night cost an old backup")
    }

    @Test("a run prunes past 30 dailies and 12 monthlies, and leaves strangers alone")
    func runPrunes() async throws {
        var files: [String: Data] = ["notes.txt": Data([1])]
        var day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                 year: 2025, month: 1, day: 1).date!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        while fmt.string(from: day) < "2026-09-26" {
            files[OffsiteBackup.filename(day: fmt.string(from: day))] = Data([1])
            day = day.addingTimeInterval(86_400)
        }
        let destination = MemoryDestination(files)
        let outcome = try await OffsiteBackup.run(book: Self.book, dek: Self.dek, day: "2026-09-26",
                                                  createdAt: "x", to: destination)
        let left = await destination.files.keys.sorted()
        #expect(left.contains("notes.txt"))
        let ours = left.compactMap(OffsiteBackup.day(of:))
        #expect(ours.count == 42, Comment(rawValue: "kept \(ours.count): \(ours)"))
        #expect(ours.last == "2026-09-26")
        #expect(!outcome.pruned.isEmpty)
    }

    // MARK: - Retention

    static func names(_ days: [String]) -> [String] { days.map(OffsiteBackup.filename(day:)) }

    @Test("30 dailies, then the newest of each older month for 12 months")
    func retention() {
        // Every day from 2025-06-01 to 2026-09-26.
        var days: [String] = []
        for (y, m, last) in [(2025, 6, 30), (2025, 7, 31), (2025, 8, 31), (2025, 9, 30), (2025, 10, 31),
                             (2025, 11, 30), (2025, 12, 31), (2026, 1, 31), (2026, 2, 28), (2026, 3, 31),
                             (2026, 4, 30), (2026, 5, 31), (2026, 6, 30), (2026, 7, 31), (2026, 8, 31),
                             (2026, 9, 26)] {
            for d in 1...last { days.append(String(format: "%04d-%02d-%02d", y, m, d)) }
        }
        let all = Self.names(days)
        let pruned = Set(OffsiteBackup.toPrune(all))
        let kept = all.filter { !pruned.contains($0) }.compactMap(OffsiteBackup.day(of:)).sorted()

        #expect(kept.count == 42)
        // The last thirty days, every one.
        #expect(Array(kept.suffix(30)) == Array(days.suffix(30)))
        // Before those, one per month — the newest of it — for twelve months.
        #expect(Array(kept.prefix(12)) == ["2025-09-30", "2025-10-31", "2025-11-30", "2025-12-31",
                                           "2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30",
                                           "2026-05-31", "2026-06-30", "2026-07-31", "2026-08-27"])
    }

    @Test("fewer than 30 backups: nothing is pruned")
    func retentionYoung() {
        let all = Self.names((1...20).map { String(format: "2026-09-%02d", $0) })
        #expect(OffsiteBackup.toPrune(all).isEmpty)
    }

    @Test("names that are not ours are never pruned")
    func retentionStrangers() {
        let all = ["khayt-book-2020-01-01.json", "khayt-book-latest.khaytbak", "readme.txt"]
            + Self.names((1...28).map { String(format: "2026-09-%02d", $0) } + ["2024-01-01", "2024-01-02"])
        let pruned = OffsiteBackup.toPrune(all, keepDaily: 28, keepMonthly: 0)
        #expect(pruned == Self.names(["2024-01-01", "2024-01-02"]))
    }

    // MARK: - Status

    @Test("failing counts from the FIRST failure, and a success clears it")
    func status() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = OffsiteBackup.Status()
        #expect(OffsiteBackup.isDue(s, now: t0))
        s = s.failed("offline", at: t0)
        s = s.failed("offline again", at: t0.addingTimeInterval(3600))
        #expect(s.failingSince == t0)
        #expect(s.lastError == "offline again")
        #expect(!OffsiteBackup.isOverdue(s, now: t0.addingTimeInterval(2 * 86_400)))
        #expect(OffsiteBackup.isOverdue(s, now: t0.addingTimeInterval(2 * 86_400 + 60)))

        let ok = OffsiteBackup.Outcome(name: "khayt-book-2026-09-26.khaytbak", bytes: 900, pruned: [], pruneFailures: 0)
        s = s.succeeded(ok, at: t0.addingTimeInterval(3 * 86_400))
        #expect(s.failingSince == nil && s.lastError == nil && s.lastBytes == 900)
        #expect(!OffsiteBackup.isOverdue(s, now: t0.addingTimeInterval(10 * 86_400)))
        #expect(!OffsiteBackup.isDue(s, now: t0.addingTimeInterval(3 * 86_400 + 3600)))
        #expect(OffsiteBackup.isDue(s, now: t0.addingTimeInterval(4 * 86_400)))
    }

    // MARK: - The destinations

    @Test("a folder destination round-trips, lists, and cannot be walked out of")
    func folder() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "offsite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = FolderDestination(root: dir)
        let outcome = try await OffsiteBackup.run(book: Self.book, dek: Self.dek, day: "2026-09-26",
                                                  createdAt: "x", to: destination)
        #expect(try await OffsiteBackup.available(at: destination).map(\.name) == [outcome.name])
        #expect(try await OffsiteBackup.fetch(outcome.name, from: destination, dek: Self.dek) == Self.book)
        try await destination.put("../escape.khaytbak", data: Data([1]))
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appending(path: "escape.khaytbak").path))
    }

    @Test("a not-yet-downloaded iCloud file lists under its own name")
    func folderPlaceholder() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "offsite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appending(path: ".khayt-book-2026-09-01.khaytbak.icloud"))
        #expect(try await OffsiteBackup.available(at: FolderDestination(root: dir)).map(\.name)
                == ["khayt-book-2026-09-01.khaytbak"])
    }

    @Test("a bucket lists by ListObjectsV2, signed, and keeps only its own folder")
    func bucketList() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>b</Name><Prefix>shop/khayt-offsite-backups/</Prefix><IsTruncated>false</IsTruncated>
          <Contents><Key>shop/khayt-offsite-backups/khayt-book-2026-09-25.khaytbak</Key>
            <LastModified>2026-09-25T01:00:00.000Z</LastModified><Size>1234</Size></Contents>
          <Contents><Key>shop/khayt-offsite-backups/deeper/other.khaytbak</Key><Size>1</Size></Contents>
        </ListBucketResult>
        """
        let seen = Seen()
        let fetch: S3.Fetch = { request in
            await seen.add(request)
            return (Data(xml.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let config = S3Config(endpoint: "https://acct.r2.cloudflarestorage.com", bucket: "b",
                              accessKeyId: "id", secretAccessKey: "secret", prefix: "shop")
        let listed = try await BucketDestination(config: config, fetch: fetch).list()
        #expect(listed == [OffsiteBackup.Entry(name: "khayt-book-2026-09-25.khaytbak", bytes: 1234,
                                               modified: S3.ListParser.date("2026-09-25T01:00:00.000Z"))])
        let request = try #require(await seen.requests.first)
        #expect(request.url?.absoluteString
                == "https://acct.r2.cloudflarestorage.com/b?list-type=2&prefix=shop%2Fkhayt-offsite-backups%2F")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
    }

    actor Seen {
        var requests: [URLRequest] = []
        func add(_ r: URLRequest) { requests.append(r) }
    }
}
