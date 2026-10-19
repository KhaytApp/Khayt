import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Measure online models" (Oct 2026): 6,521 of the shop's 10,176 models sat
/// in a linked Google Drive, online only and never measured — so none of them
/// could be priced, on the Mac or from the phone. Temp drives and temp books
/// only: a dataless placeholder cannot be made in a test, so "online" and
/// "handed back to the drive" are handed in (`linkedIsOnline`, `linkedEvict`).
@MainActor
struct OnlineMeasureTests {

    static func file(_ id: String, _ path: String, ext: String = "stl", key: String? = nil, hash: String? = nil,
                     archived: Bool = false) throws -> LibraryFile {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(id), "externalPath": .string(path),
            "sourceFile": .object(["filename": .string("m.\(ext)"), "ext": .string(ext), "size": .number(1000)]),
        ]
        if let key { o["geometryKey"] = .string(key) }
        if let hash { o["contentHash"] = .string(hash) }
        if archived { o["archivedAt"] = .string("2026-10-01T00:00:00Z") }
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(o)))
    }

    @Test("due: linked, never read, measurable — and nothing else")
    func dueRule() throws {
        let drive = "/Users/x/My Drive/Shared"
        let files = try [
            Self.file("a", drive + "/a/m.stl"),
            Self.file("b", drive + "/b/m.3mf", ext: "3mf"),
            Self.file("measured", drive + "/c/m.stl", key: "12:1.0:1x1x1"),
            // Read already and nothing came back: fetching it again changes nothing.
            Self.file("hashed", drive + "/d/m.stl", hash: "abc"),
            Self.file("archived", drive + "/e/m.stl", archived: true),
            Self.file("step", drive + "/f/m.step", ext: "step"),
            // Arrived by sync, pointing somewhere this book does not link.
            Self.file("elsewhere", "/Users/x/Desktop/m.stl"),
        ]
        let due = OnlineMeasure.due(files, linked: [drive])
        #expect(due.map(\.id) == ["a", "b"])
        #expect(due.allSatisfy { $0.size == 1000 })
        #expect(OnlineMeasure.due(files, linked: []).isEmpty, "no linked folder, nothing read")
    }

    @Test("a batch of reads is one write: keys on, online mark off, the shop's own fields kept")
    func batchApply() throws {
        func read(_ hash: String, key: String?) -> Shop.DownloadedRead {
            Shop.DownloadedRead(hash: hash, key: key, reader: 3, colours: [], swapCount: 0, thumbFile: "thumb.png",
                                parsed: [:], size: 2048, designer: "Maker", licence: nil)
        }
        var book: [String: JSONValue] = ["printFiles": .array([
            .object(["id": .string("a"), "name": .string("Dragon"), "indexedOnline": .string("2026-10-16"),
                     "source": .string("Shop's own"), "sourceFile": .object(["size": .number(1)])]),
            .object(["id": .string("b"), "name": .string("Egg"), "indexedOnline": .string("2026-10-16")]),
            .object(["id": .string("c"), "name": .string("Old egg"), "contentHash": .string("h-egg")]),
            .object(["id": .string("d"), "name": .string("Untouched"), "indexedOnline": .string("2026-10-16")]),
        ])]
        let dupes = Shop.applyDownloaded(["a": read("h-dragon", key: "10:1.0:1x1x1"), "b": read("h-egg", key: nil)],
                                         to: &book)
        let rows = Shop.rows(book, "printFiles").compactMap { if case .object(let o) = $0 { o } else { nil } }
        #expect(rows[0]["geometryKey"] == .string("10:1.0:1x1x1") && rows[0]["contentHash"] == .string("h-dragon"))
        #expect(rows[0]["indexedOnline"] == nil, "read now")
        #expect(rows[0]["source"] == .string("Shop's own"), "what the shop wrote stays")
        #expect(rows[0]["sourceFile"] == .object(["size": .number(2048)]))
        #expect(rows[1]["geometryKey"] == nil && rows[1]["contentHash"] == .string("h-egg"),
                "read and unmeasurable: hashed, so it is not fetched again")
        #expect(rows[3]["indexedOnline"] != nil, "a record not in the batch is not touched")
        #expect(dupes == ["b": "Old egg"])
    }

    @Test("a thumbnail is a name in the model's folder, never a path out of it")
    func thumbStaysInFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "khayt-thumb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: LibraryLocation.itemDirName("PF-t"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "thumb.png"))
        try Data("secret".utf8).write(to: root.appending(path: "outside.png"))
        func file(_ thumb: String) throws -> LibraryFile {
            try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(
                ["id": .string("PF-t"), "name": .string("t"), "thumbFile": .string(thumb)])))
        }
        #expect(Shop.thumbnailOnDisk(try file("thumb.png"), roots: [root.path]) != nil)
        #expect(Shop.thumbnailOnDisk(try file("../outside.png"), roots: [root.path]) == nil)
        #expect(Shop.thumbnailOnDisk(try file(".."), roots: [root.path]) == nil)
    }

    @Test("wired: Settings offers it with the size, and it asks first")
    func wired() throws {
        let settings = try LockRound3Tests.source("LibraryLocationSettings.swift")
        #expect(settings.contains(".task(id: shop.loadGeneration) { await shop.countOnlineUnmeasured() }"))
        #expect(settings.contains("await shop.measureOnlineModels()"))
        #expect(settings.contains("isPresented: $askMeasure"))
        let pass = try LockRound3Tests.source("Shop+MeasureOnline.swift")
        #expect(pass.contains("defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }"))
        #expect(try LockRound3Tests.source("Shop+PhoneLibrary.swift").contains("rememberMeasured(file, at: url, wasOnline: wasOnline)"))
        #expect(try LockRound3Tests.source("LanServer.swift").contains("guard libraryMeasuring < Self.maxLibraryMeasuring"),
                "the phone's library pricing has its own slot, not the customers' intake ones")
    }
}

