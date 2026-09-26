import Foundation
import KhaytCore

/// The nightly off-site backup, as this Mac runs it.
///
/// `OffsiteBackup` in KhaytCore is the rule — the name, the sealing, the
/// proof, what to keep. This is the schedule, the settings and the words.
///
/// ── THE SETTINGS ARE THIS MAC'S, NOT THE BOOK'S ─────────────────────────
///
/// Kept in UserDefaults rather than `settings` in the book, on purpose:
///
/// * it is a JOB this Mac does. A book that syncs to a second Mac would carry
///   "back up nightly" there too, and two Macs would upload the same book to
///   the same place every night;
/// * a folder destination is a path on this disk, which means nothing on the
///   next Mac;
/// * and it keeps the August 2026 development leftover in
///   `settings.printLibrary.s3` from ever arming anything: nothing here turns
///   on by itself. The shop picks a destination; only then is the library's
///   bucket or Drive used, and its name is shown before anything is sent.
///
/// The CREDENTIALS are the library's, read from the book where the library
/// keeps them (sealed), so a shop that has set up online storage is not asked
/// for them twice.
@MainActor @Observable
final class OffsiteBackupState {

    enum Destination: String, Codable, CaseIterable, Sendable {
        case bucket, drive, folder
    }

    struct Settings: Codable, Equatable, Sendable {
        var enabled = false
        var destination: Destination = .folder
        var folderPath = ""
    }

    static let settingsKey = "offsite.settings"
    static let statusKey = "offsite.status"

    @ObservationIgnored let defaults: UserDefaults

    var settings: Settings {
        didSet { if settings != oldValue { Self.write(settings, Self.settingsKey, defaults) } }
    }
    var status: OffsiteBackup.Status {
        didSet { if status != oldValue { Self.write(status, Self.statusKey, defaults) } }
    }

    /// A backup or a restore is running.
    var busy = false
    /// What the last button press said.
    var note: String?
    var problem: String?
    /// The shop closed the "failing for two days" banner this session.
    var noticeDismissed = false

    @ObservationIgnored var timer: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Self.read(Settings.self, Self.settingsKey, defaults) ?? Settings()
        status = Self.read(OffsiteBackup.Status.self, Self.statusKey, defaults) ?? OffsiteBackup.Status()
    }

    private static func read<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private static func write<T: Encodable>(_ value: T, _ key: String, _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// Say so across the top of the window: switched on, and failing for
    /// more than two days.
    func overdue(now: Date = Date()) -> Bool {
        settings.enabled && !noticeDismissed && OffsiteBackup.isOverdue(status, now: now)
    }

    /// iCloud Drive's own folder on this Mac, with a folder for these in it.
    static var iCloudFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Khayt Backups")
    }

    // MARK: - Restoring, with the platform pieces passed in

    /// Put a downloaded, DECRYPTED book back through the one restore path.
    ///
    /// The bytes go to a private temporary file for exactly as long as the
    /// restore takes — `Restore` works on files, and giving it one is how
    /// this gets every refusal, the safety copy and the carrying forward of
    /// credentials without a second implementation of any of them. The file
    /// is the shop's book in plain text, so it is removed whatever happens.
    @discardableResult
    static func restore(book: Data, named name: String,
                        through restore: (URL) async throws -> URL?) async throws -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-offsite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "offsite-" + (OffsiteBackup.day(of: name) ?? "backup") + ".json")
        try book.write(to: file, options: .atomic)
        return try await restore(file)
    }
}

// MARK: - What the shop does with it

extension Shop {

    /// Why this Mac cannot seal a backup right now, or nil when it can.
    var offsiteKeyProblem: String? {
        if offsiteKey != nil { return nil }
        return words.callIt(Self.cloudConnected(settingsDict) ? "mac.offsite_needs_unlock" : "mac.offsite_needs_cloud")
    }

    /// Where the backup goes, opened for one use — or the sentence saying
    /// what is missing.
    func offsiteDestination() async -> Result<any OffsiteDestination, OffsiteNotReady> {
        switch offsite.settings.destination {
        case .bucket:
            guard let c = await CloudLibrary.libraryBucket(settings: settingsDict, build: source.build) else {
                return .failure(OffsiteNotReady(sentence: words.callIt("mac.offsite_bucket_missing")))
            }
            return .success(BucketDestination(config: c, fetch: CloudLibrary.fetch))
        case .drive:
            guard let d = await CloudLibrary.libraryDrive(settings: settingsDict, build: source.build) else {
                return .failure(OffsiteNotReady(sentence: words.callIt("mac.offsite_drive_missing")))
            }
            return .success(DriveDestination(client: DriveClient(d.config, fetch: CloudLibrary.fetch), prefix: d.prefix))
        case .folder:
            let path = offsite.settings.folderPath.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else {
                return .failure(OffsiteNotReady(sentence: words.callIt("mac.offsite_folder_missing")))
            }
            return .success(FolderDestination(root: URL(fileURLWithPath: path)))
        }
    }

