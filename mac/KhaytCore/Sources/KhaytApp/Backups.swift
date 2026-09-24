import Foundation
import KhaytCore

/// The shop's daily backup.
///
/// A shop running only this app had none at all. Khayt writes one a day into
/// `Application Support/<build>/backups/YYYY-MM-DD.json` and keeps the most
/// recent thirty; this writes the same file, in the same place, with the same
/// name and the same rotation, so the two apps keep one set of backups between
/// them rather than two that each know half the days.
///
/// THE FILE IS A COPY OF THE STORE, BYTE FOR BYTE.
///
/// Khayt builds its backup by re-encrypting the store it holds in memory,
/// because the renderer holds those thirty fields decrypted. This app never
/// decrypts anything — the secrets on disk are already `__enc__` — so copying
/// the file produces exactly the artifact Khayt's own restore expects, and
/// does it without ever holding a shop's credentials in memory.
@MainActor
enum Backups {

    /// Where the day's backups live, beside the store.
    static func directory(for build: StoreReader.Build) -> URL {
        build.storeURL.deletingLastPathComponent().appending(path: "backups")
    }

    /// The name Khayt gives a day's backup: the date, and nothing else, so the
    /// second launch of a day overwrites the first rather than making two.
    static func filename(for day: Date = Date()) -> String {
        Shop.today(day) + ".json"
    }

    /// The most recent dated backup, or nil when a shop has none.
    static func lastBackupDay(in directory: URL) -> String? {
        dated(in: directory).last.map { String($0.dropLast(5)) }
    }

    /// Every `YYYY-MM-DD.json` in the folder, oldest first.
    ///
    /// ONLY those. The folder also holds a shop's insurance — the copies taken
    /// before a schema migration or an app update — and they are not days. The
    /// first version of this returned every `.json`, so "when was the last
    /// backup" answered `pre-update-v3.7.0-beta.8-2026-08-27`.
    static func dated(in directory: URL) -> [String] {
        all(in: directory).filter {
            $0.dropLast(5).range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil
        }
    }

    /// Every backup file, whatever kind. Rotation needs all of them, because
    /// which are protected is `lib/upgrade-backup.js`'s answer and not this
    /// app's — it knows about two prefixes, and knowing about one was a bug.
    static func all(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    /// Write today's backup if there is not one, and rotate what is there.
    ///
    /// Returns the file written, or nil when today's already exists — a shop
    /// that opens the app four times in a day gets one backup, not four.
    /// Never writes for the sample shop: it is not a book anybody would want
    /// back.
    @discardableResult
    static func writeDaily(for build: StoreReader.Build, engine: KhaytEngine?,
                           now: Date = Date(), keep: Int = 30) async throws -> URL? {
        let directory = Self.directory(for: build)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = filename(for: now)
        let target = directory.appending(path: name)
        // Today's is already there. Khayt's own writer overwrites; this leaves
        // it, because the earliest copy of a day is the one taken before
        // whatever the shop did next.
        if FileManager.default.fileExists(atPath: target.path) { return nil }

        let data = try Data(contentsOf: build.storeURL)
        // Straight to the file, not through a decode: a backup that cannot be
        // read back byte for byte is not a backup, and re-encoding would
        // reorder keys and re-format numbers for no gain.
        try data.write(to: target, options: .atomic)

        try await rotate(directory: directory, engine: engine, keep: keep)
        return target
    }

    /// Take a backup right now, whatever is already there for today.
    ///
    /// Named `YYYY-MM-DD-HHMM.json` rather than overwriting the day's file:
    /// the automatic copy was taken before whatever the shop did this morning,
    /// and a shop asking for one now wants to keep BOTH sides of that.
    @discardableResult
    static func writeNow(for build: StoreReader.Build, engine: KhaytEngine?,
                         now: Date = Date(), keep: Int = 30, except: [String] = []) async throws -> URL {
        let directory = Self.directory(for: build)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "HHmm"
        let target = directory.appending(path: Shop.today(now) + "-" + stamp.string(from: now) + ".json")
        try Data(contentsOf: build.storeURL).write(to: target, options: .atomic)
        try await rotate(directory: directory, engine: engine, keep: keep, except: except)
        return target
    }

    /// Delete the backups the shared rule says to: the dailies and the
    /// snapshots each keep their own newest set, so a day of cloud snapshots
    /// can no longer push the last month of daily backups out. Protected
    /// (pre-upgrade) backups and anything in `except` are never deleted.
    /// `lib/upgrade-backup.js backupsToDelete` decides, for both apps.
    static func rotate(directory: URL, engine: KhaytEngine?, keep: Int, except: [String] = []) async throws {
        guard let engine else { return }
        for name in try await engine.backupsToDelete(all(in: directory), except: except) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
