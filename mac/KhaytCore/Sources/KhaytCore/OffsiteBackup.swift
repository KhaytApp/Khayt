import Foundation

/// A copy of the shop's book that lives somewhere other than this Mac.
///
/// ── WHY ─────────────────────────────────────────────────────────────────
///
/// The daily backups (`Backups` in the app) sit in a folder beside the book,
/// on the same disk. They undo a bad afternoon; they do nothing for a stolen,
/// dead or flooded Mac. This is the other half: once a night the book is
/// sealed and sent to a bucket, a Google Drive or a folder such as iCloud
/// Drive — the places the print library already knows how to reach.
///
/// ── NOTHING LEAVES UNENCRYPTED ──────────────────────────────────────────
///
/// The payload is sealed with the shop's Khayt Cloud data key (`SyncCrypto`,
/// the same AES-256-GCM envelope the cloud stores). That key is recoverable
/// on a NEW Mac from the shop's passphrase, which is the whole point: a
/// backup nobody can open after the Mac it came from is gone is not a backup.
/// With no key there is no upload — `seal` refuses by name rather than
/// falling back to plain text.
///
/// ── WHAT IS HERE AND WHAT IS NOT ────────────────────────────────────────
///
/// Portable and pure of the network: the name of a backup, which ones to
/// keep, the sealed file's shape, and the four calls a destination answers.
/// Scheduling, settings and the screen are the app's.
public enum OffsiteBackup {

    /// The folder (or key prefix) the backups go under at a destination.
    public static let folder = "khayt-offsite-backups"
    public static let stem = "khayt-book-"
    public static let fileExtension = "khaytbak"
    /// The sealed file's `format`, so a stray file is refused by name.
    public static let format = "khayt-offsite-backup"
    public static let version = 1

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No data key: the shop is not signed in to Khayt Cloud, or has not
        /// unlocked it on this Mac.
        case noKey
        /// Not one of these files at all.
        case notABackup
        /// Written by a newer app than this one.
        case tooNew(Int)
        /// The destination does not have it.
        case missing(String)
        /// Uploaded, and what came back was not what was sent.
        case readBackDiffers
        /// It would not open with this key.
        case wrongKey

