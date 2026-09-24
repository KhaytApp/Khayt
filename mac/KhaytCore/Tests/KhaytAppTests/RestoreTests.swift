import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Putting a backup back.
///
/// A restore replaces a shop's entire book, so what is tested here is mostly
/// what it REFUSES to do, and what it carries forward that a backup could not
/// have held. Every one of these runs against a store in a temp directory: a
/// destructive write path whose only trial run was on a shop's live book has
/// not been tested, it has been risked.
@MainActor
struct RestoreTests {

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store as this app finds one: secrets already `__enc__`, and carrying
    /// the printer completion history the main process owns.
    static let book = """
    {"version":10,
     "printLog":[{"id":"P-1","rev":3}],
     "clients":[],
     "machines":[{"id":"M-1","name":"Bench","printerApi":{"apiKey":"__enc__REAL","accessCode":"__enc__CODE"}}],
     "settings":{"bizEn":"The Shop","telegram":{"botToken":"__enc__TOKEN"},"cloud":{"token":"__enc__CLOUD"}},
     "printerCompletions":{"PRN-1":{"completions":[{"at":1,"filename":"bracket.gcode"}]}}}
    """

    /// A backup as KHAYT writes one: the renderer's export payload, so the
    /// credentials are masks and there is no `printerCompletions` at all.
    static let electronBackup = """
    {"version":10,"exportedAt":"2026-09-03T10:00:00.000Z",
     "printLog":[{"id":"P-1","rev":2},{"id":"P-2","rev":1}],
     "clients":[{"id":"C-1","nameEn":"Aisha"}],
     "machines":[{"id":"M-1","name":"Bench","printerApi":{"apiKey":"__KHAYT_MASKED__","accessCode":"__KHAYT_MASKED__"}}],
     "settings":{"bizEn":"The Shop","telegram":{"botToken":"__KHAYT_MASKED__"},"cloud":{"token":"__KHAYT_MASKED__"}}}
    """

    struct Bench {
        let dir: URL
        let store: URL
        let backup: URL
        var owns = true
    }

