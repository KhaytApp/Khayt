import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// A linked Google Drive of ~10,000 models (Oct 2026): "no way to stop the
/// online folder scan", and every file was being downloaded to be indexed.
/// Temp folders and temp books only — a dataless placeholder cannot be made
/// in a test, so which files are "online" is handed in, as the scan hands in
/// `LinkedCloud.isOnlineOnly`.
@MainActor
struct LinkedScanTests {

    typealias Bench = LibraryImportEndToEndTests.Bench

    static func model(_ url: URL, size: Double = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MeshTests.binarySTL(MeshTests.boxFacets(size, size, size)).write(to: url)
    }

    static func objects(_ bench: Bench) throws -> [[String: JSONValue]] {
        try LibraryImportEndToEndTests.printFiles(in: bench).compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    // MARK: - Online only

    @Test("an online-only linked file is indexed from its listing: no hash, no measuring, marked online")
    func onlineIsNotRead() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let drive = bench.dir.appending(path: "Drive/Dragons")
        let online = drive.appending(path: "dragon.stl"), local = drive.appending(path: "egg.stl")
        try Self.model(online, size: 10)
        try Self.model(local, size: 12)
        let report = await LibraryImport.addMany(
            LibraryImport.Incoming.ungrouped([online, local]),
            storeURL: bench.store, libraryRoot: bench.library, knownHashes: [], nameOfExisting: { _ in nil },
            engine: try KhaytEngine(), keepOriginal: true, inPlace: true,
            isOnline: { $0.lastPathComponent == "dragon.stl" },
            owns: { true }, whoHasIt: { nil })
        #expect(report.moved == 2 && report.online == 1)
        let rows = try Self.objects(bench)
        let o = try #require(rows.first { $0["originalName"] == .string("dragon.stl") })
        #expect(o["contentHash"] == .null, "hashing it is downloading it")
        #expect(o["geometryKey"] == .null && o["thumbFile"] == .null)
        #expect(o["indexedOnline"] != nil)
        #expect(o["externalPath"] == .string(online.standardizedFileURL.path))
        if case .object(let sf)? = o["sourceFile"] { #expect(sf["size"] == .number(684)) }
        let l = try #require(rows.first { $0["originalName"] == .string("egg.stl") })
        #expect(l["contentHash"] != .null && l["indexedOnline"] == nil, "a local file is read as before")
    }

    @Test("an online-only file the library already holds is a duplicate by name and size, not by hash")
    func onlineDuplicateBySize() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let file = bench.dir.appending(path: "Drive/a/dragon.stl")
        try Self.model(file)
        let report = await LibraryImport.addMany(
            LibraryImport.Incoming.ungrouped([file]),
            storeURL: bench.store, libraryRoot: bench.library, knownHashes: [], nameOfExisting: { _ in nil },
            engine: try KhaytEngine(), keepOriginal: true, inPlace: true,
            knownNameSizes: [LibraryImport.nameSize(684, "Dragon.STL")],
            isOnline: { _ in true },
            owns: { true }, whoHasIt: { nil })
        #expect(report.moved == 0 && report.duplicates == 1)
        #expect(try Self.objects(bench).isEmpty)
    }

