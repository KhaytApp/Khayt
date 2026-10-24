import Foundation
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// The library grid redesign: tile sizes, the facts on a tile, the orders
/// that read them, the filter row that keeps its menus, the one Edit menu,
/// and the white backdrop keyed out of a rendered preview.
@MainActor
struct LibraryGridRedesignTests {

    static func file(_ json: String) throws -> LibraryFile {
        try JSONDecoder().decode(LibraryFile.self, from: Data(json.utf8))
    }

    static func defaults() -> UserDefaults {
        let name = "khayt-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Tile size

    @Test("tile size steps Small ↔ Medium ↔ Large and stops at the ends")
    func tileSteps() {
        let display = LibraryDisplay(defaults: Self.defaults())
        #expect(display.tileSize == .medium, "a new Mac opens on the size it always had")
        #expect(LibraryTileSize.medium.points == Wide.tile)
        #expect(display.larger() && display.tileSize == .large)
        #expect(!display.larger() && display.tileSize == .large)
        #expect(display.smaller() && display.smaller() && display.tileSize == .small)
        #expect(!display.smaller() && display.tileSize == .small)
        display.resetSize()
        #expect(display.tileSize == .medium)
        #expect(LibraryTileSize.allCases.map(\.points) == [112, 152, 220])
    }

    @Test("tile size and grid-or-list survive a relaunch, per Mac")
    func tilePersists() {
        let d = Self.defaults()
        let first = LibraryDisplay(defaults: d)
        first.tileSize = .large
        first.layout = .list
        #expect(d.string(forKey: LibraryDisplay.tileKey) == "large")
        let again = LibraryDisplay(defaults: d)
        #expect(again.tileSize == .large && again.layout == .list)
        // Something unreadable falls back rather than crashing.
        d.set("enormous", forKey: LibraryDisplay.tileKey)
        #expect(LibraryDisplay(defaults: d).tileSize == .medium)
    }

    @Test("a thumbnail is decoded at twice the tile, not 640 for every size")
    func decodeSize() {
        #expect(LibraryTileSize.small.pixels(scale: 2) == 200)
        #expect(LibraryTileSize.large.pixels(scale: 2) == 416)
        #expect(ThumbnailStore.bucket(200) == 256)
        #expect(ThumbnailStore.bucket(9_000) == ThumbnailStore.maxPixels)
        #expect(Wide.columns(across: 800, tile: 112) > Wide.columns(across: 800, tile: 220))
    }

    @Test("Small hides the format badge, and STL/3MF never wear one")
    func formatBadge() {
        #expect(Cell.formatBadge("stl", size: .medium) == nil)
        #expect(Cell.formatBadge("3MF", size: .large) == nil)
        #expect(Cell.formatBadge("step", size: .medium) == "STEP")
        #expect(Cell.formatBadge("step", size: .small) == nil)
    }

    // MARK: Facts

    @Test("the facts line: hours and minutes, grams or kilos, price, ≈ for estimates")
    func factsLine() throws {
        let words = Words()
        #expect(LibraryFacts.duration(45, words: words) == "45m")
        #expect(LibraryFacts.duration(272, words: words) == "4h 32m")
        #expect(LibraryFacts.duration(120, words: words) == "2h")
        #expect(LibraryFacts.weight(57.18, words: words) == "57 g")
        #expect(LibraryFacts.weight(2_140, words: words) == "2.1 kg")
        #expect(LibraryFacts.weight(62, words: words, approximate: true) == "\u{2248}62 g")
        let all = LibraryFacts(minutes: 272, grams: 57, price: 85)
        let line = LibraryFacts.line(all, words: words, currency: "USD")
        #expect(line.hasPrefix("4h 32m \u{00B7} 57 g \u{00B7} 85 "), "\(line)")
        let guessed = LibraryFacts(minutes: 104, minutesEstimated: true, grams: 62, gramsEstimated: true)
        #expect(LibraryFacts.line(guessed, words: words, currency: "SAR") == "\u{2248}1h 44m \u{00B7} \u{2248}62 g")
        #expect(LibraryFacts.line(LibraryFacts(), words: words, currency: "SAR").isEmpty)
        #expect(LibraryFacts.price(85.5, currency: "USD").hasPrefix("85.50"))
    }

    @Test("Arabic facts keep their numerals isolated, with ≈ inside the figure")
    func factsArabic() throws {
        for key in ["mac.lg_hours_minutes", "mac.lg_grams", "mac.lg_kilos", "mac.lg_minutes", "mac.lg_hours"] {
            let ar = try #require(Words.own[key]?["ar"], "\(key)")
            #expect(ar.contains("\u{2068}") && ar.contains("\u{2069}"), "\(key) is not isolated")
            #expect(Words.own[key]?["en"]?.isEmpty == false)
        }
    }

    @Test("facts come from the slicer, then the colours, then the estimate")
    func factsSources() throws {
        let sliced = try Self.file(#"{"id":"a","name":"a","parsed":{"printTimeMins":90,"filamentGrams":40}}"#)
        let f = LibraryFacts.of(sliced, estimate: (grams: 99, hours: 9), price: 12)
        #expect(f.minutes == 90 && !f.minutesEstimated && f.grams == 40 && !f.gramsEstimated && f.price == 12)
        let colours = try Self.file(##"{"id":"b","name":"b","colors":[{"hex":"#fff","grams":10},{"hex":"#000","grams":5.5}]}"##)
        #expect(LibraryFacts.of(colours, estimate: nil, price: nil).grams == 15.5)
        let bare = try Self.file(#"{"id":"c","name":"c"}"#)
        let e = LibraryFacts.of(bare, estimate: (grams: 30, hours: 1.5), price: 0)
        #expect(e.minutes == 90 && e.minutesEstimated && e.grams == 30 && e.gramsEstimated && e.price == nil)
        #expect(LibraryFacts.sliced(bare).isEmpty)
    }

    @Test("a price is a product made of that one file only")
    func pricesByFile() {
        func product(_ id: String, _ files: [String]) -> JSONValue {
            .object(["id": .string(id), "parts": .array(files.map { .object(["printFileId": .string($0)]) })])
        }
        let prices = Shop.pricesByFile(
            products: [product("P1", ["f1"]), product("P2", ["f2", "f3"]), product("P3", ["f1"]),
                       product("P4", ["f4", "f4"]), product("P5", ["f5"])],
            finals: ["P1": 85, "P2": 40, "P3": 99, "P4": 20])
        #expect(prices == ["f1": 85, "f4": 20], "\(prices)")
    }

    // MARK: Sort

    @Test("sort by print time and weight: smallest first, unknown last; price dearest first")
    func sortsByFacts() throws {
        let quick = try Self.file(#"{"id":"q","name":"Quick","parsed":{"printTimeMins":30,"filamentGrams":200}}"#)
        let slow = try Self.file(#"{"id":"s","name":"Slow","parsed":{"printTimeMins":300,"filamentGrams":20}}"#)
        let none = try Self.file(#"{"id":"n","name":"Aardvark"}"#)
        let rows = [none, slow, quick]
        #expect(LibrarySort.printTime.sorted(rows).map(\.id) == ["q", "s", "n"])
        #expect(LibrarySort.grams.sorted(rows).map(\.id) == ["s", "q", "n"])
        // With the shop's facts — an estimate and a price.
        let facts: (LibraryFile) -> LibraryFacts = { f in
            switch f.id {
            case "n": LibraryFacts(minutes: 10, minutesEstimated: true, price: 50)
            case "q": LibraryFacts(minutes: 30, price: 80)
            default: LibraryFacts(minutes: 300)
            }
        }
        #expect(LibrarySort.printTime.sorted(rows, facts: facts).map(\.id) == ["n", "q", "s"])
        #expect(LibrarySort.price.sorted(rows, facts: facts).map(\.id) == ["q", "n", "s"])
        let order = LibrarySort.price.ordering(facts)
        #expect(rows.sorted(by: order).map(\.id) == ["q", "n", "s"])
        #expect(LibrarySort.printTime.readsFacts && !LibrarySort.name.readsFacts)
        for sort in [LibrarySort.printTime, .grams, .price] {
            #expect(Words.own[sort.key]?["ar"]?.isEmpty == false, "\(sort)")
        }
    }

    @Test("the list's columns and the library's order are one choice")
    func listColumns() {
        for sort in LibrarySort.allCases where sort != .added && sort != .khayt {
            #expect(LibraryList.sort(for: LibraryList.comparators(for: sort)) == sort, "\(sort)")
        }
        #expect(LibraryList.comparators(for: .added).isEmpty)
    }

    // MARK: The row

    @Test("filter menus stay on the row, greyed, when they have nothing to offer")
    func menusStay() throws {
        #expect(!LibraryFilterBar.menuEnabled(rows: 0))
        #expect(LibraryFilterBar.menuEnabled(rows: 1))
        let bar = try QuoteSheetStatusTests.source("LibraryFilterBar.swift")
        #expect(!bar.contains("if !rows.isEmpty {"), "an empty axis is hidden again")
        #expect(bar.contains(".disabled(true)"))
        #expect(bar.contains("LibraryViewControls(shop: shop)"), "sort, view and size left the row")
        #expect(LibraryFilterBar.axes.count == 5)
        for key in ["mac.lg_filter_empty", "mac.lg_view_grid", "mac.lg_view_list", "mac.lg_tile_size"] {
            #expect(Words.own[key]?["en"]?.isEmpty == false && Words.own[key]?["ar"]?.isEmpty == false, "\(key)")
        }
    }

    @Test("the strip has one Edit menu, not three that look like filters")
    func oneEditMenu() throws {
        let strip = try QuoteSheetStatusTests.source("ScreenActions.swift")
        #expect(strip.contains("EditSelectionMenu(shop: shop)"))
        for gone in ["GroupMenu(shop: shop)", "CategoryMenu(shop: shop)", "ProvenanceMenu(shop: shop)",
                     "selection: $shop.librarySort"] {
            #expect(!strip.contains(gone), "\(gone) is back in the title strip")
        }
        let menu = try QuoteSheetStatusTests.source("EditSelectionMenu.swift")
        #expect(menu.contains("$shop.namingGroup"), "the right-click's New Group… has nothing to open")
        let words = Words()
        #expect(EditSelectionMenu.title(models: 0, groups: 0, words: words) == "Edit")
        #expect(EditSelectionMenu.title(models: 3, groups: 0, words: words) == "Edit 3 models")
    }

    @Test("the empty library offers a labelled Import button")
    func emptyImport() throws {
        let grid = try QuoteSheetStatusTests.source("LibraryGrid.swift")
        #expect(grid.contains("message: shop.words.callIt(\"mac.lg_empty_hint\")"))
        #expect(grid.contains(".buttonStyle(.borderedProminent)"))
    }

    // MARK: The white square

    @Test("a render on white loses its backdrop and keeps a white model")
    func matte() throws {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                // Backdrop 247, a white block (255) in the middle with a 1-px
                // grey outline, like a renderer's.
                var v: UInt8 = 247
                if (20...44).contains(x) && (20...44).contains(y) { v = 255 }
                if x == 19 || x == 45 || y == 19 || y == 45 { if (19...45).contains(x) && (19...45).contains(y) { v = 120 } }
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let cg = try #require(px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let out = try #require(ThumbnailStore.matte(cg))
        let rep = NSBitmapImageRep(cgImage: out)
        #expect((rep.colorAt(x: 2, y: 2)?.alphaComponent ?? 1) < 0.05, "the backdrop is still there")
        #expect((rep.colorAt(x: 32, y: 32)?.alphaComponent ?? 0) > 0.95, "the white model was keyed out")
        // A photograph whose edge is not a white backdrop is left alone.
        var dark = [UInt8](repeating: 40, count: w * h * 4)
        for i in stride(from: 3, to: dark.count, by: 4) { dark[i] = 255 }
        let photo = try #require(dark.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        #expect(ThumbnailStore.matte(photo) == nil)
    }
}
