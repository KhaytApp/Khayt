import Foundation
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// Library stage 3b on the Mac: stacks drawn and written, Find Similar as a
/// focus through the one matcher, the viewer's sides and plates, and a model
/// bundle out and back in.
@MainActor
struct LibraryStage3bTests {

    static func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.clearLibraryFilter()
        shop.search = ""
        shop.shelf = .library(nil)
        shop.libraryFlat = true
        await shop.settleLibraryFacets()
        return shop
    }

    static func source(_ name: String) throws -> String {
        try String(contentsOf: GroupFromRightClickTests.source(name), encoding: .utf8)
    }

    // MARK: Stacks, drawn

    /// The sample's rows with the first three Kings stacked, the first on top.
    static func stackedKings(_ rows: [JSONValue]) -> [JSONValue] {
        rows.map { row in
            guard case .object(var o) = row, case .string(let id)? = o["id"],
                  ["PF-sample-king-1", "PF-sample-king-2", "PF-sample-king-3"].contains(id) else { return row }
            o["stackId"] = .string("ST-kings")
            if id == "PF-sample-king-1" { o["stackTop"] = .bool(true) }
            return .object(o)
        }
    }

    @Test("a stack is one tile with its count; every count stays a count of models and agrees")
    func stackDrawn() async throws {
        let shop = await Self.sample()
        let before = shop.shownFiles.count
        shop.shelf = .library("Saudi Kings")
        let tilesBefore = shop.shownEntries.count
        let rows = Self.stackedKings(shop.libraryRows)
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        await shop.settleLibraryFacets()

        #expect(shop.shownEntries.count == tilesBefore - 2, "three Kings did not become one tile")
        let tile = try #require(shop.libraryStackTile("PF-sample-king-1"))
        #expect(tile.isStack && tile.total == 3 && tile.shown.count == 3)
        #expect(Cell.stackBadge(tile, words: shop.words) == shop.words.numeral(3))
        #expect(!shop.visibleFiles.contains { $0.id == "PF-sample-king-2" }, "a closed stack's member is selectable")

        // Counts are of models: the grid's own, a saved search's, and the folder's.
        shop.shelf = .library(nil)
        #expect(shop.shownFiles.count == before)
        #expect(shop.libraryCount(LibraryQuery()) == before)

        // A search that finds one variant still shows the stack — as that one,
        // saying 1 of 3 — and the count is the one model found.
        shop.search = "Faisal"
        #expect(shop.shownFiles.map(\.id) == ["PF-sample-king-3"])
        let one = try #require(shop.libraryStackTile("PF-sample-king-3"))
        #expect(one.shown == ["PF-sample-king-3"] && one.total == 3)
        #expect(Cell.stackBadge(one, words: shop.words).contains(shop.words.numeral(3)))
        var q = LibraryQuery(); q.text = "Faisal"
        #expect(shop.libraryCount(q) == 1)
        shop.search = ""

        // Open: the members inline after the cover, and selectable.
        shop.shelf = .library("Saudi Kings")
        shop.toggleStackOpen("ST-kings")
        let ids = shop.shownEntries.compactMap { if case .file(let f) = $0 { f.id } else { nil } }
        let at = try #require(ids.firstIndex(of: "PF-sample-king-1"))
        #expect(Array(ids[at...].prefix(3)) == ["PF-sample-king-1", "PF-sample-king-2", "PF-sample-king-3"])
        #expect(shop.libraryStackTile("PF-sample-king-2")?.inside == true)
        shop.fileSelection = ["PF-sample-king-2"]
        // Closed again: the hidden member leaves the selection.
        shop.toggleStackOpen("ST-kings")
        #expect(shop.fileSelection.isEmpty, "a member hidden in a closed stack stayed selected")

        // A Health or Find Similar focus draws every model alone.
        shop.shelf = .library(nil)
        shop.libraryHealthFocus = LibraryHealthFocus(kind: .looksSame, ids: ["PF-sample-king-1", "PF-sample-king-2"])
        #expect(shop.shownEntries.count == 2 && shop.libraryStackTile("PF-sample-king-1") == nil)
        shop.libraryHealthFocus = nil
    }

    @Test("a stack of one (its mate deleted on another machine) is a plain model")
    func stackOfOne() async {
        let shop = await Self.sample()
        let rows = shop.libraryRows.map { row -> JSONValue in
            guard case .object(var o) = row, o["id"] == .string("PF-sample-vase") else { return row }
            o["stackId"] = .string("ST-alone")
            return .object(o)
        }
        shop.pretendLibrary(rows)
        #expect(shop.libraryStackTile("PF-sample-vase") == nil)
        #expect(shop.stackOf(shop.files.first { $0.id == "PF-sample-vase" }!) == nil)
    }

    @Test("the sample suggests stacking nothing it should not; a suggestion's reason has words")
    func suggestionsOnTheSample() async {
        let shop = await Self.sample()
        for s in shop.stackSuggestions() {
            #expect(s.ids.count >= 2)
            let key = Shop.stackReasonKey(s.reason)
            #expect(Words.own[key]?["en"]?.isEmpty == false && Words.own[key]?["ar"]?.isEmpty == false)
        }
    }

    // MARK: Find similar

    @Test("Find Similar is a focus through the one matcher: the model first, its chip counts the grid")
    func findSimilar() async throws {
        let shop = await Self.sample()
        let king = try #require(shop.files.first { $0.id == "PF-sample-king-1" })
        shop.search = "falcon"
        shop.findSimilar(to: king)
        let focus = try #require(shop.libraryHealthFocus)
        #expect(shop.search.isEmpty, "the search stayed on and hid the matches")
        #expect(shop.shownFiles.first?.id == king.id)
        #expect(shop.shownFiles.map(\.id) == focus.ids, "the grid is not the ranked list")
        #expect(focus.ids.count == shop.shownFiles.count, "the chip's count is not the grid's")
        #expect(Set(focus.ids).isSuperset(of: ["PF-sample-king-2", "PF-sample-king-3"]), "the other Kings are not similar")
        #expect(focus.note == nil, "no King shares the first one's key, so no mirror caveat")
        #expect(shop.fileSelection == [king.id])
        // Through `libraryMatcher`: the same answer the matcher gives with that focus.
        let match = shop.libraryMatcher(shop.libraryQuery, group: nil, focus: Set(focus.ids))
        #expect(Set(shop.files.filter(match).map(\.id)) == Set(focus.ids))
        shop.clearLibraryFilter()
        #expect(shop.libraryHealthFocus == nil)
    }

    @Test("a same-shape match brings Library Health's mirror caveat with it")
    func similarMirror() async throws {
        let shop = await Self.sample()
        let twin = shop.libraryRows.map { row -> JSONValue in
            guard case .object(var o) = row, o["id"] == .string("PF-sample-king-2") else { return row }
            o["geometryKey"] = .string("6290060:115836.6:200x200x4.56")
            return .object(o)
        }
        shop.pretendLibrary(twin)
        let king = try #require(shop.files.first { $0.id == "PF-sample-king-1" })
        let ranked = shop.similar(to: king)
        #expect(ranked.first?.id == "PF-sample-king-2" && ranked.first?.mirrorCaveat == true)
        shop.findSimilar(to: king)
        #expect(shop.libraryHealthFocus?.note == "mac.lh_mirror_note")
        shop.clearLibraryFilter()
    }

    @Test("Find Similar and the stack items are on the right-click menu, the Model menu and the inspector")
    func wired() throws {
        let actions = try Self.source("FileActions.swift")
        #expect(actions.contains("shop.findSimilar(to: file)") && actions.contains("StackActions(file: file, shop: shop, picked: picked)"))
        let menus = try Self.source("Menus.swift")
        for needle in ["shop.findSimilarToSelection()", "shop.stackSelection()", "shop.unstackSelection()",
                       "shop.exportModelBundle()", "shop.chooseModelBundle()", "ModelViewCommands()"] {
            #expect(menus.contains(needle), "\(needle) is not in the menu bar")
        }
        let inspector = try Self.source("LibraryInspector.swift")
        #expect(inspector.contains("StackSection(shop: shop, file: file)") && inspector.contains("ModelViewer(shop: shop, file: file)"))
        // Every write goes through the gated, undoable library edit.
        let stacks = try Self.source("Shop+LibraryStacks.swift")
        #expect(stacks.contains("editFiles(Set(patches.keys)"))
        #expect(!stacks.contains("StoreWriter."), "a stack write went round editFiles")
    }

    // MARK: The viewer

    static func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-3b-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The box of what was drawn: the opaque pixels' extent, as fractions.
    static func extent(_ png: Data) throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let rep = try #require(NSBitmapImageRep(data: png))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return (minX, maxX, minY, maxY)
    }

    @Test("front, top and side each draw the box's own two sides")
    func sides() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appending(path: "slab.stl")
        // 60 wide (X), 15 deep (Y), 30 tall (Z).
        try MeshTests.binarySTL(MeshTests.boxFacets(60, 15, 30)).write(to: stl)
        func ratio(_ angle: ModelViewAngle) throws -> Double {
            let drawn = try #require(try MeshPreview.render(stl, size: 96, angle: angle))
            #expect(drawn.plates.isEmpty && drawn.plate == nil, "an STL has no plates")
            let e = try Self.extent(drawn.png)
            return Double(e.maxX - e.minX + 1) / Double(e.maxY - e.minY + 1)
        }
        #expect(abs(try ratio(.front) - 2.0) < 0.15, "front is X by Z")
        #expect(abs(try ratio(.top) - 4.0) < 0.4, "top is X by Y")
        #expect(abs(try ratio(.side) - 0.5) < 0.08, "side is Y by Z")
        #expect(try MeshPreview.png(of: stl, size: 64) != nil, "the tile's picture still draws")
    }

    @Test("the front view is not a mirror image: what is on the right is drawn on the right")
    func notMirrored() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appending(path: "ell.stl")
        // A low block on the left and a tall tower at +X.
        try MeshTests.binarySTL(MeshTests.boxFacets(30, 10, 5)
                                + MeshTests.boxFacets(10, 10, 40, originX: 30)).write(to: stl)
        let drawn = try #require(try MeshPreview.render(stl, size: 80, angle: .front))
        let rep = try #require(NSBitmapImageRep(data: drawn.png))
        let e = try Self.extent(drawn.png)
        // The top row of ink is the tower's: it must be at the right.
        var topInk: [Int] = []
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: e.minY + 1)?.alphaComponent ?? 0) > 0.5 { topInk.append(x) }
        let mid = (e.minX + e.maxX) / 2
        #expect(!topInk.isEmpty && topInk.allSatisfy { $0 > mid }, "the tower at +X was drawn on the left")
    }

    /// A 3MF with two plates: a cube on plate 1, a tall post on plate 2 —
    /// the snapshot scene's own.
    static func twoPlates(_ dir: URL) throws -> URL {
        let url = dir.appending(path: "two-plates.3mf")
        try Snapshot.twoPlateProject(at: url)
        return url
    }

    @Test("a two-plate 3MF offers both plates and draws one at a time")
    func plates() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.twoPlates(dir)
        let first = try #require(try MeshPreview.render(url, size: 64, angle: .front))
        #expect(first.plates == [1, 2] && first.plate == 1)
        let second = try #require(try MeshPreview.render(url, size: 64, angle: .front, plate: 2))
        #expect(second.plate == 2)
        func ratio(_ d: MeshPreview.Drawn) throws -> Double {
            let e = try Self.extent(d.png)
            return Double(e.maxX - e.minX + 1) / Double(e.maxY - e.minY + 1)
        }
        #expect(abs(try ratio(first) - 1) < 0.1, "plate 1 is the cube alone")
        #expect(abs(try ratio(second) - 1.0 / 6) < 0.06, "plate 2 is the post alone")
        // A plate the file does not have falls back to the first.
        #expect(try MeshPreview.render(url, size: 32, plate: 9)?.plate == 1)
    }

    @Test("⌥⌘1 to ⌥⌘4 are the four sides, and the viewer draws only what it reads")
    func viewerWords() throws {
        let menus = try Self.source("Menus.swift")
        for n in 1...4 { #expect(menus.contains("keyboardShortcut(\"\(n)\", modifiers: [.command, .option])")) }
        for angle in ModelViewAngle.allCases {
            #expect(Words.own[angle.key]?["en"]?.isEmpty == false && Words.own[angle.key]?["ar"]?.isEmpty == false)
        }
    }
    // MARK: The snapshot scene

    @Test("the stage 3b scene's data shows what it says: a stack, a shape suggestion, a mirror note, two plates")
    func sceneData() async throws {
        let shop = await Self.sample()
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appending(path: "two-plates.3mf")
        try Snapshot.twoPlateProject(at: project)
        let rows = Snapshot.stage3bRows(shop.libraryRows, project: project)
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.shelf = .library("Saudi Kings")
        #expect(shop.libraryStackTile("PF-sample-king-1")?.isStack == true)
        let khalid = try #require(shop.files.first { $0.id == "PF-sample-king-4" })
        #expect(shop.stackSuggestion(for: khalid)?.reason == .sameShape, "no mirror caveat on the Variants shot")
        let plates = try #require(shop.files.first { $0.id == Snapshot.stage3bProject })
        let url = try #require(shop.modelFile(for: plates), "the viewer shot has nothing to draw")
        #expect(ModelViewer.canDraw(plates))
        #expect(try MeshPreview.render(url, size: 32)?.plates == [1, 2])
        shop.findSimilar(to: khalid)
        #expect(shop.libraryHealthFocus?.note == "mac.lh_mirror_note")
        shop.clearLibraryFilter()
        // The hook: its own `if`, ending the run.
        let app = try Self.source("KhaytApp.swift")
        let hook = try #require(app.range(of: "KHAYT_SNAPSHOT_LIBSTAGE3B"))
        let body = String(app[hook.upperBound...].prefix(300))
        #expect(body.contains("captureLibraryStage3b(shop, into: dir, dark: dark)")
                && body.contains("NSApp.terminate(nil)") && body.contains("return"))
    }

    // MARK: Old mesh-drawn thumbnails

    static func libraryFile(_ o: [String: JSONValue]) throws -> LibraryFile {
        try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(o)))
    }

    @Test("only a picture this app's renderer drew is a candidate; photos, 3MF previews and Electron's are not")
    func redrawCandidates() throws {
        func file(_ ext: String, _ thumb: String?, _ source: String?) throws -> LibraryFile {
            var o: [String: JSONValue] = ["id": .string("x"), "name": .string("x"),
                                          "sourceFile": .object(["ext": .string(ext), "filename": .string("m." + ext)])]
            if let thumb { o["thumbFile"] = .string(thumb) }
            if let source { o["thumbSource"] = .string(source) }
            return try Self.libraryFile(o)
        }
        #expect(Shop.mayBeMeshDrawn(try file("stl", "thumb.png", "embedded")), "an import's drawing")
        #expect(Shop.mayBeMeshDrawn(try file("obj", "thumb.png", "mesh")), "the --thumbnails pass")
        #expect(!Shop.mayBeMeshDrawn(try file("stl", "thumb.png", "render")), "Electron's render")
        #expect(!Shop.mayBeMeshDrawn(try file("3mf", "thumb.png", "embedded")), "a 3MF's own preview")
        #expect(!Shop.mayBeMeshDrawn(try file("stl", "thumb.jpg", "embedded")))
        #expect(!Shop.mayBeMeshDrawn(try file("stl", nil, nil)))
    }

    @Test("an old drawing is drawn again once, and marked; a current one is left alone")
    func redrawOnce() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appending(path: "m.stl")
        try MeshTests.binarySTL(MeshTests.boxFacets(30, 10, 5) + MeshTests.boxFacets(10, 10, 40, originX: 30)).write(to: model)
        let thumb = dir.appending(path: "thumb.png")
        let old = Data("not the new picture".utf8)
        try old.write(to: thumb)
        #expect(MeshPreview.renderVersion(of: thumb) == 0)
        #expect(Shop.redrawIfOld(thumbnail: thumb, model: model))
        #expect(try Data(contentsOf: thumb) != old && NSImage(contentsOf: thumb) != nil)
        #expect(MeshPreview.renderVersion(of: thumb) == MeshPreview.renderVersion)
        let drawn = try Data(contentsOf: thumb)
        #expect(!Shop.redrawIfOld(thumbnail: thumb, model: model), "a current picture was drawn again")
        #expect(try Data(contentsOf: thumb) == drawn)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".thumb-redraw") })
        // A redrawn picture's cache key differs, and it still decodes by path.
        var parts = try #require(URLComponents(url: thumb, resolvingAgainstBaseURL: false))
        parts.fragment = "r1"
        #expect(ThumbnailStore.decode(.file(try #require(parts.url)), maxPixels: 64) != nil)
    }
}

