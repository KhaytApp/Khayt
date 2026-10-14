import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A book the size a real shop keeps: ten thousand models, ~15 MB of JSON.
///
/// Synthesised, never copied: the shop whose book prompted this keeps 9,802
/// models, and none of their names belong in a repository. The shape follows
/// that book — most records ~1.5 KB, a third carrying a print-risk histogram,
/// a few with an inline photo, a 700 KB logo and a 360 KB library block in
/// settings — because a fixture of small records times a different program.
enum PerfBook {
    static func synthesize(models count: Int = 10_000) -> [String: JSONValue] {
        var rows: [JSONValue] = []
        rows.reserveCapacity(count)
        let histogram = JSONValue.array((0..<64).map { .number(Double($0) * 13.37 + 0.123456789) })
        let photo = JSONValue.string("data:image/jpeg;base64," + String(repeating: "QUJD", count: 7_000))
        for i in 0..<count {
            let id = String(format: "pf%012d", i)
            let name = "Model \(i) part \(i % 97)"
            var r: [String: JSONValue] = [
                "id": .string(id), "name": .string(name), "originalName": .string(name + ".3mf"),
                "folder": .string(""), "group": .string(i % 12 == 0 ? "" : "Group \(i % 811)"),
                "tags": .array([.string("tag \(i % 23)")]), "colors": .array([]),
                "favorite": .bool(i % 50 == 0), "material": .string(""), "testedNotes": .string(""),
                "licence": .string(i % 44 == 0 ? "CC-BY" : ""), "source": .string(""),
                "swapCount": .number(0), "parsed": .object([:]),
                "createdAt": .number(1_750_000_000_000 + Double(i) * 1000),
                "updatedAt": .string("2026-09-20T10:00:00.000Z"),
                "geometryKey": .null, "contentHash": .null, "thumbFile": .null, "thumbSource": .null,
                "slicerProfileId": .null, "userPhoto": i % 450 == 0 ? photo : .string(""),
                "sourceFile": .object(["ext": .string("3mf"), "filename": .string(name + ".3mf"),
                                       "kind": .string("model"), "originalName": .string(name + ".3mf"),
                                       "size": .number(Double(100_000 + i))]),
            ]
            if i % 3 != 0 {
                r["externalPath"] = .string("/Volumes/Shop Drive/Library/Collection \(i % 811)/"
                                            + String(repeating: "sub folder/", count: 8) + name + ".3mf")
                r["autoGroup"] = .string("Collection \(i % 811)")
                r["indexedOnline"] = .string("2026-09-20T10:00:00.000Z")
            }
            if i % 5 < 3 { r["rev"] = .number(Double(i % 9 + 1)) }
            if i % 3 == 1 {
                r["printRisk"] = .object(["contentHash": .string(String(repeating: "c6", count: 32)),
                                          "analysis": .object(["triangleCount": .number(684_048),
                                                               "histogram": histogram,
                                                               "zMax": .number(84.25)])])
            }
            rows.append(.object(r))
        }
        let logo = JSONValue.string("data:image/png;base64," + String(repeating: "iVBO", count: 180_000))
        let pictureChecks = JSONValue.object(Dictionary(uniqueKeysWithValues: (0..<200).map {
            ("pf\($0)", JSONValue.string(String(repeating: "f", count: 1_700)))
        }))
        let settings: [String: JSONValue] = [
            "currency": .string("SAR"), "lang": .string("en"), "bizEn": .string("Perf Shop"),
            "bizLogo": logo,
            "printLibrary": .object(["pictureChecks": pictureChecks]),
        ]
        return ["version": .number(1), "printFiles": .array(rows), "settings": .object(settings),
                "printLog": .array([]), "inventory": .array([]), "clients": .array([]),
                "tombstones": .array([])]
    }

