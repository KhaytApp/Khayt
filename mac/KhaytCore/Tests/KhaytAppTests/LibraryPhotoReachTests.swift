import Foundation
import AppKit
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// "I dont see an option to add a photo manually to the library."
///
/// The photo could be set only from the last section of a model's page. These
/// hold the two shorter roads to the same write — the model's right-click menu
/// and a picture dropped on its tile — and the section's new place under the
/// header.
@MainActor
struct LibraryPhotoReachTests {

    static func source(_ name: String) throws -> String {
        try String(contentsOf: GroupFromRightClickTests.source(name), encoding: .utf8)
    }

    static func file(photo: String?) throws -> LibraryFile {
        var row: [String: JSONValue] = ["id": .string("PF-x"), "name": .string("Dallah")]
        row["userPhoto"] = photo.map { .string($0) } ?? .null
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(row))
    }

    @Test("the right-click menu offers Add Photo… without one, Replace Photo… and Remove Photo with one, gated")
    func menuItems() throws {
        let src = try Self.source("FileActions.swift")
        let start = try #require(src.range(of: "struct ModelActions")).upperBound
        let end = try #require(src.range(of: "extension ModelActions", range: start..<src.endIndex)).lowerBound
        let menu = String(src[start..<end])
        let photo = try #require(menu.range(of: "let hasPhoto = LibraryPhoto.has(file)"))
        let items = String(menu[photo.lowerBound...].prefix(600))
        // The page's own words, an ellipsis where a panel opens, and the
        // page's own gate on both.
        #expect(items.contains(#"callIt(hasPhoto ? "mac.lp_replace" : "mac.lp_add") + "\u{2026}""#))
        #expect(items.contains("shop.chooseLibraryPhoto(for: file.id)"))
        #expect(items.contains("if hasPhoto {"))
        #expect(items.contains(#"callIt("mac.lp_remove")) { shop.clearLibraryPhoto(file.id) }"#))
        #expect(items.components(separatedBy: ".disabled(!shop.canMoveJobs)").count == 3,
                "both photo items answer to the same gate as the page's buttons")
        // The panel offers pictures and writes through the page's own call.
        let shell = try Self.source("Shop+Shell.swift")
        let choose = try #require(shell.range(of: "func chooseLibraryPhoto(for fileId: LibraryFile.ID)")).upperBound
        let body = String(shell[choose...].prefix(700))
        #expect(body.contains("guard canMoveJobs"))
        #expect(body.contains("panel.allowedContentTypes = LibraryPhoto.kinds"))
        #expect(body.contains("setLibraryPhoto(fileId, from: url)"))
    }

    @Test("which item the menu shows follows whether the model has a photo")
    func hasPhoto() throws {
        #expect(!LibraryPhoto.has(try Self.file(photo: nil)))
        #expect(!LibraryPhoto.has(try Self.file(photo: "/Users/someone/photo.jpg")))
        #expect(LibraryPhoto.has(try Self.file(photo: "data:image/jpeg;base64,AAAA")))
    }

    @Test("a drop on a tile: only pictures are a photo; a model, a folder or a mix is the import")
    func routing() {
        let png = URL(fileURLWithPath: "/tmp/a.PNG"), heic = URL(fileURLWithPath: "/tmp/b.heic")
        let stl = URL(fileURLWithPath: "/tmp/c.stl"), threeMF = URL(fileURLWithPath: "/tmp/d.3mf")
        let folder = URL(fileURLWithPath: "/tmp/models", isDirectory: true)
        #expect(Shop.tileDrop([]) == nil)
        #expect(Shop.tileDrop([png]) == .photo(png))
        #expect(Shop.tileDrop([heic, png]) == .photo(heic))
        #expect(Shop.tileDrop([stl]) == .models([stl]))
        #expect(Shop.tileDrop([threeMF]) == .models([threeMF]))
        #expect(Shop.tileDrop([folder]) == .models([folder]))
        // A mix keeps the import whole, as a drop on the library always did.
        #expect(Shop.tileDrop([png, stl]) == .models([png, stl]))
        // A web link is not a picture on disk.
        #expect(Shop.tileDrop([URL(string: "https://example.com/a.jpg")!]) == .models([URL(string: "https://example.com/a.jpg")!]))
    }

    @Test("the sample book refuses a drop on a tile, as the library around it does")
    func gated() async {
        let shop = Shop()
        await shop.load(.sample)
        #expect(!shop.canMoveJobs)
        let id = shop.files.first?.id ?? "x"
        #expect(!shop.dropOnModelTile([URL(fileURLWithPath: "/tmp/a.png")], onto: id))
        #expect(!shop.dropOnModelTile([URL(fileURLWithPath: "/tmp/a.stl")], onto: id))
    }

    @Test("the grid's tiles take drops through the one Shop call, and the library's own drop still imports")
    func wired() throws {
        let grid = try Self.source("LibraryGrid.swift")
        #expect(grid.contains("shop.dropOnModelTile(urls, onto: file.id)"))
        #expect(grid.contains("TileDropRing(shown: tileTarget == file.id && shop.canMoveJobs)"))
        #expect(grid.contains("await shop.addModelsToLibrary(urls)"))
    }

    @Test("the photo is the section under the header, above the file's details")
    func placement() throws {
        let src = try Self.source("LibraryInspector.swift")
        let photo = try #require(src.range(of: "PhotoSection(shop: shop, file: file)"))
        let header = try #require(src.range(of: "creatorAndCopies(file)\n"))
        let theFile = try #require(src.range(of: "theFile(file)\n"))
        #expect(header.upperBound < photo.lowerBound && photo.upperBound < theFile.lowerBound)
        #expect(src.components(separatedBy: "PhotoSection(").count == 2, "the section is drawn once")
    }

    @Test("pictures for review: the model page and a tile taking a photo, EN and AR")
    func pictures() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = Shop()
        await shop.load(.sample)
        let lang = Direction.shopLanguage()
        let file = try #require(shop.files.first { $0.id == "PF-sample-dallah" } ?? shop.files.first)
        shop.select(file, modifiers: .replace)
        let page = LibraryInspector(shop: shop).page(file).frame(width: 380)
        try SnapshotTests().render(page.background(Khayt.ground), "photo-inspector-\(lang)",
                                   size: CGSize(width: 380, height: 1100))
        // Three tiles, the middle one with a picture over it.
        let tiles = HStack(spacing: Wide.tileGap) {
            ForEach(Array(shop.files.prefix(3).enumerated()), id: \.offset) { i, f in
                Cell(file: f, thumbnail: shop.thumbnail(for: f), selected: false, words: shop.words)
                    .overlay { TileDropRing(shown: i == 1) }
                    .frame(width: 170)
            }
        }
        .padding(16)
        try SnapshotTests().render(tiles.background(Khayt.ground), "photo-tile-drop-\(lang)",
                                   size: CGSize(width: 580, height: 260))
    }
}