    static func bench(book: String = RestoreTests.book,
                      backup: String = RestoreTests.electronBackup) throws -> Bench {
        let dir = try tempDir()
        let store = dir.appending(path: "khayt-store.json")
        try Data(book.utf8).write(to: store)
        let backups = dir.appending(path: "backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let file = backups.appending(path: "2026-09-03.json")
        try Data(backup.utf8).write(to: file)
        return Bench(dir: dir, store: store, backup: file)
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    /// Run a restore with the platform pieces stubbed out.
    @discardableResult
    static func run(_ b: Bench, owns: Bool = true, protectFails: Bool = false,
                    forgot: (() -> Void)? = nil) async throws -> URL? {
        var copies = 0
        return try await Restore.restore(
            backup: b.backup, storeURL: b.store,
            owns: { owns },
            whoHasIt: { "Khayt is running" },
            protect: {
                if protectFails { throw Restore.Refusal.unreadable("disk full") }
                copies += 1
                try Data(contentsOf: b.store).write(to: b.dir.appending(path: "safety-\(copies).json"))
            },
            forgetCloudView: { forgot?() },
            engine: try KhaytEngine())
    }

    // MARK: - What it refuses

    @Test("a file that is not a Khayt store is refused, and the book is untouched")
    func refusesAStranger() async throws {
        // The renderer's own restore refused a FALSY snapshot and nothing else,
        // so picking a package.json in Settings → Import zeroed all thirty-one
        // collections and toasted success. `looksLikeStore` is that lesson.
        let b = try Self.bench(backup: #"{"name":"khayt","version":"3.7.0","scripts":{}}"#)
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.store)

        await #expect(throws: Restore.Refusal.self) { try await Self.run(b) }
        #expect(try Data(contentsOf: b.store) == before, "the book was replaced by a file that was never ours")
    }

    @Test("a restore keeps THIS Mac's slicer, and a masked ntfy topic or webhook URL keeps this Mac's value")
    func keepsWhatIsThisMacs() async throws {
        let book = #"""
        {"version":10,"printLog":[],"clients":[],
         "settings":{"bizEn":"The Shop","slicers":[{"id":"s1","path":"/Applications/PrusaSlicer.app","args":"--export-gcode"}],
                     "ntfy":{"topic":"khayt-realtopic"},
                     "webhooks":{"subscriptions":[{"id":"w1","url":"https://hooks.example/secret-path"}]}}}
        """#
        let backup = #"""
        {"version":10,"printLog":[{"id":"P-1","rev":1}],"clients":[],
         "settings":{"bizEn":"The Shop","slicers":[{"id":"evil","path":"/Applications/PrusaSlicer.app","args":"--post-process /tmp/x.sh"}],
                     "ntfy":{"topic":"__KHAYT_MASKED__"},
                     "webhooks":{"subscriptions":[{"id":"w1","url":"__KHAYT_MASKED__"}]}}}
        """#
        let b = try Self.bench(book: book, backup: backup)
        defer { try? FileManager.default.removeItem(at: b.dir) }
        try await Self.run(b)
        let after = try Self.read(b.store)
        guard case .object(let settings)? = after["settings"] else { Issue.record("no settings"); return }
        #expect(settings["slicers"] == .array([.object(["id": .string("s1"), "path": .string("/Applications/PrusaSlicer.app"),
                                                       "args": .string("--export-gcode")])]),
                "a restored book chose the program this Mac runs")
        guard case .object(let ntfy)? = settings["ntfy"], case .object(let hooks)? = settings["webhooks"],
              case .array(let subs)? = hooks["subscriptions"], case .object(let sub)? = subs.first else {
            Issue.record("shape"); return
        }
        #expect(ntfy["topic"] == .string("khayt-realtopic"))
        #expect(sub["url"] == .string("https://hooks.example/secret-path"))
        #expect(after["printLog"] == .array([.object(["id": .string("P-1"), "rev": .number(1)])]), "the rest WAS restored")
    }

    @Test("the phone and the cloud never see the ntfy topic or a webhook URL")
    func devicePrivateIsMasked() async throws {
        let engine = try KhaytEngine()
        let masked = try await engine.storeForCloud([
            "settings": .object(["ntfy": .object(["topic": .string("khayt-realtopic")]),
                                 "webhooks": .object(["subscriptions": .array([.object(["id": .string("w1"),
                                                                                        "url": .string("https://hooks.example/x")])])])]),
        ])
        guard case .object(let settings)? = masked["settings"], case .object(let ntfy)? = settings["ntfy"],
              case .object(let hooks)? = settings["webhooks"], case .array(let subs)? = hooks["subscriptions"],
              case .object(let sub)? = subs.first else { Issue.record("shape"); return }
        #expect(ntfy["topic"] != .string("khayt-realtopic"))
        #expect(sub["url"] != .string("https://hooks.example/x"))
    }

    @Test("a damaged backup is refused, and the book is untouched")
    func refusesDamage() async throws {
        // Recognisably ours, but a collection is a string — a truncated or
        // hand-edited file. The shop wants to be told, not salvaged.
        let b = try Self.bench(backup: #"{"settings":{"bizEn":"The Shop"},"printLog":"oops"}"#)
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.store)

        await #expect(throws: Restore.Refusal.self) { try await Self.run(b) }
        #expect(try Data(contentsOf: b.store) == before)
    }

    @Test("a restore we do not own the book for is refused")
    func refusesWhenElectronHasIt() async throws {
        let b = try Self.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.store)

        await #expect(throws: Restore.Refusal.self) { try await Self.run(b, owns: false) }
        #expect(try Data(contentsOf: b.store) == before)
    }

    @Test("a restore that cannot copy the book first does not happen")
    func refusesWithoutASafetyCopy() async throws {
        // A restore you cannot undo is a second way to lose a shop's data.
        let b = try Self.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.store)

        await #expect(throws: Restore.Refusal.self) { try await Self.run(b, protectFails: true) }
        #expect(try Data(contentsOf: b.store) == before)
    }

    @Test("the book is copied before it is replaced")
    func copiesFirst() async throws {
        let b = try Self.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.store)

        try await Self.run(b)
        let safety = b.dir.appending(path: "safety-1.json")
        #expect(FileManager.default.fileExists(atPath: safety.path))
        #expect(try Data(contentsOf: safety) == before, "the copy is not the book that was replaced")
    }

    // MARK: - What a backup does not carry

    @Test("a Khayt backup does not write masks over the shop's credentials")
    func credentialsSurvive() async throws {
        // THE BUG THIS EXISTS FOR. Khayt builds its backup from the renderer's
        // export payload, and the renderer only ever holds `__KHAYT_MASKED__`
        // — main masks on the way out and merges the real values back on every
        // save. A plain copy here would write the mask over the printer's API
        // key, its LAN access code, the Telegram token and the cloud token, and
        // the only symptom would be printers that stopped answering.
        let b = try Self.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }

        try await Self.run(b)
        let after = try Self.read(b.store)

        #expect(Restore.value(at: ["settings", "telegram", "botToken"], in: after) == .string("__enc__TOKEN"))
        #expect(Restore.value(at: ["settings", "cloud", "token"], in: after) == .string("__enc__CLOUD"))
        guard case .array(let machines)? = after["machines"], case .object(let m) = machines[0] else {
            Issue.record("machines did not survive"); return
        }
        #expect(Restore.value(at: ["printerApi", "apiKey"], in: m) == .string("__enc__REAL"))
        #expect(Restore.value(at: ["printerApi", "accessCode"], in: m) == .string("__enc__CODE"))
    }

    @Test("the printer completion history survives a restore")
    func mainOwnedKeysSurvive() async throws {
        // `printerCompletions` is written by the poll timer in the main process
        // and dropped by `normalizeStoreSnapshot`, so it is in no Khayt backup.
        // Deleting it is #900 arriving through a new door: a finished job's real
        // filament weight and duration, gone.
        let b = try Self.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }

        try await Self.run(b)
        let after = try Self.read(b.store)
        #expect(Restore.value(at: ["printerCompletions", "PRN-1"], in: after) != nil)
    }

    @Test("the backup's own records are what is restored")
    func recordsAreTheBackups() async throws {
        let b = try Self.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }

        try await Self.run(b)
        let after = try Self.read(b.store)
        guard case .array(let jobs)? = after["printLog"] else { Issue.record("no printLog"); return }
        #expect(jobs.count == 2, "the book's records were kept instead of the backup's")
        guard case .array(let clients)? = after["clients"] else { Issue.record("no clients"); return }
        #expect(clients.count == 1)
    }

    @Test("a backup that really holds a secret keeps its own")
    func aMacBackupKeepsItsSecrets() async throws {
        // This app's own backups are byte copies of the store, so their secrets
        // are real `__enc__` values from the day they were taken — and those are
        // the ones a shop asked for. Nothing is carried forward over them.
        let mac = Self.book.replacingOccurrences(of: "__enc__TOKEN", with: "__enc__OLDTOKEN")
        let b = try Self.bench(backup: mac)
        defer { try? FileManager.default.removeItem(at: b.dir) }

        try await Self.run(b)
        let after = try Self.read(b.store)
        #expect(Restore.value(at: ["settings", "telegram", "botToken"], in: after) == .string("__enc__OLDTOKEN"))
    }

    @Test("a machine's credentials are matched by id, never by position")
    func machinesMatchById() async throws {
        // By index, adding a machine since the backup would hand one printer's
        // access code to another — which is worse than losing it.
        let book = """
        {"printLog":[],"settings":{},
         "machines":[{"id":"M-NEW","printerApi":{"apiKey":"__enc__NEW"}},
                     {"id":"M-1","printerApi":{"apiKey":"__enc__REAL"}}]}
        """
        let backup = """
        {"printLog":[],"settings":{},
         "machines":[{"id":"M-1","printerApi":{"apiKey":"__KHAYT_MASKED__"}}]}
        """
        let b = try Self.bench(book: book, backup: backup)
        defer { try? FileManager.default.removeItem(at: b.dir) }

        try await Self.run(b)
        let after = try Self.read(b.store)
        guard case .array(let machines)? = after["machines"], case .object(let m) = machines[0] else {
            Issue.record("machines did not survive"); return
        }
        #expect(Restore.value(at: ["printerApi", "apiKey"], in: m) == .string("__enc__REAL"))
    }

    @Test("a store with no bnpl does not grow one just because it was walked")
    func doesNotInventBranches() async throws {
        let b = try Self.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }

        try await Self.run(b)
        let after = try Self.read(b.store)
        #expect(Restore.value(at: ["settings", "bnpl"], in: after) == nil)
    }

    // MARK: - The cloud

    @Test("the retained server view is forgotten")
    func forgetsTheCloudView() async throws {
        // A restore moves local state backwards. If the view the last session
        // left on disk survives it, the next push ships every rolled-back
        // record — or worse, a full blob the server accepts, which every other
        // device then pulls down. Nothing says anything.
        let b = try Self.bench()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        var forgotten = false

        try await Self.run(b, forgot: { forgotten = true })
        #expect(forgotten, "the cloud was left believing the server view still describes this book")
    }

    @Test("forgetting the view deletes the file and leaves the rest alone")
    func deletesOnlyTheViewFiles() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appending(path: "cloud-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cache.appending(path: "cloud-view-abc123.json"))
        try Data("{}".utf8).write(to: cache.appending(path: "something-else.json"))

        Restore.forgetCloudViewFiles(in: cache)

        #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "cloud-view-abc123.json").path))
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "something-else.json").path))
    }

    // MARK: - Choosing one

    @Test("the shelf is newest first, and an empty file is not offered")
    func listsWhatIsWorthChoosing() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appending(path: "2026-09-01.json"))
        try Data("{}".utf8).write(to: dir.appending(path: "pre-update-v3.7.0-2026-09-02.json"))
        // A failed write, not a choice.
        try Data("".utf8).write(to: dir.appending(path: "2026-09-03.json"))
        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later],
            ofItemAtPath: dir.appending(path: "pre-update-v3.7.0-2026-09-02.json").path)

        let shelf = Restore.list(in: dir)
        #expect(shelf.map(\.filename) == ["pre-update-v3.7.0-2026-09-02.json", "2026-09-01.json"])
        #expect(shelf[0].isInsurance, "the copy taken before an update is the one a shop usually wants")
        #expect(!shelf[1].isInsurance)
    }

    @Test("a copy taken before a reset is protected too, and says so rather than 'before an update'")
    func beforeAWipe() {
        #expect(Restore.Insurance.of("pre-wipe-2026-09-24T15-00-00-000Z.json") == .wipe)
        #expect(Restore.Insurance.of("pre-update-v3.7.0-2026-09-02.json") == .update)
        #expect(Restore.Insurance.of("pre-upgrade-v1-to-v2-x.json") == .update)
        #expect(Restore.Insurance.of("2026-09-24.json") == nil)
        #expect(Restore.Insurance.of("snap-2026-09-24-1200.json") == nil)
    }

    @Test("a filename cannot name a file outside the backups folder")
    func refusesAPathTraversal() throws {
        // The only thing a restore takes is a filename. `../khayt-store.json`
        // would otherwise name the very book being replaced, and a store is not
        // a backup: it carries `printerCompletions` and encrypted secrets, so
        // restoring one over itself is at best a no-op and at worst a way to
        // reach a file the shop never chose.
        let dir = URL(fileURLWithPath: "/tmp/khayt/backups")
        #expect(Restore.backupURL(named: "../khayt-store.json", in: dir).path
                == "/tmp/khayt/backups/khayt-store.json")
        #expect(Restore.backupURL(named: "/etc/passwd", in: dir).path
                == "/tmp/khayt/backups/passwd")
        #expect(Restore.backupURL(named: "2026-09-03.json", in: dir).path
                == "/tmp/khayt/backups/2026-09-03.json")
    }
}
