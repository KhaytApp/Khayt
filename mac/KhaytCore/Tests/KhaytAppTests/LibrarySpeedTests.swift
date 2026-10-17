import Foundation
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// The library stays quick with thousands of models.
///
/// Measured before the memo (Oct 17 2026, debug build, a synthetic 5,000-model
/// book in 200 groups): one draw of the library screen — the grid, its empty
/// check, the inspector, the toolbar count and the menu bar — filtered, folded
/// and sorted the whole book about ten times, 240–420 ms; a click on a model
/// took 260–300 ms before anything moved; each key typed in the search box
/// 120–490 ms. Each visible tile also asked the disk about its thumbnail twice
/// per draw. After: a redraw that changed nothing 0.1 ms, a click 0.04 ms, a
/// key 16–25 ms.
///
/// COUNTED, NOT TIMED, as ⌘K's test is: a test asserting milliseconds fails on
/// a busy CI runner and teaches people to rerun it. `LibraryMemo.Work` counts
/// the passes, the rows searched and the disk questions, and those numbers do
/// not depend on the machine.
@MainActor
struct LibrarySpeedTests {

    static func row(_ i: Int, name: String? = nil, group: String? = nil, tag: String? = nil) -> JSONValue {
        let title = name ?? "Model \(i) part \(i % 97)"
        var o: [String: JSONValue] = [
            "id": .string(String(format: "PF-%05d", i)), "name": .string(title),
            "createdAt": .number(1_750_000_000_000 + Double(i) * 1000),
            "sourceFile": .object(["filename": .string(title + ".3mf"), "ext": .string("3mf")]),
        ]
        if let group { o["group"] = .string(group) }
        if let tag { o["tags"] = .array([.string(tag)]) }
        return .object(o)
    }