    @Test("a picture the cloud would have to download is never decoded for a linked model")
    func onlinePhotoSkipped() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let file = bench.dir.appending(path: "Drive/owl/owl.stl")
        try Self.model(file)
        let photo = bench.dir.appending(path: "Drive/owl/owl.jpg")
        try LibraryStorageTests.picture(photo)
        var incoming = LibraryImport.Incoming(url: file, group: nil)
        incoming.photos = [photo]
        let report = await LibraryImport.addMany(
            [incoming], storeURL: bench.store, libraryRoot: bench.library, knownHashes: [], nameOfExisting: { _ in nil },
            engine: try KhaytEngine(), keepOriginal: true, inPlace: true,
            isOnline: { $0.pathExtension == "jpg" },
            owns: { true }, whoHasIt: { nil })
        #expect(report.moved == 1 && report.photos == 0)
    }

    @Test("once the file is here, the existing fill writes the rest — pictures in the vault, never the shop's folder")
    func filledOnceLocal() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let file = bench.dir.appending(path: "Drive/cube/cube.stl")
        try Self.model(file)
        _ = await LibraryImport.addMany(
            LibraryImport.Incoming.ungrouped([file]),
            storeURL: bench.store, libraryRoot: bench.library, knownHashes: [], nameOfExisting: { _ in nil },
            engine: try KhaytEngine(), keepOriginal: true, inPlace: true, isOnline: { _ in true },
            owns: { true }, whoHasIt: { nil })
        let id = try #require({ if case .string(let s)? = try Self.objects(bench).first?["id"] { s } else { nil } }())
        let vault = bench.library.appending(path: LibraryLocation.itemDirName(id))
        try await Shop.fillDownloaded(id: id, file: file, pictures: vault, storeURL: bench.store,
                                      engine: try KhaytEngine(), owns: { true }, whoHasIt: { nil })
        let o = try #require(try Self.objects(bench).first)
        #expect(o["contentHash"] != .null && o["geometryKey"] != .null)
        #expect(o["indexedOnline"] == nil, "read now: no longer what the drive listed")
        let beside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(beside == ["cube.stl"], "nothing of the app's written into the shop's folder: \(beside)")
    }

    // MARK: - Stop

    @Test("Stop between files keeps what was indexed, and says it stopped")
    func stopKeepsWhatIsDone() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let files = try (1...4).map { i -> URL in
            let u = bench.dir.appending(path: "Drive/m\(i).stl")
            try Self.model(u, size: Double(10 + i))
            return u
        }
        let stop = ScanStop()
        let report = await LibraryImport.addMany(
            LibraryImport.Incoming.ungrouped(files),
            storeURL: bench.store, libraryRoot: bench.library, knownHashes: [], nameOfExisting: { _ in nil },
            engine: try KhaytEngine(), keepOriginal: true, inPlace: true,
            owns: { true }, whoHasIt: { nil },
            shouldStop: { stop.isStopped },
            progress: { done, _, _ in if done == 2 { stop.stop() } })
        // Stop pressed while the third file was being indexed: that one
        // finishes (a file is indexed whole or not at all), the fourth never starts.
        #expect(report.stopped)
        #expect(report.moved == 3, "what was indexed before the Stop stays")
        #expect(try Self.objects(bench).count == 3)
    }

    @Test("the walk stops when asked, and reads no file to find models")
    func walkStops() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<600 {
            let u = root.appending(path: "Pack \(i % 3)/m\(i).stl")
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: u)
        }
        let all = Shop.linkedWalk([root], skippingAll: [], known: [], stop: nil)
        #expect(all.first?.models.count == 600)
        #expect(all.first?.fresh.first?.group?.hasPrefix(root.lastPathComponent) == false,
                "the linked folder's own name is not a group")
        let stop = ScanStop()
        stop.stop()
        let none = Shop.linkedWalk([root], skippingAll: [], known: [], stop: stop)
        #expect(none.isEmpty)
    }

    @Test("Stop reaches the running scan, and the load-time pass does not start again by itself")
    func stopIsWired() throws {
        let shop = Shop()
        let stop = ScanStop()
        shop.libraryScanStop = stop
        shop.stopLibraryScan()
        #expect(stop.isStopped)
        let storage = try LockRound3Tests.source("LibraryStorage.swift")
        #expect(storage.contains("!self.libraryScanStoppedBooks.contains(build.rawValue)"))
        #expect(storage.contains("defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }"))
        let linked = try LockRound3Tests.source("LinkedFolders.swift")
        #expect(linked.contains("defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }"))
        #expect(try LockRound3Tests.source("Banners.swift").contains("shop.stopLibraryScan()"))
        #expect(try LockRound3Tests.source("LibraryLocationSettings.swift").contains("shop.stopLibraryScan()"))
    }

    // MARK: - The records already on disk

    static let drive = URL(fileURLWithPath: "/Users/x/My Drive/Auto_Copied_Shared (1)")
    static func f(_ rel: String) -> URL { drive.appending(path: rel) }
    static func row(_ id: String, _ rel: String, group: String, name: String,
                    extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name),
                                      "externalPath": .string(f(rel).standardizedFileURL.path),
                                      "group": .string(group), "folder": .string(group)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("records the old rule filed are refiled; a group the shop chose is left alone")
    func regroupProtectsHandPlaced() {
        let rels = ["Aug26 Giga Tier/Aug26 Collectibles Tier/Call of Duty 4 /Mini Poster/STLs/Base_2.stl",
                    "Aug26 Giga Tier/Aug26 Collectibles Tier/Call of Duty 4 /Mini Poster/STLs/Frame.stl",
                    "2026 World Cup/2026 FIFA World Cup_Key Chain/Key_v2_SPAIN.3mf",
                    "2026 World Cup/2026 FIFA World Cup_Key Chain/Key_v2_BRAZIL.3mf",
                    "Mumm-Ra/Mumm Ra - Patreon/Single STLs/head.stl"]
        let rows: [JSONValue] = [
            Self.row("PF-a", rels[0], group: "Auto_Copied_Shared (1)/Aug26 Giga Tier/Mini Poster", name: "Base_2"),
            Self.row("PF-b", rels[1], group: "Posters I like", name: "Frame"),            // the shop's
            Self.row("PF-c", rels[2], group: "Auto_Copied_Shared (1)/2026 FIFA World Cup_Key Chain", name: "Key_v2_SPAIN"),
            Self.row("PF-d", rels[3], group: "Custom", name: "Key_v2_BRAZIL",
                     extra: ["autoGroup": .string("Custom")]),                              // this app's, remembered
            // A folder of one: titled by its folders under the old rule.
            Self.row("PF-e", rels[4], group: "Auto_Copied_Shared (1)", name: "Mumm-Ra – Mumm Ra - Patreon – Single STLs"),
        ]
        let changes = LinkedRegroup.changes(rows: rows, root: Self.drive, models: rels.map(Self.f))
        let by = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        #expect(by["PF-a"]?.group == "Aug26 Giga Tier/Call of Duty 4/Mini Poster")
        #expect(by["PF-b"] == nil, "a group the shop chose is the shop's")
        #expect(by["PF-c"]?.group == "2026 World Cup/2026 FIFA World Cup Key Chain")
        #expect(by["PF-d"]?.group == "2026 World Cup/2026 FIFA World Cup Key Chain")
        #expect(by["PF-e"]?.group == "" && by["PF-e"]?.name == "Mumm-Ra",
                "a folder of one is the model's name, without the Patreon and packaging folders")
    }

    @Test("the refile is one write through the chain, marks the book, and runs again to nothing")
    func regroupWrites() throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let rels = ["Monsters/Dragon/a.stl", "Monsters/Dragon/b.stl"]
        let root = bench.dir.appending(path: "Shared")
        let rows: [JSONValue] = rels.enumerated().map { i, rel in
            .object(["id": .string("PF-\(i)"), "name": .string(i == 0 ? "a" : "b"),
                     "externalPath": .string(root.appending(path: rel).standardizedFileURL.path),
                     "group": .string("Shared/Monsters/Dragon"), "folder": .string("Shared/Monsters/Dragon")])
        }
        try LibraryStorageTests.write(rows, to: bench)
        let models = rels.map { root.appending(path: $0) }
        let n = try Shop.regroupLinked([(root, models)], storeURL: bench.store, owns: { true }, whoHasIt: { nil })
        #expect(n == 2)
        let after = try Self.objects(bench)
        #expect(after.allSatisfy { $0["group"] == .string("Monsters/Dragon") && $0["folder"] == .string("Monsters/Dragon")
                                   && $0["autoGroup"] == .string("Monsters/Dragon") })
        let book = try #require(Shop.readBook(bench.store))
        if case .object(let s)? = book["settings"] { #expect(LinkedRegroup.doneVersion(s) == LinkedRegroup.version) }
        #expect(try Shop.regroupLinked([(root, models)], storeURL: bench.store, owns: { true }, whoHasIt: { nil }) == 0)
    }
}