extension LibraryEditPerfTests {

    /// A small book linking `drive`, with `rows` as its models.
    static func withOnlineBook(_ drive: URL, rows: [JSONValue],
                               _ body: (Shop, URL, OnlineMeasureTests.Evicted) async throws -> Void) async throws {
        var root = PerfBook.synthesize(models: 0)
        root["printFiles"] = .array(rows)
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        settings["printLibrary"] = .object(["linked": .array([.string(drive.standardizedFileURL.path)])])
        root["settings"] = .object(settings)
        let support = try PerfBook.install(root)
        let spotlight = UserDefaults.standard.object(forKey: Spotlight.defaultsKey)
        UserDefaults.standard.set(false, forKey: Spotlight.defaultsKey)
        let shop = Shop()
        let evicted = OnlineMeasureTests.Evicted()
        shop.linkedIsOnline = { _ in true }
        shop.linkedEvict = { evicted.add($0) }
        shop.linkedScannedBooks.insert(StoreReader.Build.shipped.rawValue)
        shop.storageScannedBooks.insert(StoreReader.Build.shipped.rawValue)
        do {
            await shop.load(.store(.shipped))
            try await body(shop, StoreReader.Build.shipped.storeURL, evicted)
        } catch {
            Issue.record(error)
        }
        await shop.settleLibraryWrites()
        await shop.load(.sample)
        StoreReader.Build.supportFolderForTests = nil
        UserDefaults.standard.set(spotlight, forKey: Spotlight.defaultsKey)
        try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
    }

    static func onlineRow(_ id: String, _ url: URL) -> JSONValue {
        .object(["id": .string(id), "name": .string(id), "externalPath": .string(url.standardizedFileURL.path),
                 "indexedOnline": .string("2026-10-16T08:18:55.569Z"), "contentHash": .null, "geometryKey": .null,
                 "sourceFile": .object(["filename": .string(url.lastPathComponent), "ext": .string("stl"),
                                        "size": .number(684)])])
    }

