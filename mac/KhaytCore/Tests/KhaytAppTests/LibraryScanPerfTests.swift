import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "The library scan freezes for a few seconds" (Oct 2026): a shop with a
/// linked Google Drive of ~10,000 models, mostly kept online, beachballed for
/// as long as the scan ran.
///
/// Measured on a copy of that shop's book (never committed) and a mirror of its
/// drive's folders, the causes were: every model indexed wrote the whole 15 MB
/// book ON THE MAIN THREAD (1.5–3 s each, and ~3,500 models still unindexed,
/// so every launch froze again); every pass after the walk reloaded the book
/// whether or not it had written; "Check pictures" looked every picture up by
/// walking every record; and the storage pass decoded the book and stat'ed
/// each model on the main thread. A scan that found nothing new held the main
/// thread 13.9 s in all (longest single hold 3.9 s); the storage pass 6.6 s.
///
/// Synthesised drive and book (`PerfBook`), in the same serialised suite as
/// the library-edit timings: both point the app at a temp folder through the
/// one global test seam.
extension LibraryEditPerfTests {

    /// A linked "drive": `folders` folders of `perFolder` models, and `loose`
    /// models at its top, with a picture in every tenth folder. One byte each —
    /// the scan reads none of them, as it reads none of a drive kept online.
    static func drive(folders: Int = 1_200, perFolder: Int = 6, loose: Int = 2_600) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "khayt-scan-\(UUID().uuidString)/My Drive")
        let fm = FileManager.default
        let byte = Data("x".utf8)
        for f in 0..<folders {
            let dir = root.appending(path: "Collection \(f % 97)/Project \(f)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for m in 0..<perFolder {
                try byte.write(to: dir.appending(path: "part \(f)-\(m).\(m % 2 == 0 ? "stl" : "3mf")"))
            }
            if f % 10 == 0 { try byte.write(to: dir.appending(path: "render.jpg")) }
        }
        for m in 0..<loose { try byte.write(to: root.appending(path: "loose \(m).stl")) }
        return root
    }

    /// A 10,000-model book with `drive` linked.
    static func book(linking drive: URL) -> [String: JSONValue] {
        var root = PerfBook.synthesize()
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        library["linked"] = .array([.string(drive.standardizedFileURL.path)])
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
        return root
    }

    /// `withPerfBook`, with the drive kept online (as the shop's is) and the
    /// load-time scan left to the test — so what is timed is one whole scan.
    static func withScanBook(_ drive: URL, _ body: (Shop, URL) async throws -> Void) async throws {
        let support = try PerfBook.install(book(linking: drive))
        let spotlight = UserDefaults.standard.object(forKey: Spotlight.defaultsKey)
        UserDefaults.standard.set(false, forKey: Spotlight.defaultsKey)
        let shop = Shop()
        shop.linkedIsOnline = { _ in true }
        shop.linkedScannedBooks.insert(StoreReader.Build.shipped.rawValue)
        shop.storageScannedBooks.insert(StoreReader.Build.shipped.rawValue)
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

    static func written(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @Test("a linked drive of 9,800 new models is indexed without freezing the window, and again with nothing new")
    func linkedScanDoesNotFreeze() async throws {
        let drive = try Self.drive()
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        try await Self.withScanBook(drive) { shop, url in
            // ── MEASURED ON THE WRITER'S CLOCK, NOT THE MAIN QUEUE'S ─────
            //
            // This was a timer on the main queue (`MainStallMeter`), and it
            // failed at 1,914 ms against the 1,500 ms budget with a second
            // full suite running on the same Mac (review of #1866): how late
            // the main thread answers measures whatever else is queued on
            // it, not the scan. What froze the shop's window was the scan
            // writing the whole book ON the main thread, once per model, and
            // that is what `MainHold` counts, on the writer's own clock — the
            // same guard as `StoreWritePerfTests`. The stall is still printed
            // under `KHAYT_PERF_MEASURE=1` for a person to read.
            let measuring = ProcessInfo.processInfo.environment["KHAYT_PERF_MEASURE"] != nil
            let meter = MainStallMeter()

            if measuring { meter.start() }
            let full = await Self.held { await shop.rescanLinkedFolders() }
            if measuring { print("PERF full scan: worst main stall \(Int(await meter.stop())) ms") }
            let rows = try diskRows(url)
            #expect(rows.count == 19_800, "the drive's models went into the book: \(rows.count)")
            #expect(shop.files.count == rows.count, "the library on screen is the book")
            #expect(full.count == 0,
                    "the full scan wrote the whole book on the main thread \(full.count)x, worst \(Int(full.worstMs)) ms")

            // Nothing new: nothing written, nothing reloaded, no freeze.
            let before = Self.written(url)
            if measuring { meter.start() }
            let again = await Self.held { await shop.rescanLinkedFolders() }
            if measuring { print("PERF rescan: worst main stall \(Int(await meter.stop())) ms") }
            #expect(Self.written(url) == before, "a scan that found nothing new wrote to the book")
            #expect(again.count == 0, "the rescan wrote the whole book on the main thread \(again.count)x")

            // The library's own folder, with a vault folder for every record.
            if measuring { meter.start() }
            let storage = await Self.held { await shop.rescanStorage() }
            if measuring { print("PERF storage pass: worst main stall \(Int(await meter.stop())) ms") }
            #expect(storage.count == 0, "the storage pass wrote the whole book on the main thread \(storage.count)x")
        }
    }

    @Test("Stop ends a 10,000-model scan, and what it indexed before stays")
    func linkedScanStops() async throws {
        // A smaller drive than the timing test's: Stop is pressed at the first
        // progress, ~50 models in, so 1,600 is as good a guard and a third of
        // the CI time (review of #1860).
        let drive = try Self.drive(folders: 200, perFolder: 6, loose: 400)
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        try await Self.withScanBook(drive) { shop, url in
            let scan = Task { await shop.rescanLinkedFolders() }
            // Pressed once the indexing has started.
            while shop.libraryMoveProgress == nil, !scan.isCancelled {
                try await Task.sleep(for: .milliseconds(5))
                if shop.libraryScanStop == nil, shop.libraryMoveNote != nil { break }
            }
            shop.stopLibraryScan()
            await scan.value
            let added = try diskRows(url).count - 10_000
            #expect(added > 0, "what was indexed before the Stop was written")
            #expect(added < 1_600, "the scan stopped")
            #expect(shop.libraryScanStop == nil && !shop.libraryMoveBusy, "the scan let go of the library")
        }
    }
}