/// Through the real writer, on a temp book: the global seam these share.
extension LibraryEditPerfTests {

    static func picture(_ side: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "khayt-tile-\(UUID().uuidString).png")
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test("a picture dropped on a tile is that model's photo, byte for byte what the page writes")
    func tilePhoto() async throws {
        let png = try Self.picture(900)
        defer { try? FileManager.default.removeItem(at: png) }
        let rows: [JSONValue] = [.object(["id": .string("PF-a"), "name": .string("A")]),
                                 .object(["id": .string("PF-b"), "name": .string("B")])]
        try await Self.withLinkedBook([], rows: rows) { shop, url in
            #expect(shop.canMoveJobs)
            #expect(shop.dropOnModelTile([png], onto: "PF-b"))
            await shop.settleLibraryWrites()
            let book = try Self.book(url)
            guard case .array(let files)? = book["printFiles"] else { Issue.record("no printFiles"); return }
            func photo(_ id: String) -> JSONValue? {
                for case .object(let o) in files where o["id"] == .string(id) { return o["userPhoto"] ?? .null }
                return nil
            }
            // The page's encoder, so nothing new in the book: 480px JPEG at
            // 0.82 as a data URI, the other app's own format.
            #expect(photo("PF-b") == .string(try LibraryPhoto.dataURI(of: png)))
            #expect(photo("PF-a") != .string(try LibraryPhoto.dataURI(of: png)), "only the tile's own model")
        }
    }

    @Test("a model file dropped on a tile still goes to the library's import")
    func tileModelImports() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-tile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appending(path: "bracket.stl")
        try LinkedScanTests.model(stl, size: 14)
        let rows: [JSONValue] = [.object(["id": .string("PF-a"), "name": .string("A")])]
        try await Self.withLinkedBook([], rows: rows) { shop, url in
            #expect(shop.dropOnModelTile([stl], onto: "PF-a"))
            // The import runs in a task of its own, as the grid's drop does.
            var waited = 0
            while waited < 200, shop.importProblem == nil,
                  !shop.files.contains(where: { $0.sourceFile?.originalName == "bracket.stl" }) {
                try await Task.sleep(for: .milliseconds(50)); waited += 1
            }
            #expect(shop.importProblem == nil, "\(shop.importProblem ?? "")")
            #expect(shop.files.contains { $0.sourceFile?.originalName == "bracket.stl" })
            // And the tile's model was not given a photo.
            #expect(!LibraryPhoto.has(try #require(shop.files.first { $0.id == "PF-a" })))
        }
    }
}
