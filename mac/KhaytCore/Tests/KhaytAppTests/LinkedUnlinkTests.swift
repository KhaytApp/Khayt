import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Linked folders: a deleted model stays deleted, an unlink takes only its
/// own folder's models and never runs under a scan, and the models a shop
/// made available offline are filled in a batch at a time.
///
/// In the serialised suite of the library timings: these point the app at a
/// temp book through the one global test seam (`PerfBook.install`).
extension LibraryEditPerfTests {

    /// A small book linking every folder in `linked`, with `rows` as its
    /// models and `library` laid into `settings.printLibrary`.
    static func withLinkedBook(_ linked: [URL], rows: [JSONValue] = [], library: [String: JSONValue] = [:],
                               _ body: (Shop, URL) async throws -> Void) async throws {
        var root = PerfBook.synthesize(models: 0)
        root["printFiles"] = .array(rows)
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var lib = library
        lib["linked"] = .array(linked.map { .string($0.standardizedFileURL.path) })
        settings["printLibrary"] = .object(lib)
        root["settings"] = .object(settings)
        let support = try PerfBook.install(root)
        let spotlight = UserDefaults.standard.object(forKey: Spotlight.defaultsKey)
        UserDefaults.standard.set(false, forKey: Spotlight.defaultsKey)
        let shop = Shop()
        shop.linkedIsOnline = { _ in true }
        shop.linkedEvict = { _ in }
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

    static func tempDrive() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "khayt-linked-\(UUID().uuidString)/My Drive")
    }

    static func linkedRow(_ id: String, _ url: URL) -> JSONValue {
        .object(["id": .string(id), "name": .string(id), "externalPath": .string(url.standardizedFileURL.path),
                 "sourceFile": .object(["filename": .string(url.lastPathComponent), "ext": .string("stl")])])
    }

    static func book(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    static func library(_ url: URL) throws -> [String: JSONValue] {
        guard case .object(let s)? = try book(url)["settings"],
              case .object(let l)? = s["printLibrary"] else { return [:] }
        return l
    }

    static func strings(_ v: JSONValue?) -> [String] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }

    @Test("a model deleted from a linked folder is not indexed again by the next scan")
    func linkedDeleteStaysDeleted() async throws {
        let drive = Self.tempDrive()
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        let a = drive.appending(path: "Dragons/dragon.stl"), b = drive.appending(path: "Eggs/egg.stl")
        try LinkedScanTests.model(a, size: 10)
        try LinkedScanTests.model(b, size: 12)
        try await Self.withLinkedBook([drive]) { shop, url in
            await shop.rescanLinkedFolders()
            #expect(shop.files.count == 2, "\(shop.libraryMoveProblem ?? "")")
            let dragon = try #require(shop.files.first { $0.externalPath == a.standardizedFileURL.path })
            await shop.deleteLibraryFiles([dragon])
            #expect(shop.files.count == 1)
            #expect(FileManager.default.fileExists(atPath: a.path), "the shop's file is never touched")

            await shop.rescanLinkedFolders()
            let paths = try diskRows(url).compactMap { row -> String? in
                if case .object(let o) = row, case .string(let p)? = o["externalPath"] { p } else { nil }
            }
            #expect(paths == [b.standardizedFileURL.path], "the deleted model came back: \(paths)")
        }
    }

    @Test("unlinking a folder keeps the models of a folder linked inside it, in one write")
    func unlinkKeepsNested() async throws {
        let drive = Self.tempDrive()
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        let prints = drive.appending(path: "Prints")
        let outer = drive.appending(path: "loose.stl"), inner = prints.appending(path: "boat.stl")
        try LinkedScanTests.model(outer)
        try LinkedScanTests.model(inner)
        let forgotten = drive.appending(path: "deleted.stl").standardizedFileURL.path
        let keptForgotten = prints.appending(path: "deleted.stl").standardizedFileURL.path
        try await Self.withLinkedBook([drive, prints],
                                      rows: [Self.linkedRow("PF-outer", outer), Self.linkedRow("PF-inner", inner)],
                                      library: ["notAdopted": .array([.string(forgotten), .string(keptForgotten)])]) { shop, url in
            await shop.unlinkFolder(drive.standardizedFileURL.path)
            #expect(shop.libraryMoveProblem == nil, "\(shop.libraryMoveProblem ?? "")")
            #expect(try diskIds(url) == ["PF-inner"], "the nested folder's model went with its parent")
            let lib = try Self.library(url)
            #expect(Self.strings(lib["linked"]) == [prints.standardizedFileURL.path])
            #expect(Self.strings(lib["notAdopted"]) == [keptForgotten],
                    "linking the folder again should index what is there")
            #expect(FileManager.default.fileExists(atPath: outer.path), "the shop's file is never touched")
        }
        // The list, the records and the ledger are one write: a second one
        // refused left the folder unlinked with its records still in the book.
        let source = try LockRound3Tests.source("LinkedFolders.swift")
        let start = try #require(source.range(of: "func unlinkFolder("))
        let end = try #require(source.range(of: "nonisolated static func unlink(", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        #expect(body.components(separatedBy: "StoreWriter.").count - 1 == 1)
        #expect(!body.contains("writeLinked("))
    }

    @Test("an unlink does nothing while a scan runs, and its button waits for the scan")
    func unlinkWaitsForTheScan() async throws {
        let drive = Self.tempDrive()
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        let model = drive.appending(path: "a.stl")
        try LinkedScanTests.model(model)
        try await Self.withLinkedBook([drive], rows: [Self.linkedRow("PF-a", model)]) { shop, url async throws in
            shop.libraryMoveBusy = true
            await shop.unlinkFolder(drive.standardizedFileURL.path)
            shop.libraryMoveBusy = false
            #expect(try diskIds(url) == ["PF-a"])
            #expect(Self.strings(try Self.library(url)["linked"]) == [drive.standardizedFileURL.path])
        }
        let settings = try LockRound3Tests.source("LibraryLocationSettings.swift")
        let at = try #require(settings.range(of: "{ unlinking = path }"))
        #expect(settings[at.upperBound...].prefix(200).contains(".disabled(shop.libraryMoveBusy)"))
    }

    /// One write per model was the whole book again for each one a shop made
    /// available offline: the number of writes must not grow with the models.
    @Test("models now on this Mac are filled in a batch, not one write each")
    func fillNowLocalBatches() async throws {
        func writes(models: Int) async throws -> Int {
            let drive = Self.tempDrive()
            defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
            var rows: [JSONValue] = []
            for i in 0..<models {
                let url = drive.appending(path: "m\(i).stl")
                try LinkedScanTests.model(url, size: Double(10 + i))
                rows.append(LibraryEditPerfTests.onlineRow("PF-\(i)", url))
            }
            final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0 }
            let count = Count()
            var asked = 0
            try await Self.withLinkedBook([drive], rows: rows) { shop, url in
                shop.linkedIsOnline = { _ in false }
                let engine = try #require(shop.engine)
                await shop.fillNowLocal(storeURL: url, engine: engine,
                                        owns: { count.lock.withLock { count.n += 1 }; return true },
                                        whoHasIt: { nil }, stop: nil)
                let filled = try diskRows(url).filter {
                    if case .object(let o) = $0 { o["indexedOnline"] == nil } else { false }
                }
                #expect(filled.count == models, "every model now here is filled in")
                asked = count.lock.withLock { count.n }
            }
            return asked
        }
        let one = try await writes(models: 1)
        let five = try await writes(models: 5)
        #expect(one > 0)
        #expect(five == one, "one model asked the book \(one) time(s), five asked \(five)")
    }
}
