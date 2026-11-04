import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// The library at a real shop's size: ten thousand models, in memory.
///
/// Nov 2026 review of a shop with ~10,000 models (6,500 online-only in a
/// Drive folder): a facet recount made about fifteen passes over the book per
/// keystroke, and `row(for:)` walked every record per question — once per
/// inspector draw, once per model on each of the phone's library pages.
///
/// The clock bounds only catch a runaway; they are printed so a change can be
/// measured before and after (`swift test --filter LibraryTenThousand`).
@MainActor
struct LibraryTenThousandTests {

    static func shop() async -> Shop {
        let shop = await LibrarySmartFolderTests.sample()
        let rows = Snapshot.scaled(shop.libraryRows, to: 10_000)
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.fileRows = rows
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        return shop
    }

    @Test("a facet recount per search letter stays quick on 10,000 models")
    func facetRecount() async {
        let shop = await Self.shop()
        #expect(shop.files.count == 10_000)
        let clock = ContinuousClock()
        var times: [Double] = []
        for typed in ["d", "dr", "dra", "drag", "#1", "#12"] {
            shop.search = typed
            let t = clock.now
            // Straight to the recount: the pause between letters is not
            // what is being timed.
            await shop.readLibraryFacets()
            times.append(ms(clock.now - t))
        }
        shop.search = ""
        shop.libraryNeverPrintedOnly = true
        let t = clock.now
        await shop.readLibraryFacets()
        times.append(ms(clock.now - t))
        print("10k facet recount ms:", times.map { String(format: "%.1f", $0) }.joined(separator: " "))
        #expect(times.allSatisfy { $0 < 10_000 })
    }

    @Test("a burst of thumbnails is decoded at most four at a time, and a tile gone away is not decoded")
    func thumbnailDecodesAreBounded() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-burst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 800,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let urls = try (0..<40).map { i -> URL in
            let u = dir.appending(path: "t\(i).png")
            try png.write(to: u)
            return u
        }
        let store = ThumbnailStore()
        await withTaskGroup(of: Void.self) { group in
            for u in urls { group.addTask { _ = await store.image(for: .file(u)) } }
        }
        #expect(await store.mostDecodingAtOnce <= ThumbnailStore.decodeWidth)
        #expect(await store.decodes == 40)
        // Cancelled before its turn: nothing decoded, nothing cached.
        let late = dir.appending(path: "late.png")
        try png.write(to: late)
        let task = Task { await store.image(for: .file(late)) }
        task.cancel()
        _ = await task.value
        #expect(await store.decodes == 40)
    }

    @Test("row(for:) answers from an index: every model asked once is quick")
    func rowLookup() async {
        let shop = await Self.shop()
        let ids = shop.files.map(\.id)
        let clock = ContinuousClock()
        let t = clock.now
        var found = 0
        for id in ids.prefix(2_000) where shop.row(for: id) != nil { found += 1 }
        let took = ms(clock.now - t)
        // The walk it replaced, for the comparison.
        let w = clock.now
        var walked = 0
        for id in ids.prefix(2_000) where shop.fileRows.contains(where: {
            if case .object(let rec) = $0, case .string(let known)? = rec["id"] { return known == id }
            return false
        }) { walked += 1 }
        print("10k row(for:) x2000 ms:", String(format: "%.1f", took),
              "| the old walk:", String(format: "%.1f", ms(clock.now - w)))
        #expect(walked == 2_000)
        #expect(found == 2_000)
        #expect(took < 10_000)
        // The first record with the id, as the walk found it.
        if case .object(let rec)? = shop.row(for: ids[5]), case .string(let id)? = rec["id"] {
            #expect(id == ids[5])
        } else { Issue.record("no record") }
        #expect(shop.row(for: "PF-nobody") == nil)
        // A new book is a new index.
        var rows = shop.fileRows
        rows.removeFirst()
        shop.fileRows = rows
        #expect(shop.row(for: ids[0]) == nil)
        #expect(shop.row(for: ids[1]) != nil)
    }
}