    /// 5,000 models in 200 group paths (40 collections of 5 sets), one in 25
    /// loose — the shape the timings above were taken on.
    static func bigShop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendLibrary((0..<5_000).map {
            row($0, group: $0 % 25 == 0 ? nil : "Collection \($0 % 40)/Set \($0 % 5)", tag: "tag \($0 % 23)")
        })
        shop.clearLibraryFilter()
        shop.search = ""
        shop.librarySort = .name
        shop.shelf = .library(nil)
        shop.libraryFlat = false
        return shop
    }

    /// What one draw of the library screen reads.
    static func draw(_ shop: Shop) {
        _ = shop.shownEntries
        _ = shop.shownFiles.isEmpty
        _ = shop.selectedFiles.count
        _ = shop.selectedFile
        _ = shop.selectedIds
        _ = shop.shownFiles.count
    }

    @Test("a redraw that changed nothing builds nothing, and a click builds nothing either")
    func redrawIsFree() async {
        let shop = await Self.bigShop()
        Self.draw(shop)
        let before = shop.libraryMemo.work
        #expect(shop.shownEntries.count == 240, "40 collections × 5 sets, and the 200 loose models")
        for _ in 0..<20 { Self.draw(shop) }
        #expect(shop.libraryMemo.work == before, "a redraw with nothing changed did work")

        // Clicks: the selection is not an input of the lists.
        let tiles = shop.visibleFiles
        #expect(tiles.count == 200)
        for file in tiles.prefix(10) {
            shop.select(file, modifiers: .replace)
            Self.draw(shop)
            #expect(shop.selectedFile?.id == file.id)
        }
        #expect(shop.libraryMemo.work.builds == before.builds)
        #expect(shop.libraryMemo.work.entryBuilds == before.entryBuilds)
    }

    @Test("each key typed narrows the last answer, and the answer is the one a fresh search gives")
    func typingNarrows() async {
        let shop = await Self.bigShop()
        shop.libraryFlat = true
        Self.draw(shop)
        let start = shop.libraryMemo.work
        var previous = shop.shownFiles.count
        for (n, q) in ["m", "mo", "mod", "model", "model 1", "model 12"].enumerated() {
            shop.search = q
            Self.draw(shop)
            let work = shop.libraryMemo.work
            // The first key starts from the whole book; every later one only
            // from what the key before it found.
            if n == 0 {
                #expect(work.builds == start.builds + 1)
            } else {
                #expect(work.builds == start.builds + 1, "'\(q)' searched the whole book again")
                #expect(work.narrowed == start.narrowed + n)
            }
            let fresh = shop.buildShownFiles(query: SearchText.fold(q)).map(\.id)
            #expect(shop.shownFiles.map(\.id) == fresh, "'\(q)': narrowing changed the answer")
            #expect(shop.shownFiles.count <= previous)
            previous = shop.shownFiles.count
        }
        #expect(previous == 111, "Model 12, 120–129, 1200–1299 and 12000+ — 1 + 10 + 100")
        // Every model's text folded once, however many keys were typed.
        #expect(shop.libraryMemo.work.folds == 5_000)

        // Rubbing a letter out is a new search, not a narrower one.
        shop.search = "model 1"
        Self.draw(shop)
        #expect(shop.libraryMemo.work.builds == start.builds + 2)
        #expect(shop.shownFiles.count == 1_111)
    }

    @Test("narrowing folds Arabic as the search always has")
    func narrowingFoldsArabic() async {
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendLibrary([Self.row(1, name: "دلة أحمد"), Self.row(2, name: "دلة احمد الكبيرة"),
                             Self.row(3, name: "مكتبة"), Self.row(4, name: "مكتبه ١٢"), Self.row(5, name: "Dallah")])
        shop.clearLibraryFilter()
        shop.shelf = .library(nil)
        shop.libraryFlat = true
        for q in ["ا", "اح", "احم", "احمد"] {
            shop.search = q
            let fresh = shop.buildShownFiles(query: SearchText.fold(q)).map(\.id)
            #expect(shop.shownFiles.map(\.id) == fresh)
        }
        #expect(Set(shop.shownFiles.map(\.id)) == ["PF-00001", "PF-00002"])
        shop.search = "مكتب"
        shop.search = "مكتبة"
        #expect(Set(shop.shownFiles.map(\.id)) == ["PF-00003", "PF-00004"])
        shop.search = "12"
        #expect(shop.shownFiles.map(\.id) == ["PF-00004"], "١٢ typed in the book is found by 12")
    }

    @Test("a change to the book, a filter or the order rebuilds; nothing else does")
    func invalidation() async {
        let shop = await Self.bigShop()
        Self.draw(shop)
        var builds = shop.libraryMemo.work.builds

        shop.libraryTag = "tag 3"
        Self.draw(shop)
        #expect(shop.libraryMemo.work.builds == builds + 1)
        #expect(shop.shownFiles.allSatisfy { $0.tags == ["tag 3"] })
        builds += 1

        shop.librarySort = .added
        Self.draw(shop)
        #expect(shop.libraryMemo.work.builds == builds + 1)
        builds += 1

        // An edit to one model is a new book.
        var rows = (0..<5_000).map {
            Self.row($0, group: $0 % 25 == 0 ? nil : "Collection \($0 % 40)/Set \($0 % 5)", tag: "tag \($0 % 23)")
        }
        rows[3] = Self.row(3, name: "Renamed", group: "Collection 3/Set 3", tag: "tag 3")
        shop.pretendLibrary(rows)
        Self.draw(shop)
        #expect(shop.libraryMemo.work.builds == builds + 1)
        #expect(shop.shownFiles.contains { $0.title == "Renamed" })
        builds = shop.libraryMemo.work.builds

        // Into a group and out again.
        shop.libraryTag = nil
        shop.shelf = .library("Collection 3/Set 3")
        Self.draw(shop)
        #expect(shop.shownFiles.allSatisfy { $0.groupName == "Collection 3/Set 3" })
        #expect(!shop.shownFiles.isEmpty)
        shop.shelf = .library(nil)
        Self.draw(shop)
        #expect(shop.shownEntries.count == 240)
    }

    @Test("the hidden-selection rule holds through the memo: a model in a group tile is never selected")
    func selectionStaysVisible() async {
        let shop = await Self.bigShop()
        Self.draw(shop)
        shop.selectAllShown()
        #expect(shop.selectedIds.count == 200, "only the loose models are tiles at the top")
        #expect(shop.selectedFiles.allSatisfy { $0.groupName == nil })
        // In the order they are drawn.
        #expect(shop.selectedFiles.map(\.id) == shop.visibleFiles.map(\.id))
        // A model that is inside a folder tile, put in the selection by hand,
        // is not selected.
        let hidden = shop.files.first { $0.groupName != nil }!
        shop.fileSelection.insert(hidden.id)
        #expect(!shop.selectedIds.contains(hidden.id))
    }

    @Test("a thumbnail is decoded once, scaled down, and the cache stays bounded")
    func thumbnailStoreIsBounded() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 2,000-pixel picture: drawn into a tile, it is decoded at 640.
        let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2_000, pixelsHigh: 1_000,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(big.representation(using: .png, properties: [:]))
        let url = dir.appending(path: "big.png")
        try png.write(to: url)

        let store = ThumbnailStore()
        let first = try #require(await store.image(for: .file(url)))
        #expect(first.size.width == 640 && first.size.height == 320)
        _ = await store.image(for: .file(url))
        #expect(await store.decodes == 1, "the second ask decoded again")

        for i in 0..<(ThumbnailStore.limit + 20) {
            let each = dir.appending(path: "p\(i).png")
            try png.write(to: each)
            _ = await store.image(for: .file(each))
        }
        #expect(await store.count <= ThumbnailStore.limit)
    }
}