// MARK: - Writes, in the serialised suite that owns the test support folder

extension LibraryEditPerfTests {

    /// Eight models; the first three Dragons in one group, a Vase beside them.
    static func dragonBook() -> [String: JSONValue] {
        var root = PerfBook.synthesize(models: 8)
        guard case .array(var rows)? = root["printFiles"] else { return root }
        let names = ["Dragon", "Dragon supportless", "Dragon 150%", "Vase"]
        for i in 0..<4 {
            guard case .object(var o) = rows[i] else { continue }
            o["name"] = .string(names[i])
            o["folder"] = .string("Beasts")
            o["group"] = .string("Beasts")
            rows[i] = .object(o)
        }
        root["printFiles"] = .array(rows)
        return root
    }

    @Test("stacking a suggestion writes two fields per member, and Undo of Unstack puts them back")
    func stackRoundTrip() async throws {
        try await withPerfBook(Self.dragonBook()) { shop, url in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            shop.clearLibraryFilter()
            shop.shelf = .library("Beasts")
            func record(_ id: String) throws -> [String: JSONValue]? {
                for case .object(let o) in try diskRows(url) where o["id"] == .string(id) { return o }
                return nil
            }
            let dragon = try #require(shop.files.first { $0.title == "Dragon" })
            let suggestion = try #require(shop.stackSuggestion(for: dragon))
            #expect(suggestion.reason == .sameName && suggestion.ids.count == 3)
            let tilesBefore = shop.shownEntries.count
            let models = shop.shownFiles.count

            undo.beginUndoGrouping()
            #expect(shop.acceptStackSuggestion(suggestion, cover: dragon.id))
            undo.endUndoGrouping()
            await shop.settleLibraryWrites()
            let stack = try #require(try record(dragon.id)?["stackId"])
            #expect(try record(dragon.id)?["stackTop"] == .bool(true))
            for id in suggestion.ids where id != dragon.id {
                #expect(try record(id)?["stackId"] == stack)
                #expect(try record(id)?["stackTop"] == nil, "only the cover is marked")
            }
            #expect(shop.shownEntries.count == tilesBefore - 2)
            #expect(shop.shownFiles.count == models, "stacking changed a count of models")

            guard case .string(let sid) = stack else { Issue.record("not a string"); return }
            undo.beginUndoGrouping()
            #expect(shop.unstack(sid))
            undo.endUndoGrouping()
            await shop.settleLibraryWrites()
            for id in suggestion.ids { #expect(try record(id)?["stackId"] == nil) }
            #expect(shop.shownEntries.count == tilesBefore)

            undo.undo()
            await shop.settleLibraryWrites()
            for id in suggestion.ids { #expect(try record(id)?["stackId"] == stack, "Undo did not restack \(id)") }
            #expect(try record(dragon.id)?["stackTop"] == .bool(true))
            shop.undoManager = nil
        }
    }

    @Test("a bundle carries the model and an allowlist; the same bytes are refused back in, new ones come in filled")
    func bundleRoundTrip() async throws {
        var root = Self.dragonBook()
        guard case .array(var rows)? = root["printFiles"], case .object(var first) = rows[4] else { return }
        let id = try #require(Shop.recordId(.object(first)))
        first["printNextAt"] = .string("2026-10-01T00:00:00.000Z")
        first["printNextFor"] = .string("Noura Private")
        first["licence"] = .string("commercial")
        first["licenceCode"] = .string("SECRET-LICENCE-123")
        first["category"] = .string("Toys")
        first["testedNotes"] = .string("Brim on the first layer")
        first.removeValue(forKey: "externalPath")
        // The library knows these bytes, as it knows any file it imported.
        let stl = MeshTests.binarySTL(MeshTests.boxFacets(10, 10, 10))
        let hashed = FileManager.default.temporaryDirectory.appending(path: "khayt-3b-\(UUID().uuidString).stl")
        try stl.write(to: hashed)
        defer { try? FileManager.default.removeItem(at: hashed) }
        first["contentHash"] = .string(try #require(try LibraryImport.contentHash(of: hashed)))
        first["originalName"] = .string("dragon.stl")
        first["sourceFile"] = .object(["filename": .string("dragon.stl"), "originalName": .string("dragon.stl"),
                                       "ext": .string("stl"), "kind": .string("model"), "size": .number(684)])
        rows[4] = .object(first)
        root["printFiles"] = .array(rows)
        try await withPerfBook(root) { shop, _ in
            let file = try #require(shop.files.first { $0.id == id })
            let primary = try #require(shop.libraryRoots?.primary)
            let dir = URL(fileURLWithPath: primary).appending(path: LibraryLocation.itemDirName(file.id))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let model = dir.appending(path: file.sourceFile?.filename ?? "model.stl")
            try stl.write(to: model)
            try Data("%PDF-1.4 guide".utf8).write(to: dir.appending(path: "guide.pdf"))
            #expect(shop.modelFile(for: file) != nil)

            let data = try #require(try shop.modelBundle(file, includePrice: false))
            for secret in ["Noura Private", "SECRET-LICENCE-123", primary] {
                #expect(data.range(of: Data(secret.utf8)) == nil, "\(secret) left the shop in the bundle")
            }
            let out = FileManager.default.temporaryDirectory.appending(path: "khayt-3b-\(UUID().uuidString).khaytbundle")
            defer { try? FileManager.default.removeItem(at: out) }
            try data.write(to: out)
            let opened = try Shop.unpackBundle(out)
            defer { try? FileManager.default.removeItem(at: opened.scratch) }
            #expect(opened.manifest.title == file.title && opened.manifest.fields["category"] == .string("Toys"))
            #expect(opened.others.contains { $0.lastPathComponent == "guide.pdf" }, "the guide was not packed")
            #expect(opened.manifest.price == nil)

            // The same bytes: refused, as any import of a model already here.
            let count = shop.files.count
            await shop.importModelBundle(out)
            #expect(shop.files.count == count)
            #expect(shop.importProblem != nil)

            // New bytes under the same manifest: a new model, filled from it.
            let entries = try Zip.entries(of: out)
            let m = try #require(entries.first { $0.name == ModelBundle.manifestName })
            let fresh = FileManager.default.temporaryDirectory.appending(path: "khayt-3b-\(UUID().uuidString).khaytbundle")
            defer { try? FileManager.default.removeItem(at: fresh) }
            try ZipWrite.archive([
                ZipWrite.Member("model/other.stl", MeshTests.binarySTL(MeshTests.boxFacets(12, 14, 16))),
                ZipWrite.Member(ModelBundle.manifestName, try Zip.data(of: m, in: out)),
            ]).write(to: fresh)
            await shop.importModelBundle(fresh)
            await shop.settleLibraryWrites()
            #expect(shop.files.count == count + 1, "\(shop.importProblem ?? "")")
            let added = try #require(shop.files.first { $0.title == file.title && $0.id != file.id })
            #expect(added.category == "Toys" && added.testedNotes == "Brim on the first layer")
            #expect(added.printNextNote == nil && added.licenceCode == nil, "shop-private fields came back in")

            // A bundle that names a way out of its folder is refused before a byte is written.
            let evil = FileManager.default.temporaryDirectory.appending(path: "khayt-3b-\(UUID().uuidString).khaytbundle")
            defer { try? FileManager.default.removeItem(at: evil) }
            try ZipWrite.archive([
                ZipWrite.Member("model/../../escape.stl", MeshTests.binarySTL(MeshTests.boxFacets(1, 1, 1))),
                ZipWrite.Member(ModelBundle.manifestName, try Zip.data(of: m, in: out)),
            ]).write(to: evil)
            await shop.importModelBundle(evil)
            #expect(shop.importProblem == shop.words.callIt("mac.mb_bad_name", ["name": .string("model/../../escape.stl")]))
            #expect(shop.files.count == count + 1)
        }
    }

    @Test("old drawings are redrawn as their tiles are drawn — never by a pass over the library")
    func redrawLazily() async throws {
        var root = Self.dragonBook()
        guard case .array(var rows)? = root["printFiles"] else { return }
        for i in 0..<3 {
            guard case .object(var o) = rows[i] else { continue }
            o.removeValue(forKey: "externalPath")
            o["sourceFile"] = .object(["filename": .string("m.stl"), "ext": .string("stl"), "kind": .string("model")])
            o["thumbFile"] = .string("thumb.png")
            o["thumbSource"] = .string(i == 2 ? "render" : "embedded")
            o["userPhoto"] = .string("")
            rows[i] = .object(o)
        }
        root["printFiles"] = .array(rows)
        try await withPerfBook(root) { shop, _ in
            let primary = try #require(shop.libraryRoots?.primary)
            let ids = ["pf000000000000", "pf000000000001", "pf000000000002"]
            var thumbs: [String: URL] = [:]
            for id in ids {
                let dir = URL(fileURLWithPath: primary).appending(path: LibraryLocation.itemDirName(id))
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try MeshTests.binarySTL(MeshTests.boxFacets(10, 20, 30)).write(to: dir.appending(path: "m.stl"))
                try Data("old".utf8).write(to: dir.appending(path: "thumb.png"))
                thumbs[id] = dir.appending(path: "thumb.png")
            }
            shop.forgetLibraryDisk()
            let files = try ids.map { id in try #require(shop.files.first { $0.id == id }) }
            let start = shop.libraryMemo.work.thumbRedraws
            // Everything that is not a tile being drawn asks nothing.
            for f in shop.files { _ = shop.thumbnail(for: f) }
            _ = shop.phoneLibrary(q: "", folder: "", offset: 0, limit: 500)
            #expect(shop.libraryMemo.thumbQueue.isEmpty && shop.libraryMemo.thumbChecked.isEmpty,
                    "a read that draws nothing queued a redraw")
            // Drawing the three tiles: the two this app drew are redrawn, Electron's is not.
            for f in files { _ = shop.displayedThumbnail(for: f) }
            while shop.libraryMemo.thumbRedrawing { try await Task.sleep(for: .milliseconds(20)) }
            #expect(shop.libraryMemo.work.thumbRedraws - start == 2)
            #expect(try Data(contentsOf: thumbs[ids[0]]!) != Data("old".utf8))
            #expect(try Data(contentsOf: thumbs[ids[2]]!) == Data("old".utf8), "Electron's picture was redrawn")
            // A redrawn tile's source is a new key for the picture cache.
            if case .file(let url)? = shop.thumbnail(for: files[0]) { #expect(url.fragment == "1") }
            else { Issue.record("no picture") }
            // Drawn again this run: not checked twice.
            for f in files { _ = shop.displayedThumbnail(for: f) }
            #expect(shop.libraryMemo.thumbQueue.isEmpty && !shop.libraryMemo.thumbRedrawing)
        }
    }
}