        public var description: String {
            switch self {
            case .noKey: "there is no Khayt Cloud key on this Mac to encrypt the backup with"
            case .notABackup: "that file is not a Khayt off-site backup"
            case .tooNew(let v): "that backup was written by a newer Khayt (format \(v))"
            case .missing(let name): "\(name) is not at the destination"
            case .readBackDiffers: "the copy read back from the destination is not the one sent"
            case .wrongKey: "the backup would not open with this shop's key"
            }
        }
    }

    // MARK: - Names

    /// `khayt-book-2026-09-26.khaytbak`. One a day: a second backup the same
    /// day replaces the first, so "30 dailies" means thirty days.
    public static func filename(day: String) -> String {
        stem + day + "." + fileExtension
    }

    /// The day a backup is for, or nil when the name is not one of ours.
    /// Anything else at the destination is never listed, and never pruned.
    public static func day(of filename: String) -> String? {
        guard filename.hasPrefix(stem), filename.hasSuffix("." + fileExtension) else { return nil }
        let day = String(filename.dropFirst(stem.count).dropLast(fileExtension.count + 1))
        guard day.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return nil }
        return day
    }

    /// Where a backup sits at a bucket or a Drive: `[prefix]/khayt-offsite-backups/<name>`.
    public static func key(prefix: String, name: String) -> String {
        [keyFolder(prefix: prefix), name].joined(separator: "/")
    }

    public static func keyFolder(prefix: String) -> String {
        let clean = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return [clean, folder].filter { !$0.isEmpty }.joined(separator: "/")
    }

    // MARK: - Keeping 30 dailies and 12 monthlies

    /// Which backups to delete, given every name at the destination.
    ///
    /// Kept: the newest `keepDaily` backups, and then — from what is OLDER
    /// than those — the newest backup of each month, for `keepMonthly`
    /// months. So a shop has the last month day by day and the year before it
    /// month by month. Names that are not ours are never returned.
    public static func toPrune(_ names: [String], keepDaily: Int = 30, keepMonthly: Int = 12) -> [String] {
        let dated = names.compactMap { name in day(of: name).map { (name: name, day: $0) } }
            .sorted { $0.day > $1.day }                                // newest first
        let dailies = dated.prefix(max(0, keepDaily))
        var keep = Set(dailies.map(\.name))
        var months: [String] = []
        for entry in dated.dropFirst(dailies.count) {
            let month = String(entry.day.prefix(7))
            guard !months.contains(month) else { continue }
            months.append(month)
            if months.count > keepMonthly { break }
            keep.insert(entry.name)
        }
        return dated.filter { !keep.contains($0.name) }.map(\.name).sorted()
    }

    // MARK: - The sealed file

    /// What is written at the destination: a small JSON wrapper around the
    /// `SyncCrypto` blob. `createdAt` is outside the encryption so a list can
    /// be read without the key; nothing about the book is.
    public struct Envelope: Codable, Sendable {
        public let format: String
        public let v: Int
        public let createdAt: String
        public let blob: SyncCrypto.Blob
    }

    /// Seal the book's bytes, exactly as they are on disk. Refuses without a
    /// key — there is no unencrypted path.
    public static func seal(_ book: Data, dek: Data?, createdAt: String) throws -> Data {
        guard let dek, !dek.isEmpty else { throw Failure.noKey }
        let envelope = Envelope(format: format, v: version, createdAt: createdAt,
                                blob: try SyncCrypto.sealBytes(book, dek: dek))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(envelope)
    }

    /// The book's bytes back out of a sealed file.
    public static func open(_ sealed: Data, dek: Data?) throws -> Data {
        guard let dek, !dek.isEmpty else { throw Failure.noKey }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: sealed),
              envelope.format == format else { throw Failure.notABackup }
        guard envelope.v <= version else { throw Failure.tooNew(envelope.v) }
        do { return try SyncCrypto.openStore(envelope.blob, dek: dek) }
        catch SyncCrypto.Failure.wrongKey { throw Failure.wrongKey }
    }

    // MARK: - One night's run

    /// What a successful run did.
    public struct Outcome: Sendable, Equatable {
        public let name: String
        /// The size of what was uploaded (the sealed file).
        public let bytes: Int
        public let pruned: [String]
        /// Old backups that should have gone and did not. Never a reason to
        /// call the backup itself a failure.
        public let pruneFailures: Int
    }

    /// Seal, upload, PROVE, then prune.
    ///
    /// The proof is a separate download that must be byte-identical to what
    /// was sent AND must open with the key — so a destination that mangles or
    /// truncates is caught on the night, not on the day it is needed. Pruning
    /// only happens after that, so a failed night never costs an old backup.
    public static func run(book: Data, dek: Data?, day: String, createdAt: String,
                           to destination: any OffsiteDestination,
                           keepDaily: Int = 30, keepMonthly: Int = 12) async throws -> Outcome {
        let sealed = try seal(book, dek: dek, createdAt: createdAt)
        let name = filename(day: day)
        try await destination.put(name, data: sealed)
        guard let back = try await destination.get(name) else { throw Failure.missing(name) }
        guard back == sealed, try open(back, dek: dek) == book else { throw Failure.readBackDiffers }

        var pruned: [String] = []
        var failures = 0
        let present = try await destination.list().map(\.name)
        for old in toPrune(present, keepDaily: keepDaily, keepMonthly: keepMonthly) where old != name {
            do { try await destination.delete(old); pruned.append(old) } catch { failures += 1 }
        }
        return Outcome(name: name, bytes: sealed.count, pruned: pruned, pruneFailures: failures)
    }

    /// The backups at a destination, newest first — ours only.
    public static func available(at destination: any OffsiteDestination) async throws -> [Entry] {
        try await destination.list()
            .filter { day(of: $0.name) != nil }
            .sorted { (day(of: $0.name) ?? "") > (day(of: $1.name) ?? "") }
    }

    /// Download one and open it: the book's bytes, ready for the app's restore.
    public static func fetch(_ name: String, from destination: any OffsiteDestination,
                             dek: Data?) async throws -> Data {
        guard dek != nil else { throw Failure.noKey }
        guard day(of: name) != nil else { throw Failure.notABackup }
        guard let sealed = try await destination.get(name) else { throw Failure.missing(name) }
        return try open(sealed, dek: dek)
    }

    // MARK: - Status

    /// When the last backup went off this Mac, and how long it has been
    /// failing. Kept by the app between launches.
    public struct Status: Codable, Sendable, Equatable {
        public var lastAt: Date?
        public var lastBytes: Int?
        public var lastName: String?
        /// The first failure since the last success; nil while all is well.
        public var failingSince: Date?
        public var lastError: String?

        public init(lastAt: Date? = nil, lastBytes: Int? = nil, lastName: String? = nil,
                    failingSince: Date? = nil, lastError: String? = nil) {
            self.lastAt = lastAt; self.lastBytes = lastBytes; self.lastName = lastName
            self.failingSince = failingSince; self.lastError = lastError
        }

        public func succeeded(_ outcome: Outcome, at now: Date) -> Status {
            Status(lastAt: now, lastBytes: outcome.bytes, lastName: outcome.name,
                   failingSince: nil, lastError: nil)
        }

        /// A failure keeps the FIRST failure's time, so "failing for two days"
        /// counts from when it started, not from the latest retry.
        public func failed(_ why: String, at now: Date) -> Status {
            var next = self
            next.failingSince = failingSince ?? now
            next.lastError = why
            return next
        }
    }

    /// A day, in seconds. Scheduling, not the calendar: "older than 24 hours".
    public static let oneDay: TimeInterval = 24 * 60 * 60

    /// Is a backup due? When there has never been one, or the last is at
    /// least a day old.
    public static func isDue(_ status: Status, now: Date) -> Bool {
        guard let last = status.lastAt else { return true }
        return now.timeIntervalSince(last) >= oneDay
    }

    /// Should the shop be told? When it has been failing for more than two days.
    public static func isOverdue(_ status: Status, now: Date, after: TimeInterval = 2 * oneDay) -> Bool {
        guard let since = status.failingSince else { return false }
        return now.timeIntervalSince(since) > after
    }

    /// One backup at a destination.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let bytes: Int
        public let modified: Date?
        public init(name: String, bytes: Int, modified: Date?) {
            self.name = name; self.bytes = bytes; self.modified = modified
        }
        public var day: String? { OffsiteBackup.day(of: name) }
    }
}

