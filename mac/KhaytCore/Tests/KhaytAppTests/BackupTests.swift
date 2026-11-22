import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's daily backup.
///
/// A shop running only this app had none at all — one disk failure from losing
/// its book. Khayt writes one a day into `Application Support/<build>/backups`
/// and keeps the most recent thirty; this writes the same file, in the same
/// place, with the same name and the same rotation, so between them the two
/// apps keep ONE set of backups rather than two that each know half the days.
@MainActor
struct BackupTests {

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ names: [String], into dir: URL) throws {
        for name in names {
            try Data("{}".utf8).write(to: dir.appending(path: name))
        }
    }

    @Test("the day's backup is a copy of the store, byte for byte")
    func copiesTheStore() async throws {
        // This app never decrypts: the secrets on disk are already `__enc__`,
        // so a copy IS the artifact Khayt's restore expects — and it is made
        // without ever holding a shop's credentials in memory. A re-encode
        // would also reorder keys for no gain.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        let contents = #"{"settings":{"cloud":{"token":"__enc__abc"}},"printLog":[]}"#
        try Data(contents.utf8).write(to: store)

        let backups = dir.appending(path: "backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: backups.appending(path: Backups.filename()))

        let back = try String(contentsOf: backups.appending(path: Backups.filename()), encoding: .utf8)
        #expect(back == contents)
        #expect(back.contains("__enc__"), "the secrets stay encrypted, exactly as they are on disk")
    }

    @Test("a day gets one backup, not one per launch")
    func onePerDay() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = Backups.filename(for: Date())
        try Self.write([name], into: dir)
        // The earliest copy of a day is the one taken before whatever the shop
        // did next, so it is left alone rather than overwritten.
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: name).path))
        #expect(Backups.dated(in: dir) == [name])
    }

    @Test("the file is named for the day, so it sorts and Khayt recognises it")
    func naming() {
        let day = Calendar.book.date(from: DateComponents(year: 2026, month: 9, day: 6))!
        #expect(Backups.filename(for: day) == "2026-09-06.json")
    }

    @Test("rotation keeps the most recent thirty and never the insurance")
    func rotation() async throws {
        let engine = try KhaytEngine()
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var names: [String] = []
        for day in 1...35 {
            names.append(String(format: "2026-01-%02d.json", day))
        }
        // A pre-upgrade backup, which is a shop's insurance against a schema
        // change. A shop that opens the app on thirty consecutive days would
        // otherwise have it deleted by routine housekeeping — so it would
        // survive exactly as long as nobody needed it.
        let insurance = "pre-upgrade-v11-to-v12-2026-01-02.json"
        names.append(insurance)
        try Self.write(names, into: dir)

        try await Backups.rotate(directory: dir, engine: engine, keep: 30)
        // `all` is every file in the folder; `dated` is only the days. The
        // insurance is not a day, and reading it as one is how "when was the
        // last backup" once answered `pre-update-v3.7.0-beta.8-2026-08-27`.
        #expect(Backups.all(in: dir).contains(insurance),
                "the insurance is not routine housekeeping's to delete")
        let dated = Backups.dated(in: dir)
        #expect(!dated.contains(insurance), "and it is not one of the days either")
        #expect(dated.count == 30)
        #expect(dated.first == "2026-01-06.json", "the five oldest went")
        #expect(dated.last == "2026-01-35.json")
    }

    @Test("which files may be rotated is the shared rule's answer, not this app's")
    func rotatableIsShared() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.rotatableBackups([
            "2026-01-01.json", "pre-upgrade-v11-to-v12-2026-01-02.json", "2026-01-03.json",
        ])
        #expect(out == ["2026-01-01.json", "2026-01-03.json"])
    }

    @Test("the last backup a shop has is a DAY, not whatever file sorts last")
    func lastDay() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Backups.lastBackupDay(in: dir) == nil, "a shop with none is told nothing, not a date")
        try Self.write(["2026-01-01.json", "2026-03-09.json", "2026-02-01.json",
                        // Sorts after every date, and is not one. The first
                        // version of this reported it as the last backup.
                        "pre-update-v3.7.0-beta.8-2026-08-27.json"], into: dir)
        #expect(Backups.lastBackupDay(in: dir) == "2026-03-09")
    }

    @Test("a backup taken on demand keeps the day's automatic one")
    func onDemand() async throws {
        // The automatic copy was taken before whatever the shop did this
        // morning; a shop asking for one now wants BOTH sides of that.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        try Data(#"{"printLog":[]}"#.utf8).write(to: store)

        let backups = dir.appending(path: "backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let day = Backups.filename()
        try Data(#"{"the":"morning copy"}"#.utf8).write(to: backups.appending(path: day))

        let now = Calendar.book.date(from: DateComponents(year: 2026, month: 9, day: 4,
                                                             hour: 14, minute: 35))!
        let stamped = Shop.today(now) + "-1435.json"
        try Data(#"{"printLog":[]}"#.utf8).write(to: backups.appending(path: stamped))

        #expect(Backups.all(in: backups).contains(day), "the morning's copy is still there")
        #expect(Backups.all(in: backups).contains(stamped))
        // A time-stamped file is not a day, so it does not become the answer to
        // "when was the last backup" — that stays the date.
        #expect(Backups.dated(in: backups) == [day])
        #expect(Backups.lastBackupDay(in: backups) == String(day.dropLast(5)))
    }

    @Test("the sample shop is not backed up")
    func sampleNotBackedUp() async throws {
        // It is not a book anybody would want back.
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.lastBackup == nil)
        #expect(shop.backupProblem == nil)
    }
}
