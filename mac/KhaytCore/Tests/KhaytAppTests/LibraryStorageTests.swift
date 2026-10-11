import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import KhaytApp
import KhaytCore

/// Model files dropped into the library's own folder are adopted where they
/// sit, with the photo that came with them — and nothing the app wrote itself,
/// nothing the shop deleted, and no picture, ever becomes a model.
@MainActor
struct LibraryStorageTests {

    typealias Bench = LibraryImportEndToEndTests.Bench

    // MARK: - Fixtures

    static func model(_ url: URL, size: Double = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MeshTests.binarySTL(MeshTests.boxFacets(size, size, size)).write(to: url)
    }

    /// A real picture ImageIO can decode, in the format its extension says.
    static func picture(_ url: URL, red: Double = 1) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: red, green: 0.3, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(ctx.makeImage())
        let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    static func rows(_ bench: Bench) throws -> [JSONValue] {
        try LibraryImportEndToEndTests.printFiles(in: bench)
    }

    static func adopt(_ bench: Bench, ignored: Set<String> = []) async throws -> Shop.StorageReport {
        await Shop.adoptFromStorage(root: bench.library, rows: try rows(bench), ignored: ignored,
                                    storeURL: bench.store, engine: try KhaytEngine(),
                                    owns: { true }, whoHasIt: { nil }, progress: { _, _, _ in })
    }

    static func record(_ bench: Bench, at file: URL) throws -> [String: JSONValue]? {
        let want = file.resolvingSymlinksInPath().standardizedFileURL.path
        for row in try rows(bench) {
            guard case .object(let o) = row, case .string(let p)? = o["externalPath"] else { continue }
            if URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path == want { return o }
        }
        return nil
    }

    static func write(_ rows: [JSONValue], to bench: Bench) throws {
        let root: [String: JSONValue] = ["printFiles": .array(rows), "settings": .object([:])]
        try JSONEncoder().encode(root).write(to: bench.store)
    }

    // MARK: - What is adopted

    @Test("an untracked model in the library folder is adopted in place: the file stays, the record points at it")
    func untrackedIsAdopted() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let loose = bench.library.appending(path: "dropped.stl")
        let filed = bench.library.appending(path: "Dragons/red/dragon.stl")
        try Self.model(loose, size: 10)
        try Self.model(filed, size: 12)
        let before = try Data(contentsOf: filed)