/// Somewhere a backup can be put. Four calls over plain names — the
/// destination decides where under itself a name lives.
public protocol OffsiteDestination: Sendable {
    func put(_ name: String, data: Data) async throws
    /// The bytes, or nil when there is nothing by that name.
    func get(_ name: String) async throws -> Data?
    /// Everything in the backups folder — the caller filters for ours.
    func list() async throws -> [OffsiteBackup.Entry]
    func delete(_ name: String) async throws
}

/// A bucket — the print library's own, under `[prefix]/khayt-offsite-backups/`.
public struct BucketDestination: OffsiteDestination {
    public let config: S3Config
    public let fetch: S3.Fetch
    public init(config: S3Config, fetch: @escaping S3.Fetch) { self.config = config; self.fetch = fetch }

    private func key(_ name: String) -> String { OffsiteBackup.key(prefix: config.prefix, name: name) }

    public func put(_ name: String, data: Data) async throws { try await S3.put(config, key: key(name), data: data, fetch: fetch) }
    public func get(_ name: String) async throws -> Data? { try await S3.get(config, key: key(name), fetch: fetch) }
    public func delete(_ name: String) async throws { try await S3.delete(config, key: key(name), fetch: fetch) }
    public func list() async throws -> [OffsiteBackup.Entry] {
        let folder = OffsiteBackup.keyFolder(prefix: config.prefix) + "/"
        return try await S3.list(config, prefix: folder, fetch: fetch).compactMap { item in
            let name = String(item.key.dropFirst(folder.count))
            guard item.key.hasPrefix(folder), !name.isEmpty, !name.contains("/") else { return nil }
            return OffsiteBackup.Entry(name: name, bytes: item.size, modified: item.modified)
        }
    }
}

/// Google Drive — the library's app folder, each file tagged with its key.
public struct DriveDestination: OffsiteDestination {
    public let client: DriveClient
    public let prefix: String
    public init(client: DriveClient, prefix: String) { self.client = client; self.prefix = prefix }

    private func key(_ name: String) -> String { OffsiteBackup.key(prefix: prefix, name: name) }

    public func put(_ name: String, data: Data) async throws { try await client.put(key(name), data: data) }
    public func get(_ name: String) async throws -> Data? { try await client.get(key(name)) }
    public func delete(_ name: String) async throws { try await client.delete(key(name)) }
    public func list() async throws -> [OffsiteBackup.Entry] {
        let folder = OffsiteBackup.keyFolder(prefix: prefix) + "/"
        return try await client.list(keyPrefix: folder, nameContains: OffsiteBackup.stem).map {
            OffsiteBackup.Entry(name: String($0.key.dropFirst(folder.count)), bytes: $0.size, modified: $0.modified)
        }
    }
}

/// A folder on this Mac that something else carries away — iCloud Drive,
/// Dropbox, a network share. Written atomically, so a sync client never
/// uploads half a file.
public struct FolderDestination: OffsiteDestination {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// The same basename-only rule `Restore` uses: a name with `../` in it
    /// never reaches outside the folder.
    private func url(_ name: String) -> URL {
        root.appending(path: URL(fileURLWithPath: name).lastPathComponent)
    }

    public func put(_ name: String, data: Data) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url(name), options: .atomic)
    }
    /// iCloud Drive keeps a file it has not downloaded yet as
    /// `.<name>.icloud`. On a new Mac that is every backup, so it is asked for
    /// and waited on (briefly) rather than reported as missing.
    private func placeholder(_ name: String) -> URL {
        root.appending(path: "." + URL(fileURLWithPath: name).lastPathComponent + ".icloud")
    }

    public func get(_ name: String) async throws -> Data? {
        let fm = FileManager.default
        let target = url(name)
        if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: placeholder(name).path) {
            try? fm.startDownloadingUbiquitousItem(at: target)
            for _ in 0..<60 where !fm.fileExists(atPath: target.path) {
                try await Task.sleep(for: .seconds(1))
            }
        }
        guard fm.fileExists(atPath: target.path) else { return nil }
        return try Data(contentsOf: target)
    }
    public func delete(_ name: String) async throws {
        let fm = FileManager.default
        for target in [url(name), placeholder(name)] where fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
    }
    public func list() async throws -> [OffsiteBackup.Entry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: root.path).compactMap { file in
            guard let attrs = try? fm.attributesOfItem(atPath: root.appending(path: file).path) else { return nil }
            // A not-yet-downloaded iCloud file lists under its real name; its
            // size is the placeholder's, which is the best there is until then.
            var name = file
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            return OffsiteBackup.Entry(name: name, bytes: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                                       modified: attrs[.modificationDate] as? Date)
        }
    }
}