    /// What the settings pane says about the destination: which bucket, or
    /// what to set up first. Named, so a shop can see exactly where its book
    /// would go before switching anything on.
    func offsiteDestinationSummary() async -> (ready: Bool, text: String) {
        switch offsite.settings.destination {
        case .bucket:
            guard let c = await CloudLibrary.libraryBucket(settings: settingsDict, build: source.build) else {
                return (false, words.callIt("mac.offsite_bucket_missing"))
            }
            let place = c.bucket + " · " + (URL(string: c.endpoint)?.host ?? c.endpoint)
            return (true, words.callIt("mac.offsite_bucket_uses", ["bucket": .string(place)]))
        case .drive:
            guard await CloudLibrary.libraryDrive(settings: settingsDict, build: source.build) != nil else {
                return (false, words.callIt("mac.offsite_drive_missing"))
            }
            return (true, words.callIt("mac.offsite_drive_uses"))
        case .folder:
            let path = offsite.settings.folderPath.trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? (false, words.callIt("mac.offsite_folder_missing")) : (true, path)
        }
    }

    /// The same failure, said to a shop.
    func offsiteSay(_ error: Error) -> String {
        if let refused = error as? OffsiteNotReady { return refused.sentence }
        if let f = error as? OffsiteBackup.Failure {
            switch f {
            case .noKey: return offsiteKeyProblem ?? words.callIt("mac.offsite_needs_cloud")
            case .wrongKey: return words.callIt("mac.offsite_wrong_key")
            case .readBackDiffers: return words.callIt("mac.offsite_read_back")
            default: return String(describing: f)
            }
        }
        return cloudSay(error)
    }

    /// Take the off-site backup. `automatic` is the timer: it does nothing
    /// unless the shop switched the backup on, and it says nothing on
    /// success — the settings line and, after two days of failing, the
    /// banner are where it speaks.
    func runOffsiteBackup(automatic: Bool = false) async {
        guard let build = source.build else {
            if !automatic { offsite.problem = words.callIt("mac.move_sample") }
            return
        }
        if automatic && !offsite.settings.enabled { return }
        guard !offsite.busy else { return }
        offsite.busy = true
        defer { offsite.busy = false }
        offsite.problem = nil
        offsite.note = nil
        let now = Date()
        do {
            // The key first: with no key there is no upload, and nothing else
            // is worth asking the destination.
            guard let dek = offsiteKey else { throw OffsiteBackup.Failure.noKey }
            let destination = try await offsiteDestination().get()
            let book = try await Task.detached { try Data(contentsOf: build.storeURL) }.value
            let outcome = try await OffsiteBackup.run(book: book, dek: dek, day: Shop.today(now),
                                                      createdAt: StoreWriter.iso(now), to: destination)
            offsite.status = offsite.status.succeeded(outcome, at: now)
            offsite.noticeDismissed = false
            if !automatic {
                offsite.note = words.callIt("mac.offsite_done", [
                    "name": .string(outcome.name),
                    "size": .string(ByteCountFormatter.string(fromByteCount: Int64(outcome.bytes), countStyle: .file))])
            }
        } catch {
            let why = offsiteSay(error)
            offsite.status = offsite.status.failed(why, at: now)
            offsite.problem = words.callIt("mac.offsite_failed") + " " + why
        }
    }

    /// Check hourly while the app is open, and once shortly after launch:
    /// a backup is taken whenever the last one is a day old.
    func startOffsiteBackups() {
        guard offsite.timer == nil else { return }
        offsite.timer = Task { [weak self] in
            // Not in the first seconds of a launch, which are the book's.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if let shop = self, shop.offsite.settings.enabled,
                   OffsiteBackup.isDue(shop.offsite.status, now: Date()) {
                    await shop.runOffsiteBackup(automatic: true)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func stopOffsiteBackups() {
        offsite.timer?.cancel()
        offsite.timer = nil
    }

    /// The backups at the destination, newest first.
    func offsiteBackups() async throws -> [OffsiteBackup.Entry] {
        try await OffsiteBackup.available(at: offsiteDestination().get())
    }

    /// Download one, decrypt it, and put it back through `Restore` — which
    /// validates it and copies the book as it stands before replacing it.
    /// True when the book was replaced.
    func restoreOffsite(_ entry: OffsiteBackup.Entry) async -> Bool {
        offsite.problem = nil
        offsite.note = nil
        guard let build = source.build else { offsite.problem = words.callIt("mac.move_sample"); return false }
        guard !offsite.busy else { return false }
        offsite.busy = true
        defer { offsite.busy = false }
        do {
            let destination = try await offsiteDestination().get()
            let book = try await OffsiteBackup.fetch(entry.name, from: destination, dek: offsiteKey)
            let engine = self.engine
            try await OffsiteBackupState.restore(book: book, named: entry.name) { file in
                try await Restore.restore(backup: file, for: build, engine: engine)
            }
            offsite.note = words.callIt("mac.offsite_restored", ["name": .string(entry.name)])
            await load(source)
            return true
        } catch {
            offsite.problem = words.callIt("mac.restore_failed") + " " + offsiteSay(error)
            return false
        }
    }
}

/// A destination that is not set up yet, in the shop's words.
struct OffsiteNotReady: Error {
    let sentence: String
}
