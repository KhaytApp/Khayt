import Foundation
import AppKit
import Testing
@testable import KhaytApp

/// A photograph of the finished print.
///
/// `Shop.thumbnail(for:)` has always preferred one — "a photograph the shop
/// took beats a generated thumbnail: it is the print as it came off the bed" —
/// and this app had no way to take one. The better picture was one it could
/// display and never obtain.
@MainActor
struct LibraryPhotoTests {

    /// A picture on disk of an EXACT pixel size.
    ///
    /// Built as a bitmap rep rather than `NSImage` + `lockFocus`: focusing an
    /// image draws at the screen's backing scale, so on this Mac a "200 point"
    /// square was written as a 400-pixel file — and the first version of the
    /// no-enlarging test below duly failed against an encoder that was doing
    /// exactly the right thing. The fixture has to mean pixels.
    private func written(_ side: Int, opaque: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "khayt-photo-\(UUID().uuidString).png")
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (opaque ? NSColor.systemTeal : NSColor.clear).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }

    @Test("the numbers are the other app's, not ours")
    func matchesTheCanvas() {
        // `renderer/printfiles.js`: resizeImage(file, 480, 0.82). Both apps read
        // the same book and either may draw this, so these are matched rather
        // than chosen — a test so that changing one is a decision.
        #expect(LibraryPhoto.maxDim == 480)
        #expect(LibraryPhoto.quality == 0.82)
    }

    @Test("a big photo comes back as a data URI Khayt can draw")
    func encodes() throws {
        let uri = try LibraryPhoto.dataURI(of: try written(1200))
        #expect(uri.hasPrefix("data:image/jpeg;base64,"))
        let image = try #require(PhotoSection.image(from: uri))
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        // Scaled to fit 480 on its longest side. PIXELS, not points.
        #expect(rep.pixelsWide == LibraryPhoto.maxDim,
                Comment(rawValue: "a 1200px photo came back \(rep.pixelsWide)px wide"))
        #expect(rep.pixelsHigh <= LibraryPhoto.maxDim)
    }

    @Test("a small photo is never blown up")
    func neverEnlarges() throws {
        // `min(1, maxDim / longest)`, as the canvas does. A 200px photo stays
        // 200px rather than being enlarged to 480 and looking worse than the
        // file the shop gave us.
        let uri = try LibraryPhoto.dataURI(of: try written(200))
        let image = try #require(PhotoSection.image(from: uri))
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        #expect(rep.pixelsWide == 200,
                Comment(rawValue: "a 200px photo came back \(rep.pixelsWide)px wide"))
    }

    @Test("a picture with transparency does not come out on black")
    func flattensOntoWhite() throws {
        // JPEG carries no alpha. A transparent PNG encoded straight to JPEG
        // comes out on black, which is what the canvas's fillRect prevents.
        let uri = try LibraryPhoto.dataURI(of: try written(300, opaque: false))
        let image = try #require(PhotoSection.image(from: uri))
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let corner = try #require(rep.colorAt(x: 2, y: 2))
        #expect(corner.brightnessComponent > 0.9,
                Comment(rawValue: "the transparent area came out at \(corner.brightnessComponent)"))
    }

    @Test("something that is not a picture is refused with a sentence")
    func refusesRubbish() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "khayt-not-a-photo-\(UUID().uuidString).png")
        try Data("this is not a picture".utf8).write(to: url)
        #expect(throws: ProductPhotos.Failure.self) { try LibraryPhoto.dataURI(of: url) }
    }

    @Test("the reader round-trips what the store holds, and rejects what it does not")
    func readsBackOnlyDataURIs() {
        #expect(PhotoSection.image(from: nil) == nil)
        #expect(PhotoSection.image(from: "") == nil)
        // A path is not a photo: the field is inline data on purpose, and a
        // string that looks like a file would otherwise be drawn as one.
        #expect(PhotoSection.image(from: "/Users/someone/photo.jpg") == nil)
        #expect(PhotoSection.image(from: "data:image/jpeg;base64,not-base64!!") == nil)
    }
}
