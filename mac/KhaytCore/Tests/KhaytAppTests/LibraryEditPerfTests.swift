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
        let support = FileManager.default.temporaryDirectory
            .appending(path: "khayt-perf-\(UUID().uuidString)")
        let folder = support.appending(path: StoreReader.Build.shipped.rawValue)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(root).write(to: folder.appending(path: "khayt-store.json"))
        StoreReader.Build.supportFolderForTests = support
        return support
    }

    /// Or a local copy of a real book, for measuring by hand. NEVER commit one.
    @MainActor
    static func installRealIfAsked() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["KHAYT_PERF_BOOK"] else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try install(JSONDecoder().decode([String: JSONValue].self, from: data))
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

@MainActor
@Suite(.serialized)
struct LibraryEditPerfTests {

    @Test("measure: library edits at real size (prints timings)")
    func measure() async throws {
        let support: URL
        if let real = try PerfBook.installRealIfAsked() { support = real }
        else { support = try PerfBook.install(PerfBook.synthesize()) }
        // Never into this Mac's own Spotlight from a test.
        let spotlight = UserDefaults.standard.object(forKey: Spotlight.defaultsKey)
        UserDefaults.standard.set(false, forKey: Spotlight.defaultsKey)
        defer {
            StoreReader.Build.supportFolderForTests = nil
            try? FileManager.default.removeItem(at: support)
            UserDefaults.standard.set(spotlight, forKey: Spotlight.defaultsKey)
        }
        let clock = ContinuousClock()
        let shop = Shop()
        let meter = MainStallMeter()

        meter.start()
        var t = clock.now
        await shop.load(.store(.shipped))
        print("PERF load: wall \(ms(clock.now - t)) ms, worst main stall \(await meter.stop()) ms, files \(shop.files.count)")

        let url = StoreReader.Build.shipped.storeURL
        t = clock.now
        let data = try Data(contentsOf: url)
        let read = ms(clock.now - t)
        t = clock.now
        var root = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let decode = ms(clock.now - t)
        let before = root
        if case .array(var rows)? = root["printFiles"] { rows.removeFirst(); root["printFiles"] = .array(rows) }
        t = clock.now
        StoreWriter.reviveUnderNewIds(before: before, after: &root)
        StoreWriter.recordDeletions(before: before, after: &root)
        StoreWriter.stampChanged(before: before, after: &root)
        let bookkeeping = ms(clock.now - t)
        t = clock.now
        let encoded = try JSONEncoder().encode(root)
        let encode = ms(clock.now - t)
        print("PERF parts: read \(read) ms, decode \(decode) ms, revive+tombstone+stamp \(bookkeeping) ms, encode \(encode) ms (\(encoded.count) bytes)")

        // One model.
        guard let one = shop.files.first else { Issue.record("no files"); return }
        meter.start()
        t = clock.now
        await shop.deleteLibraryFiles([one])
        print("PERF delete one: wall \(ms(clock.now - t)) ms, worst main stall \(await meter.stop()) ms, files \(shop.files.count)")

        // Twenty at once.
        let many = Array(shop.files.prefix(20))
        meter.start()
        t = clock.now
        await shop.deleteLibraryFiles(many)
        print("PERF delete twenty: wall \(ms(clock.now - t)) ms, worst main stall \(await meter.stop()) ms, files \(shop.files.count)")

        // Favourite (fire-and-forget reload inside).
        let fav = shop.files[5]
        meter.start()
        t = clock.now
        shop.toggleFavourite(fav)
        let favSync = ms(clock.now - t)
        await shop.settleLibraryWrites()
        try? await Task.sleep(for: .seconds(4))
        print("PERF favourite: synchronous \(favSync) ms, worst main stall incl. reload \(await meter.stop()) ms, now \(shop.files.first { $0.id == fav.id }?.isFavourite ?? false)")
    }
}