    @Test("Measure online models: each read, measured, handed back to the drive, and written to the book")
    func measuresOnlineModels() async throws {
        let drive = FileManager.default.temporaryDirectory.appending(path: "khayt-online-\(UUID().uuidString)/My Drive")
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        let a = drive.appending(path: "Dragons/dragon.stl"), b = drive.appending(path: "Eggs/egg.stl")
        try LinkedScanTests.model(a, size: 10)
        try LinkedScanTests.model(b, size: 12)
        let gone = drive.appending(path: "Gone/gone.stl")   // listed once, not on the drive now
        let rows = [Self.onlineRow("PF-a", a), Self.onlineRow("PF-b", b), Self.onlineRow("PF-gone", gone)]
        try await Self.withOnlineBook(drive, rows: rows) { shop, url, evicted in
            await shop.countOnlineUnmeasured()
            #expect(shop.onlineUnmeasured.count == 3 && shop.onlineUnmeasured.bytes == 3 * 684)
            await shop.measureOnlineModels()
            let disk = try diskRows(url).compactMap { if case .object(let o) = $0 { o } else { nil } }
            for id in ["PF-a", "PF-b"] {
                let o = try #require(disk.first { $0["id"] == .string(id) })
                #expect(o["geometryKey"] != nil && o["geometryKey"] != .null, "\(id) measured")
                #expect(o["indexedOnline"] == nil)
            }
            let g = try #require(disk.first { $0["id"] == .string("PF-gone") })
            #expect(g["indexedOnline"] != nil, "a file not there is left for next time")
            #expect(Set(evicted.urls.map(\.lastPathComponent)) == ["dragon.stl", "egg.stl"],
                    "each fetched model handed back to the drive")
            #expect(shop.files.filter { !($0.geometryKey ?? "").isEmpty }.count == 2, "the library reloaded")
            #expect(shop.libraryMoveNote == shop.words.callIt("mac.measure_online_done",
                                                              ["n": .number(2), "skipped": .number(1)]))
            #expect(!shop.libraryMoveBusy && shop.libraryScanStop == nil)
            await shop.countOnlineUnmeasured()
            #expect(shop.onlineUnmeasured.count == 1, "only the missing one is still due")
        }
    }

    @Test("a model priced from the phone is measured once: written to the book, and handed back to the drive")
    func phoneMeasureRemembered() async throws {
        let drive = FileManager.default.temporaryDirectory.appending(path: "khayt-online-\(UUID().uuidString)/My Drive")
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        let a = drive.appending(path: "Dragons/dragon.stl")
        try LinkedScanTests.model(a, size: 10)
        try await Self.withOnlineBook(drive, rows: [Self.onlineRow("PF-a", a)]) { shop, url, evicted in
            let (status, body) = await shop.phoneLibraryEstimate("PF-a", plate: nil, qty: 1)
            #expect(status == 200, "\(body)")
            await shop.phoneMeasureWrite?.value
            let o = try #require(try diskRows(url).first.flatMap { if case .object(let o) = $0 { o } else { nil } })
            #expect(o["geometryKey"] != nil && o["geometryKey"] != .null)
            #expect(evicted.urls.map(\.lastPathComponent) == ["dragon.stl"])
        }
    }

    @Test("a phone price never reads a file outside the book's folders, whatever a synced record says")
    func phoneMeasureStaysInFolders() async throws {
        let drive = FileManager.default.temporaryDirectory.appending(path: "khayt-online-\(UUID().uuidString)/My Drive")
        let outside = drive.deletingLastPathComponent().appending(path: "Elsewhere/secret.stl")
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        try LinkedScanTests.model(outside, size: 10)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try await Self.withOnlineBook(drive, rows: [Self.onlineRow("PF-x", outside)]) { shop, url, evicted in
            let (status, body) = await shop.phoneLibraryEstimate("PF-x", plate: nil, qty: 1)
            #expect(status == 409 && body.contains("no-file"), "\(status) \(body)")
            #expect(evicted.urls.isEmpty)
        }
    }
}

extension OnlineMeasureTests {
    final class Evicted: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URL] = []
        var urls: [URL] { lock.withLock { list } }
        func add(_ url: URL) { lock.withLock { list.append(url) } }
    }
}