        let report = try await Self.adopt(bench)
        #expect(report.added == 2)
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(try Data(contentsOf: filed) == before, "the shop's file is exactly where it was")
        let o = try #require(try Self.record(bench, at: filed))
        #expect(o["originalName"] == .string("dragon.stl"))
        #expect(try Self.record(bench, at: loose) != nil)
        // In place: its record folder holds at most a picture, never a copy.
        guard case .string(let id)? = o["id"] else { Issue.record("no id"); return }
        let vault = bench.library.appending(path: LibraryLocation.itemDirName(id))
        let inside = (try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? []
        #expect(!inside.contains { LibraryImport.kinds.contains(($0 as NSString).pathExtension.lowercased()) },
                "a copy of the model went into the vault: \(inside)")
    }

    @Test("a second rescan adds nothing")
    func secondRescanAddsNothing() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        try Self.model(bench.library.appending(path: "a.stl"), size: 10)
        try Self.model(bench.library.appending(path: "Pack/b.stl"), size: 11)
        try Self.model(bench.library.appending(path: "Pack/c.stl"), size: 13)
        #expect(try await Self.adopt(bench).added == 3)
        let count = try Self.rows(bench).count
        let again = try await Self.adopt(bench)
        #expect(again.added == 0 && again.duplicates == 0, "\(again)")
        #expect(try Self.rows(bench).count == count)
        // And the walk itself finds nothing — the adopted files are known by
        // path, so not even re-hashed.
        #expect(Shop.untrackedInStorage(bench.library, rows: try Self.rows(bench), ignored: []).files.isEmpty)
    }

    @Test("a copy of a model the library already holds is a duplicate, not a second record")
    func duplicateByHash() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        try Self.model(bench.library.appending(path: "one.stl"), size: 10)
        try Self.model(bench.library.appending(path: "Copies/one again.stl"), size: 10)
        let report = try await Self.adopt(bench)
        #expect(report.added == 1 && report.duplicates == 1, "\(report)")
    }

    @Test("a folder groups its models the way an import of that folder would")
    func grouping() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.model(root.appending(path: "Saudi Kings/abdulaziz.stl"))
        try Self.model(root.appending(path: "Saudi Kings/faisal.stl"))
        try Self.model(root.appending(path: "Crown/stl/crown.stl"))
        let found = Shop.untrackedInStorage(root, rows: [], ignored: []).files
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0) })
        #expect(byName["abdulaziz.stl"]?.group == "Saudi Kings")
        #expect(byName["crown.stl"]?.group == nil)
        #expect(byName["crown.stl"]?.title == "Crown", "a folder of one model names it")
        // The library's own root is never a group level.
        #expect(!found.contains { ($0.group ?? "").contains(root.lastPathComponent) })
    }

    // MARK: - What is not

    @Test("a record's own file is never re-adopted — by its folder or by its path")
    func recordsOwnFile() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.model(root.appending(path: "PF-abc123/dragon.stl"))
        let linked = root.appending(path: "Loose/adopted.stl")
        try Self.model(linked)
        let rows: [JSONValue] = [
            .object(["id": .string("PF-abc123"), "name": .string("Dragon")]),
            .object(["id": .string("PF-def456"), "externalPath": .string(linked.path)]),
        ]
        #expect(Shop.untrackedInStorage(root, rows: rows, ignored: []).files.isEmpty)
    }

    @Test("versions, sidecars, thumbs, group pictures and a deleted record's folder are not models")
    func appsOwnFiles() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // A record's folder: the model, a version beside it (print-versions
        // keeps them there), a converted copy, the sidecar, the picture.
        try Self.model(root.appending(path: "PF-live/dragon.3mf"))
        try Self.model(root.appending(path: "PF-live/dragon-small.3mf"))
        try Self.model(root.appending(path: "PF-live/dragon (Snapmaker U1).3mf"))
        try Data("{}".utf8).write(to: root.appending(path: "PF-live/big.3mf.cloud"))
        try Self.picture(root.appending(path: "PF-live/thumb.png"))
        // A record folder whose record is gone — deleted on the other Mac.
        try Self.model(root.appending(path: "PF-deletedElsewhere/old.stl"))
        // The groups' pictures, and a sidecar loose at the root.
        try Self.picture(root.appending(path: "group-pictures/kings.jpg"))
        try Data("{}".utf8).write(to: root.appending(path: "stray.stl.cloud"))
        // Hidden, and the Trash.
        try Self.model(root.appending(path: ".hidden.stl"))
        try Self.model(root.appending(path: ".Trash/binned.stl"))
        let rows: [JSONValue] = [.object(["id": .string("PF-live")])]
        let found = Shop.untrackedInStorage(root, rows: rows, ignored: []).files
        #expect(found.isEmpty, "\(found.map(\.url.lastPathComponent))")
    }

    @Test("a symlink is not adopted, file or folder")
    func symlinks() throws {
        let root = try LibraryImportTests.tempDir()
        let elsewhere = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
        try Self.model(elsewhere.appending(path: "outside.stl"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.stl"),
                                                   withDestinationURL: elsewhere.appending(path: "outside.stl"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Away"), withDestinationURL: elsewhere)
        #expect(Shop.untrackedInStorage(root, rows: [], ignored: []).files.isEmpty)
    }

    @Test("a model the shop deleted after adoption is not adopted again")
    func deletedStaysDeleted() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "gone.stl")
        try Self.model(file)
        let json: [String: Any] = ["id": "PF-x", "name": "gone",
                                   "externalPath": file.resolvingSymlinksInPath().path]
        let record = try JSONDecoder().decode(LibraryFile.self, from: JSONSerialization.data(withJSONObject: json))
        let remembered = Shop.notAdoptedAfterDeleting([record], roots: [root.resolvingSymlinksInPath().path],
                                                      already: [])
        let ignored = Set(remembered.compactMap { if case .string(let s) = $0 { s } else { nil } })
        #expect(ignored.count == 1)
        #expect(Shop.untrackedInStorage(root, rows: [], ignored: ignored).files.isEmpty)
        // A linked folder's model is not a library root's: nothing remembered.
        let linked = try JSONDecoder().decode(LibraryFile.self, from: JSONSerialization.data(withJSONObject:
            ["id": "PF-y", "name": "a", "externalPath": "/Volumes/NAS/a.stl"]))
        #expect(Shop.notAdoptedAfterDeleting([linked], roots: [root.path], already: []).isEmpty)
    }

    @Test("pictures are never models")
    func imagesAreNotModels() throws {
        #expect(ModelPhoto.kinds.isDisjoint(with: LibraryImport.kinds))
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.picture(root.appending(path: "cover.jpg"))
        try Self.picture(root.appending(path: "Shots/1.png"))
        #expect(Shop.untrackedInStorage(root, rows: [], ignored: []).files.isEmpty)
        #expect(Shop.modelsUnder([root], skippingAll: []).isEmpty)
    }

    @Test("the walk stops at its cap and says so")
    func capped() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<5 { try Self.model(root.appending(path: "m\(i).stl"), size: Double(10 + i)) }
        let found = Shop.untrackedInStorage(root, rows: [], ignored: [], adoptCap: 3)
        #expect(found.files.count == 3 && found.capped)
    }

    // MARK: - Photos

    @Test("a same-named picture beside the model becomes its userPhoto")
    func siblingPhoto() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let file = bench.library.appending(path: "Shelf/dragon.stl")
        try Self.model(file)
        try Self.model(bench.library.appending(path: "Shelf/knight.stl"), size: 14)
        try Self.picture(bench.library.appending(path: "Shelf/dragon.jpg"))
        let report = try await Self.adopt(bench)
        #expect(report.added == 2 && report.photos == 1, "\(report)")
        let o = try #require(try Self.record(bench, at: file))
        guard case .string(let photo)? = o["userPhoto"] else { Issue.record("no photo"); return }
        #expect(photo.hasPrefix("data:image/jpeg;base64,"))
        // The other model in that folder does not borrow it.
        let knight = try #require(try Self.record(bench, at: bench.library.appending(path: "Shelf/knight.stl")))
        #expect(knight["userPhoto"] == .null)
        #expect(FileManager.default.fileExists(atPath: bench.library.appending(path: "Shelf/dragon.jpg").path),
                "the picture is read, never moved")
    }

    @Test("a Printables-shaped download: the images/ folder's photo goes to its one model")
    func printablesShape() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let file = bench.library.appending(path: "Articulated Dragon/files/dragon_v3.stl")
        try Self.model(file)
        try Self.picture(bench.library.appending(path: "Articulated Dragon/images/IMG_2041.jpg"))
        try Self.picture(bench.library.appending(path: "Articulated Dragon/images/IMG_2042.png"))
        let report = try await Self.adopt(bench)
        #expect(report.added == 1 && report.photos == 1, "\(report)")
        let o = try #require(try Self.record(bench, at: file))
        #expect(o["name"] == .string("Articulated Dragon"))
        guard case .string(let photo)? = o["userPhoto"] else { Issue.record("no photo"); return }
        #expect(photo.hasPrefix("data:image/"))
    }

    @Test("several models in a project share no picture unless it carries one's name")
    func projectOfMany() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = root.appending(path: "Robot/files/head.stl")
        let arm = root.appending(path: "Robot/files/arm.stl")
        try Self.model(head); try Self.model(arm, size: 7)
        try Self.picture(root.appending(path: "Robot/images/cover.jpg"))
        try Self.picture(root.appending(path: "Robot/images/head.png"))
        let found = ModelPhoto.candidates(for: [head, arm], everyModel: [head, arm], boundary: root.appending(path: "Robot"))
        #expect(found[head]?.first?.lastPathComponent == "head.png")
        #expect(found[arm] == nil, "the cover of a forty-part kit is not a picture of every part")
    }

    @Test("a file picked on its own takes only a picture with its own name")
    func pickedAlone() throws {
        let root = try LibraryImportTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "vase.stl")
        try Self.model(file)
        try Self.picture(root.appending(path: "holiday.jpg"))
        #expect(Shop.modelsUnder([file], skippingAll: []).first?.photos.isEmpty == true)
        try Self.picture(root.appending(path: "vase.png"))
        #expect(Shop.modelsUnder([file], skippingAll: []).first?.photos.first?.lastPathComponent == "vase.png")
    }

    @Test("a folder import picks the photo up too, and a picture that will not decode does not fail it")
    func folderImportAndBadPicture() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let pack = bench.dir.appending(path: "Downloads/Lamp")
        let file = pack.appending(path: "lamp.stl")
        try Self.model(file)
        try Data("not a picture".utf8).write(to: pack.appending(path: "lamp.jpg"))
        let incoming = Shop.modelsUnder([pack], skippingAll: [bench.library.path])
        #expect(incoming.first?.photos.count == 1)
        let report = await LibraryImport.addMany(incoming, storeURL: bench.store, libraryRoot: bench.library,
                                                 knownHashes: [], nameOfExisting: { _ in nil },
                                                 engine: try KhaytEngine(), keepOriginal: true,
                                                 owns: { true }, whoHasIt: { nil })
        #expect(report.moved == 1 && report.photos == 0 && report.failures.isEmpty, "\(report)")
        guard case .object(let o)? = try Self.rows(bench).first else { Issue.record("no record"); return }
        #expect(o["userPhoto"] == .null)

        // With a real picture beside it, the same import carries it.
        try Self.picture(pack.appending(path: "lamp.jpg"))
        try Self.model(pack.appending(path: "lamp.stl"), size: 20)
        let again = await LibraryImport.addMany(Shop.modelsUnder([pack], skippingAll: [bench.library.path]),
                                                storeURL: bench.store, libraryRoot: bench.library,
                                                knownHashes: [], nameOfExisting: { _ in nil },
                                                engine: try KhaytEngine(), keepOriginal: true,
                                                owns: { true }, whoHasIt: { nil })
        #expect(again.photos == 1, "\(again)")
    }

    @Test("a userPhoto the shop already set is kept")
    func existingPhotoKept() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let file = bench.library.appending(path: "Mine/owl.stl")
        try Self.model(file)
        try Self.picture(bench.library.appending(path: "Mine/owl.jpg"))
        let theirs = "data:image/jpeg;base64,/9j/shop-took-this"
        try Self.write([.object(["id": .string("PF-owl"), "name": .string("Owl"),
                                 "externalPath": .string(file.path), "userPhoto": .string(theirs)])], to: bench)
        let report = try await Self.adopt(bench)
        #expect(report.added == 0)
        let o = try #require(try Self.record(bench, at: file))
        #expect(o["userPhoto"] == .string(theirs))
    }

    // MARK: - Who may

    @Test("Rescan Storage asks the lock; the load-time pass is the system's")
    func rescanAsks() async throws {
        let shop = await LockRound3Tests.shop()
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)   // viewer
        await shop.rescanStorage()
        #expect(shop.moveProblem == LockRound3Tests.notAllowed(shop))
        #expect(try LockRound3Tests.source("Shop.swift").contains("rescanStorageIfDue()"))
        #expect(try LockRound3Tests.source("LibraryStorage.swift").contains("rescanStorage(byPerson: false)"))
    }
}