    /// Write `root` as the shipped build's book under a fresh temp support
    /// folder, and point the app at it.
    @MainActor
    static func install(_ root: [String: JSONValue]) throws -> URL {
        // Named like the real one, so a path another test checks while this
        // is set still reads `Application Support/khayt/`.
        let support = FileManager.default.temporaryDirectory
            .appending(path: "khayt-perf-\(UUID().uuidString)/Application Support")
        let folder = support.appending(path: StoreReader.Build.shipped.rawValue)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(root).write(to: folder.appending(path: "khayt-store.json"))
        StoreReader.Build.supportFolderForTests = support
        return support
    }
}

/// The longest the main thread went without servicing its queue.
///
/// A timer on the main queue every 2 ms: a gap between two firings is time the
/// main thread spent on something else — which, in the app, is a frozen window.
@MainActor
final class MainStallMeter {
    private var timer: DispatchSourceTimer?
    private var last: UInt64 = 0
    private(set) var worstMs: Double = 0

    func start() {
        last = DispatchTime.now().uptimeNanoseconds
        worstMs = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(2))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                self.worstMs = max(self.worstMs, Double(now - self.last) / 1e6)
                self.last = now
            }
        }
        t.resume()
        timer = t
    }

    /// Stop, after letting the queue drain once so a stall at the very end is
    /// counted.
    func stop() async -> Double {
        try? await Task.sleep(for: .milliseconds(10))
        timer?.cancel()
        timer = nil
        return worstMs
    }
}

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// Open `root` as a real book in a temp folder, run `body`, and put
/// everything back — the sample book loaded again stops the printers, the
/// cameras and the timers a real book starts, before the folder goes.
@MainActor
func withPerfBook(_ root: [String: JSONValue],
                  _ body: (Shop, URL) async throws -> Void) async throws {
    let support = try PerfBook.install(root)
    // Never into this Mac's own Spotlight from a test.
    let spotlight = UserDefaults.standard.object(forKey: Spotlight.defaultsKey)
    UserDefaults.standard.set(false, forKey: Spotlight.defaultsKey)
    let shop = Shop()
    do {
        await shop.load(.store(.shipped))
        try await body(shop, StoreReader.Build.shipped.storeURL)
    } catch {
        Issue.record(error)
    }
    await shop.settleLibraryWrites()
    await shop.load(.sample)
    StoreReader.Build.supportFolderForTests = nil
    UserDefaults.standard.set(spotlight, forKey: Spotlight.defaultsKey)
    try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
}

/// The book's `printFiles`, as on disk now.
func diskRows(_ url: URL) throws -> [JSONValue] {
    let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    if case .array(let rows)? = root["printFiles"] { return rows }
    return []
}

func diskIds(_ url: URL) throws -> Set<String> {
    Set(try diskRows(url).compactMap(Shop.recordId))
}

@MainActor
@Suite(.serialized)
struct LibraryEditPerfTests {

    /// How long one delete may hold the main thread at 10,000 models.
    ///
    /// Measured on a debug build (the one `swift test` runs): ~3,800 ms
    /// before — the whole book decoded, encoded and read back on the main
    /// thread — and ~100 ms after, the rest being the library's own chips
    /// recounted in Swift. 500 ms leaves a slow CI runner five times the
    /// room, and is still a seventh of what the freeze was.
    static let budgetMs = 500.0

    @Test("deleting one model from a 10,000-model book does not freeze the window")
    func deleteDoesNotFreeze() async throws {
        try await withPerfBook(PerfBook.synthesize()) { shop, url in
            #expect(shop.files.count == 10_000)
            let meter = MainStallMeter()
            // The best of three: another test sharing the main thread can
            // stall one run, but the freeze this guards against stalled
            // every one of them by seconds.
            var best = Double.infinity
            var gone: [String] = []
            for i in 0..<3 {
                let one = shop.files[i * 100]
                gone.append(one.id)
                meter.start()
                await shop.deleteLibraryFiles([one])
                best = min(best, await meter.stop())
                let drawn = shop.files.contains { $0.id == one.id }
                #expect(!drawn, "still on screen")
            }
            #expect(best < Self.budgetMs, "a delete held the main thread \(Int(best)) ms")
            let onDisk = try diskIds(url)
            #expect(onDisk.count == 9_997)
            #expect(onDisk.isDisjoint(with: gone), "a delete never reached the book")
            #expect(shop.files.count == 9_997)
            #expect(shop.libraryRows.count == 9_997)
        }
    }