/// In `LibraryEditPerfTests`, the one serialised suite that may set the test
/// support folder (a single global).
extension LibraryEditPerfTests {

    @Test("the disk is asked about a thumbnail once per model, until the library is opened again")
    func diskAskedOnce() async throws {
        try await withPerfBook(PerfBook.synthesize(models: 60)) { shop, _ in
            let roots = try #require(shop.libraryRoots?.roots)
            shop.shelf = .library(nil)
            let models = Array(shop.files.filter { !($0.userPhoto ?? "").hasPrefix("data:") }.prefix(40))
            // A picture on disk for every other one.
            for file in models.enumerated().filter({ $0.offset % 2 == 0 }).map(\.element) {
                let dir = URL(fileURLWithPath: roots[0]).appending(path: LibraryLocation.itemDirName(file.id))
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appending(path: file.thumbFile ?? "thumb.jpg"))
            }
            let start = shop.libraryMemo.work.diskChecks
            var answers: [String: Bool] = [:]
            for _ in 0..<5 {
                for file in models { answers[file.id] = shop.thumbnail(for: file) != nil }
            }
            #expect(shop.libraryMemo.work.diskChecks == start + 40, "five draws asked the disk more than once a model")
            #expect(answers.values.filter { $0 }.count == 20)

            // Opened again: asked again, once.
            shop.shelf = .dashboard
            shop.shelf = .library(nil)
            for file in models { _ = shop.thumbnail(for: file) }
            #expect(shop.libraryMemo.work.diskChecks == start + 80)

            // A model whose record changed is asked again; the others are not.
            shop.toggleFavourite(models[1])
            await shop.settleLibraryWrites()
            let changed = try #require(shop.files.first { $0.id == models[1].id })
            for file in models { _ = shop.thumbnail(for: shop.files.first { $0.id == file.id } ?? file) }
            #expect(shop.libraryMemo.work.diskChecks == start + 81)
            #expect(shop.thumbnail(for: changed) == nil)
        }
    }
}
