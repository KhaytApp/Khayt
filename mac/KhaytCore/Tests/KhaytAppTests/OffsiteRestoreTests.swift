import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Bringing an off-site backup back: download, decrypt, and hand it to the ONE
/// restore path, which validates it and copies the book first. Every step
/// runs against a temp book and an in-memory destination.
@MainActor
struct OffsiteRestoreTests {

    actor Shelf: OffsiteDestination {
        var files: [String: Data] = [:]
        func put(_ name: String, data: Data) async throws { files[name] = data }
        func get(_ name: String) async throws -> Data? { files[name] }
        func list() async throws -> [OffsiteBackup.Entry] {
            files.map { OffsiteBackup.Entry(name: $0.key, bytes: $0.value.count, modified: nil) }
        }
        func delete(_ name: String) async throws { files[name] = nil }
    }

    static let dek = Data((0..<32).map { UInt8(255 - $0) })

    /// Restore through the same seam `RestoreTests` uses, recording what the
    /// restore was handed and whether it took the safety copy.
    static func restore(_ book: Data, name: String, bench b: RestoreTests.Bench,
                        handed: inout URL?, copies: inout Int) async throws {
        var seenFile: URL?
        var taken = 0
        let engine = try KhaytEngine()
        try await OffsiteBackupState.restore(book: book, named: name) { file in
            seenFile = file
            return try await Restore.restore(
                backup: file, storeURL: b.store,
                owns: { true }, whoHasIt: { nil },
                protect: {
                    taken += 1
                    try Data(contentsOf: b.store).write(to: b.dir.appending(path: "safety-\(taken).json"))
                },
                forgetCloudView: {}, engine: engine)
        }
        handed = seenFile
        copies = taken
    }

    @Test("an off-site backup comes down, opens with the key, and replaces the book after a safety copy")
    func restoresThroughTheOnePath() async throws {
        let b = try RestoreTests.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.store)

        // Last night's backup, as the Mac sent it.
        let shelf = Shelf()
        let backup = Data(RestoreTests.electronBackup.utf8)
        let sent = try await OffsiteBackup.run(book: backup, dek: Self.dek, day: "2026-09-03",
                                               createdAt: "2026-09-03T01:00:00Z", to: shelf)

        let listed = try await OffsiteBackup.available(at: shelf)
        #expect(listed.map(\.name) == [sent.name])
        let book = try await OffsiteBackup.fetch(sent.name, from: shelf, dek: Self.dek)
        #expect(book == backup)

        var handed: URL?
        var copies = 0
        try await Self.restore(book, name: sent.name, bench: b, handed: &handed, copies: &copies)

        #expect(copies == 1, "the book was replaced without a safety copy")
        #expect(try Data(contentsOf: b.dir.appending(path: "safety-1.json")) == before)
        let after = try RestoreTests.read(b.store)
        #expect(after["clients"] == .array([.object(["id": .string("C-1"), "nameEn": .string("Aisha")])]))
        // What an off-site copy cannot carry is carried forward, as for any restore.
        guard case .object(let settings)? = after["settings"], case .object(let tg)? = settings["telegram"] else {
            Issue.record("shape"); return
        }
        #expect(tg["botToken"] == .string("__enc__TOKEN"))
        // The decrypted book never outlives the restore.
        let file = try #require(handed)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the plain-text book was left in a temp folder")
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test("the wrong key restores nothing")
    func wrongKeyRestoresNothing() async throws {
        let b = try RestoreTests.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.store)
        let shelf = Shelf()
        let sent = try await OffsiteBackup.run(book: Data(RestoreTests.electronBackup.utf8), dek: Self.dek,
                                               day: "2026-09-03", createdAt: "x", to: shelf)
        var other = Self.dek
        other[5] ^= 1
        await #expect(throws: OffsiteBackup.Failure.wrongKey) {
            _ = try await OffsiteBackup.fetch(sent.name, from: shelf, dek: other)
        }
        await #expect(throws: OffsiteBackup.Failure.noKey) {
            _ = try await OffsiteBackup.fetch(sent.name, from: shelf, dek: nil)
        }
        #expect(try Data(contentsOf: b.store) == before)
    }

    @Test("a decrypted file that is not a Khayt book is refused by Restore, and the book is untouched")
    func strangerIsRefused() async throws {
        let b = try RestoreTests.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.store)
        var handed: URL?
        var copies = 0
        await #expect(throws: Restore.Refusal.self) {
            try await Self.restore(Data(#"{"name":"khayt","scripts":{}}"#.utf8), name: "khayt-book-2026-09-03.khaytbak",
                                   bench: b, handed: &handed, copies: &copies)
        }
        #expect(try Data(contentsOf: b.store) == before)
    }

    // MARK: - This Mac's settings

    @Test("settings and status are kept per Mac, and the notice waits for two days of failing")
    func stateIsKept() throws {
        let suite = "khayt-offsite-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = OffsiteBackupState(defaults: defaults)
        #expect(first.settings.enabled == false, "an off-site backup switched itself on")
        first.settings = .init(enabled: true, destination: .bucket, folderPath: "")
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        first.status = first.status.failed("offline", at: t0)

        let again = OffsiteBackupState(defaults: defaults)
        #expect(again.settings == first.settings)
        #expect(again.status.failingSince == t0)
        #expect(!again.overdue(now: t0.addingTimeInterval(86_400)))
        #expect(again.overdue(now: t0.addingTimeInterval(3 * 86_400)))
        again.noticeDismissed = true
        #expect(!again.overdue(now: t0.addingTimeInterval(3 * 86_400)))
        again.noticeDismissed = false
        again.settings.enabled = false
        #expect(!again.overdue(now: t0.addingTimeInterval(3 * 86_400)), "a switched-off backup nagged")
    }
}