    @Test("a delete leaves the screen at once, and the book when it is written")
    func deleteIsOptimisticThenWritten() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 40)) { shop, url in
            let doomed = Array(shop.files.prefix(3))
            let ids = Set(doomed.map(\.id))
            let write = Task { await shop.deleteLibraryFiles(doomed) }
            // The first hop is the Trash, off the main thread: by the time it
            // is under way the models are already off the screen.
            await Task.yield()
            let drawn = shop.files.contains { ids.contains($0.id) }
            #expect(!drawn, "still drawn while it is written")
            await write.value
            #expect(try diskIds(url).isDisjoint(with: ids))
            #expect(shop.files.count == 37)
            // One write, and its tombstones — or the next sync puts them back.
            let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
            let tombs = Shop.rows(root, "tombstones").compactMap { row -> String? in
                guard case .object(let t) = row, case .string(let id)? = t["id"] else { return nil }
                return id
            }
            #expect(ids.isSubset(of: Set(tombs)))
            // What is on screen is what is in the book.
            let written = try diskRows(url)
            #expect(shop.libraryRows == written)
        }
    }

    @Test("a favourite shows at once, lands in the book, and undoes and redoes")
    func favouriteRoundTrip() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 40)) { shop, url in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            let plain = shop.files.first { !$0.isFavourite }
            let file = try #require(plain)
            undo.beginUndoGrouping()
            shop.toggleFavourite(file)
            undo.endUndoGrouping()
            @MainActor func starred() -> Bool? { shop.files.first { $0.id == file.id }?.isFavourite }
            #expect(starred() == true, "the star waits for the write")
            await shop.settleLibraryWrites()
            func onDisk() throws -> [String: JSONValue]? {
                for case .object(let o) in try diskRows(url) where o["id"] == .string(file.id) { return o }
                return nil
            }
            #expect(try onDisk()?["favorite"] == .bool(true))
            let written = try diskRows(url)
            #expect(shop.libraryRows == written, "the screen and the book disagree")

            undo.undo()
            await shop.settleLibraryWrites()
            #expect(try onDisk()?["favorite"] == .bool(false), "undo did not reach the book")
            #expect(starred() == false)
            #expect(undo.canRedo, "the undo's redo went on the wrong stack")

            undo.redo()
            await shop.settleLibraryWrites()
            #expect(try onDisk()?["favorite"] == .bool(true), "redo did not reach the book")
            shop.undoManager = nil
        }
    }

    @Test("edits made faster than they are written all land, and stay on screen")
    func quickEditsInARow() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 30)) { shop, url in
            let chosen = Array(shop.files.filter { !$0.isFavourite }.prefix(4))
            for file in chosen { shop.toggleFavourite(file) }
            // A delete queued behind them, of a model none of them touched.
            let doomed = shop.files[20]
            await shop.deleteLibraryFiles([doomed])
            await shop.settleLibraryWrites()
            let ids = Set(chosen.map(\.id))
            var starredOnDisk = 0
            for case .object(let o) in try diskRows(url) where ids.contains(Shop.recordId(.object(o)) ?? "") {
                if o["favorite"] == .bool(true) { starredOnDisk += 1 }
            }
            #expect(starredOnDisk == 4, "an edit was lost behind another")
            let starredOnScreen = shop.files.filter { ids.contains($0.id) && $0.isFavourite }.count
            #expect(starredOnScreen == 4)
            let onDisk = try diskIds(url)
            #expect(!onDisk.contains(doomed.id))
            let written = try diskRows(url)
            #expect(shop.libraryRows == written, "the screen and the book disagree")
        }
    }

    /// A reload whose read of the book came BEFORE a library write, finishing
    /// AFTER that write was put on screen, drew the older book: the star went
    /// off again (a deleted model came back) with nothing pending to fix it.
    @Test("a reload that read the book before an edit landed does not undo it on screen")
    func reloadOlderThanAWrite() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 20)) { shop, url in
            let file = try #require(shop.files.first { !$0.isFavourite })
            // Hold the write chain, so the edit's write waits behind it.
            let release = DispatchSemaphore(value: 0)
            await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    StoreWriter.serialised { held.resume(); release.wait() }
                }
            }
            shop.toggleFavourite(file)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) { release.signal() }
            // Between the reload's read and its use of it, the edit lands and
            // is put on screen.
            Shop.afterBookReadForTests = {
                Shop.afterBookReadForTests = nil
                await shop.settleLibraryWrites()
            }
            await shop.load(shop.source)
            Shop.afterBookReadForTests = nil
            await shop.settleLibraryWrites()
            var onDisk: JSONValue?
            for case .object(let o) in try diskRows(url) where o["id"] == .string(file.id) { onDisk = o["favorite"] }
            #expect(onDisk == .bool(true))
            let starred = shop.files.first { $0.id == file.id }?.isFavourite
            #expect(starred == true, "the reload put the older book back on screen")
            #expect(shop.libraryRows == (try diskRows(url)), "the screen and the book disagree")
        }
    }

    /// Another app takes the book: a live pid on this host (launchd).
    static func stealBook(_ url: URL) throws -> URL {
        let now = Date().timeIntervalSince1970 * 1000
        let thief = StoreLock.Record(app: "Khayt", pid: 1, host: ProcessInfo.processInfo.hostName,
                                     takenAt: now, heartbeat: now)
        let lock = url.deletingLastPathComponent().appending(path: StoreLock.filename)
        try JSONEncoder().encode(thief).write(to: lock)
        return lock
    }

    @Test("an edit whose write is refused leaves no undo behind, so ⌘Z reaches the change before it")
    func refusedEditLeavesNoUndo() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 20)) { shop, url in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            let plain = shop.files.filter { !$0.isFavourite }
            let first = try #require(plain.first), second = try #require(plain.dropFirst().first)
            func favourite(_ id: String) throws -> JSONValue? {
                for case .object(let o) in try diskRows(url) where o["id"] == .string(id) { return o["favorite"] }
                return nil
            }
            undo.beginUndoGrouping()
            shop.toggleFavourite(first)
            undo.endUndoGrouping()
            await shop.settleLibraryWrites()
            #expect(try favourite(first.id) == .bool(true))

            let lock = try Self.stealBook(url)
            undo.beginUndoGrouping()
            shop.toggleFavourite(second)
            undo.endUndoGrouping()
            await shop.settleLibraryWrites()
            // Let the undo's own clean-up hear that the write failed.
            for _ in 0..<20 { await Task.yield() }
            #expect(shop.writeProblem != nil, "a refused edit said nothing")
            #expect(try favourite(second.id) != .bool(true))
            try FileManager.default.removeItem(at: lock)
            #expect(StoreLock.take(for: .shipped) != nil, "the book could not be taken back")

            undo.undo()
            await shop.settleLibraryWrites()
            #expect(try favourite(first.id) == .bool(false), "⌘Z was swallowed by the refused edit")
            #expect(!undo.canUndo, "the refused edit is still on the undo stack")
            shop.undoManager = nil
        }
    }

    @Test("a delete that cannot be written leaves the model's files where they are")
    func refusedDeleteKeepsFiles() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 10)) { shop, url in
            let file = shop.files[0]
            let primary = try #require(shop.libraryRoots?.primary)
            let folder = URL(fileURLWithPath: primary).appending(path: LibraryLocation.itemDirName(file.id))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let model = folder.appending(path: "model.3mf")
            try Data("solid".utf8).write(to: model)
            _ = try Self.stealBook(url)
            await shop.deleteLibraryFiles([file])
            #expect(shop.importProblem != nil, "a refused delete said nothing")
            #expect(try diskIds(url).contains(file.id))
            #expect(FileManager.default.fileExists(atPath: model.path),
                    "the files went to the Trash though the record stayed in the book")
            #expect(shop.files.contains { $0.id == file.id })
        }
    }

    @Test("a delete that cannot be written puts the models back on screen")
    func failedDeleteComesBack() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 20)) { shop, url in
            // Another app takes the book (a live pid on this host: launchd).
            let now = Date().timeIntervalSince1970 * 1000
            let thief = StoreLock.Record(app: "Khayt", pid: 1, host: ProcessInfo.processInfo.hostName,
                                         takenAt: now, heartbeat: now)
            let lock = url.deletingLastPathComponent().appending(path: StoreLock.filename)
            try JSONEncoder().encode(thief).write(to: lock)
            let file = shop.files[0]
            await shop.deleteLibraryFiles([file])
            #expect(shop.importProblem != nil, "a refused delete said nothing")
            let back = shop.files.contains { $0.id == file.id }
            #expect(back, "a model the book still holds vanished")
            #expect(try diskIds(url).contains(file.id))
        }
    }

    @Test("the write runs on the write chain, never on the main thread")
    func writeIsOffMain() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 5)) { _, url in
            let probe: @Sendable (inout [String: JSONValue]) -> Bool = { _ in Thread.isMainThread }
            let onMain = try await StoreWriter.updateOffMain(storeURL: url, owns: { true },
                                                             whoHasIt: { nil }, mutate: probe)
            #expect(!onMain)
        }
    }

    /// Opt-in: `KHAYT_PERF_MEASURE=1` prints the timings this file's budget
    /// was chosen from; `KHAYT_PERF_BOOK=<path>` measures a local copy of a
    /// real book instead (never commit one).
    @Test("measure: library edits at real size (prints timings)",
          .enabled(if: ProcessInfo.processInfo.environment["KHAYT_PERF_MEASURE"] != nil))
    func measure() async throws {
        let book: [String: JSONValue]
        if let path = ProcessInfo.processInfo.environment["KHAYT_PERF_BOOK"] {
            book = try JSONDecoder().decode([String: JSONValue].self,
                                            from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            book = PerfBook.synthesize()
        }
        let clock = ContinuousClock()
        let meter = MainStallMeter()
        let support = try PerfBook.install(book)
        let spotlight = UserDefaults.standard.object(forKey: Spotlight.defaultsKey)
        UserDefaults.standard.set(false, forKey: Spotlight.defaultsKey)
        let shop = Shop()
        defer {
            StoreReader.Build.supportFolderForTests = nil
            UserDefaults.standard.set(spotlight, forKey: Spotlight.defaultsKey)
            try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
        }

        meter.start()
        var t = clock.now
        await shop.load(.store(.shipped))
        print("PERF load: wall \(ms(clock.now - t)) ms, worst main stall \(await meter.stop()) ms, files \(shop.files.count)")

        let one = try #require(shop.files.first)
        meter.start()
        t = clock.now
        await shop.deleteLibraryFiles([one])
        print("PERF delete one: wall \(ms(clock.now - t)) ms, worst main stall \(await meter.stop()) ms")

        let many = Array(shop.files.prefix(20))
        meter.start()
        t = clock.now
        await shop.deleteLibraryFiles(many)
        print("PERF delete twenty: wall \(ms(clock.now - t)) ms, worst main stall \(await meter.stop()) ms")

        let fav = shop.files[5]
        meter.start()
        t = clock.now
        shop.toggleFavourite(fav)
        let favSync = ms(clock.now - t)
        await shop.settleLibraryWrites()
        print("PERF favourite: on screen in \(favSync) ms, written in \(ms(clock.now - t)) ms, worst main stall \(await meter.stop()) ms")

        let moving = Set(shop.files.dropFirst(10).prefix(5).map(\.id))
        shop.fileSelection = moving
        meter.start()
        t = clock.now
        await shop.fileSelection(under: "Perf Moved")
        await shop.settleLibraryWrites()
        print("PERF move five to a group: wall \(ms(clock.now - t)) ms, worst main stall \(await meter.stop()) ms")

        await shop.load(.sample)
    }
}
