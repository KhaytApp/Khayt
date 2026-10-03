import Foundation
import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import KhaytCore
@testable import KhaytApp

/// A phone photo comes out the way up it was taken, and one that did not can
/// be turned.
///
/// Reported by a shop: *"I added a photo to a catalogue product and it turned
/// it sideways with no way to fix it."* A phone stores a portrait shot on its
/// side with an EXIF orientation tag; `CGImageSourceCreateImageAtIndex` hands
/// back the pixels as stored and the JPEG written from them carried no tag,
/// so the picture was sideways everywhere for good.
///
/// THE FIXTURE is made here rather than checked in: 40×20 pixels stored, red
/// on the left half and blue on the right, tagged orientation 6 ("turn a
/// quarter clockwise to view"). Seen properly it is 20 wide and 40 tall, red
/// on TOP. Every assertion below is about which colour ends up where, because
/// a picture's size alone cannot tell a quarter turn one way from the other.
@MainActor
struct PhotoOrientationTests {

    static let red = (r: 255, g: 0, b: 0)
    static let blue = (r: 0, g: 0, b: 255)

    /// 40×20 pixels, left half red, right half blue.
    static func halves() -> CGImage {
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        return ctx.makeImage()!
    }

    /// The fixture as a phone would write it: the stored pixels plus a tag.
    static func jpeg(orientation: Int) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, halves(), [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func fixtureFile(orientation: Int = 6) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-orient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "IMG_0001.jpg")
        try jpeg(orientation: orientation).write(to: url)
        return url
    }

    /// Decoded AS STORED — no orientation applied — so a test sees what a
    /// reader that ignores tags would see.
    static func stored(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func tag(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return -1 }
        return ProductPhotos.orientation(source)
    }

    /// The colour at a point measured from the TOP-left, as a person reads it.
    static func colour(_ image: CGImage, x: Int, yFromTop: Int) -> (r: Int, g: Int, b: Int) {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // A bitmap context's memory starts at the TOP row.
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (yFromTop * w + x) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
    }

    static func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 200 && c.g < 60 && c.b < 60 }
    static func isBlue(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.b > 200 && c.r < 60 && c.g < 60 }

    /// Red on top and blue below, 20 wide by 40 tall (in proportion).
    static func expectUpright(_ image: CGImage?, _ what: String) {
        guard let image else { Issue.record("\(what): no image"); return }
        #expect(image.height > image.width, "\(what) is \(image.width)×\(image.height): still on its side")
        #expect(isRed(colour(image, x: image.width / 2, yFromTop: image.height / 4)),
                "\(what): the top is not red — turned the wrong way")
        #expect(isBlue(colour(image, x: image.width / 2, yFromTop: image.height * 3 / 4)),
                "\(what): the bottom is not blue")
    }

    static func decodeURI(_ uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
    }

    // MARK: - Upright on the way in

    @Test("the fixture really is sideways as stored, and tagged 6")
    func fixtureIsSideways() {
        let data = Self.jpeg(orientation: 6)
        #expect(Self.tag(data) == 6)
        let raw = Self.stored(data)!
        #expect(raw.width == 40 && raw.height == 20)
    }

    @Test("an EXIF-rotated photo (orientation 6) is written UPRIGHT, with no tag left to need")
    func addWritesUpright() throws {
        let url = try Self.fixtureFile()
        let prepared = try ProductPhotos.prepare(url)
        // The full file: upright in its PIXELS — read the way a reader that
        // ignores tags reads it — and carrying no tag to contradict them.
        Self.expectUpright(Self.stored(prepared.full), "the full-size file")
        #expect(Self.tag(prepared.full) == 1, "the written file still carries an orientation tag")
        // And the thumbnail every screen draws.
        let thumb = try #require(Self.decodeURI(prepared.thumbnail))
        Self.expectUpright(Self.stored(thumb), "the thumbnail")
    }

    @Test("an upright photo is left exactly as it was turned")
    func uprightStaysUpright() throws {
        let url = try Self.fixtureFile(orientation: 1)
        let prepared = try ProductPhotos.prepare(url)
        let image = try #require(Self.stored(prepared.full))
        #expect(image.width == 40 && image.height == 20)
        #expect(Self.isRed(Self.colour(image, x: 5, yFromTop: 10)))
    }

    @Test("a file already on disk with a tag is published to the web store upright")
    func heroIsUpright() throws {
        let url = try Self.fixtureFile()
        let hero = try #require(CatalogPublisher.hero(url, maxDim: 1000, quality: 0.82))
        Self.expectUpright(Self.stored(try #require(Self.decodeURI(hero))), "the web store's picture")
    }

    @Test("a model's photo and a group's picture come in upright too")
    func otherReadersUpright() throws {
        let url = try Self.fixtureFile()
        let uri = try LibraryPhoto.dataURI(of: url)
        Self.expectUpright(Self.stored(try #require(Self.decodeURI(uri))), "a model's photo")
        Self.expectUpright(Self.stored(try GroupPictures.encode(url)), "a group's picture")
    }

    @Test("no reader of an image file drops its orientation any more")
    func noRawDecodesLeft() throws {
        // `CGImageSourceCreateImageAtIndex` ignores the tag. The one place
        // allowed it is the fallback inside `upright` itself.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".swift") }
        var found: [String] = []
        for f in files {
            let text = try String(contentsOf: root.appending(path: f), encoding: .utf8)
            let n = text.components(separatedBy: "CGImageSourceCreateImageAtIndex(").count - 1
            if n > (f == "ProductPhotos.swift" ? 1 : 0) { found.append(f) }
        }
        #expect(found.isEmpty, "decodes a picture as stored, ignoring which way up it goes: \(found)")
    }

    // MARK: - Turning a picture

    @Test("Rotate Right turns clockwise and Rotate Left anticlockwise")
    func rotateDirections() throws {
        let image = Self.halves()   // red left, blue right
        let right = try #require(ProductPhotos.rotated(image, quarterTurns: 1))
        #expect(right.width == 20 && right.height == 40)
        // Clockwise: the left edge goes to the TOP.
        #expect(Self.isRed(Self.colour(right, x: 10, yFromTop: 5)), "Rotate Right did not turn clockwise")
        #expect(Self.isBlue(Self.colour(right, x: 10, yFromTop: 35)))
        let left = try #require(ProductPhotos.rotated(image, quarterTurns: -1))
        #expect(left.width == 20 && left.height == 40)
        #expect(Self.isBlue(Self.colour(left, x: 10, yFromTop: 5)), "Rotate Left did not turn anticlockwise")
        #expect(Self.isRed(Self.colour(left, x: 10, yFromTop: 35)))
        let half = try #require(ProductPhotos.rotated(image, quarterTurns: 2))
        #expect(half.width == 40 && Self.isBlue(Self.colour(half, x: 5, yFromTop: 10)))
        #expect(ProductPhotos.rotated(image, quarterTurns: 4) === image)
    }

    @Test("turning a picture on disk rewrites ITS file and updates its record")
    func turnRewritesFileAndRecord() async throws {
        // A sideways picture already in the book, as this app wrote them
        // before the fix: the pixels as stored, no tag.
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = ProductPhotos.filename(productId: "PROD-1", imageId: "IMG-a")
        let sideways = try #require(ProductPhotos.jpeg(Self.halves(), maxDim: 1600, quality: 0.88))
        try sideways.write(to: dir.appending(path: name))
        let oldThumb = "data:image/jpeg;base64,"
            + (ProductPhotos.jpeg(Self.halves(), maxDim: 240, quality: 0.85)!).base64EncodedString()
        let picture = StagedPicture(id: "IMG-a", kind: "print", caption: "the real one",
                                    thumbnail: oldThumb, path: name, bytes: nil)
        let read: (String) -> Data? = { try? Data(contentsOf: dir.appending(path: $0)) }

        // Rotate Right: the left edge (red) goes to the top.
        let turned = try #require(await ProductPictureStrip.turning(picture, by: 1, read: read))
        #expect(turned.turns == 1)
        #expect(turned.path == name, "a turned picture is the same picture: its path stays")
        #expect(turned.thumbnail != oldThumb)
        Self.expectUpright(Self.stored(try #require(Self.decodeURI(turned.thumbnail))), "the new thumbnail")
        let bytes = try #require(turned.bytes)

        // Saved: over its own file, nothing else to unlink.
        let target = ProductPhotos.target(existing: turned.path, productId: "PROD-1", imageId: turned.id)
        #expect(target.name == name && target.unlink == nil)
        try ProductPhotos.write(bytes, named: target.name, into: dir)
        Self.expectUpright(Self.stored(try Data(contentsOf: dir.appending(path: name))), "the file on disk")

        // And the record the rule writes: the new thumbnail, the same path,
        // the kind and caption kept, and the legacy view following images[0].
        var saved = turned
        saved.bytes = nil
        let engine = try KhaytEngine()
        let fields = await Shop.pictureFields([saved], productId: "PROD-1", engine: engine)
        guard case .array(let images)? = fields["images"], case .object(let first)? = images.first else {
            Issue.record("no images written"); return
        }
        #expect(first["thumbnail"] == .string(turned.thumbnail))
        #expect(first["path"] == .string(name))
        #expect(first["kind"] == .string("print"))
        #expect(first["caption"] == .string("the real one"))
        #expect(fields["thumbnail"] == .string(turned.thumbnail), "the storefront would still read the old one")
        #expect(fields["imagePath"] == .string(name))
    }

    @Test("Rotate Left then Rotate Right is no change at all, and nothing to rewrite")
    func turnBackIsUntouched() async throws {
        let data = try #require(ProductPhotos.jpeg(Self.halves(), maxDim: 1600, quality: 0.88))
        let picture = StagedPicture(id: "IMG-a", kind: "render", caption: "",
                                    thumbnail: "data:image/jpeg;base64,AA", path: "PROD-1-IMG-a.jpeg", bytes: nil)
        let left = try #require(await ProductPictureStrip.turning(picture, by: -1, read: { _ in data }))
        #expect(left.turns == 3 && left.bytes != nil)
        let back = try #require(await ProductPictureStrip.turning(left, by: 1, read: { _ in nil }))
        #expect(back.turns == 0)
        #expect(back.bytes == nil, "turned all the way back, and the file would still be rewritten")
        #expect(back.thumbnail == "data:image/jpeg;base64,AA")
        // Four turns the same way, from ONE starting point: the last is made
        // from the original, not from three re-encodes stacked up.
        var p = picture
        for _ in 0..<3 { p = try #require(await ProductPictureStrip.turning(p, by: 1, read: { _ in data })) }
        #expect(p.turnedFrom?.original == data)
        p = try #require(await ProductPictureStrip.turning(p, by: 1, read: { _ in nil }))
        #expect(p.turns == 0 && p.bytes == nil)
    }

    @Test("a picture picked in this sitting turns from its staged bytes, and saves under main.js's name")
    func turnStagedPick() async throws {
        let url = try Self.fixtureFile(orientation: 1)
        let prepared = try ProductPhotos.prepare(url)
        let picture = StagedPicture(id: "IMG-b", kind: "render", caption: "",
                                    thumbnail: prepared.thumbnail, path: "", bytes: prepared.full)
        let turned = try #require(await ProductPictureStrip.turning(picture, by: 1, read: { _ in nil }))
        Self.expectUpright(Self.stored(try #require(turned.bytes)), "the staged bytes")
        let target = ProductPhotos.target(existing: "", productId: "PROD-1", imageId: "IMG-b")
        #expect(target.name == "PROD-1-IMG-b.jpeg" && target.unlink == nil)
        // A picture with nothing to turn from cannot be turned.
        let hollow = StagedPicture(id: "x", kind: "render", caption: "", thumbnail: "", path: "", bytes: nil)
        #expect(await ProductPictureStrip.turning(hollow, by: 1, read: { _ in nil }) == nil)
    }

    @Test("a turned picture whose file is not a JPEG moves to a JPEG name, and its old file goes")
    func turnNonJpeg() {
        let target = ProductPhotos.target(existing: "PROD-1.png", productId: "PROD-1", imageId: "IMG-c")
        #expect(target.name == "PROD-1-IMG-c.jpeg")
        #expect(target.unlink == "PROD-1.png")
        // A path off a synced record cannot reach outside the folder.
        let odd = ProductPhotos.target(existing: "../../etc/x.jpeg", productId: "PROD-1", imageId: "i")
        #expect(odd.name == "x.jpeg")
    }

    @Test("an untouched save writes the pictures back exactly as the book holds them (#1676)")
    func untouchedRoundTrip() async throws {
        let engine = try KhaytEngine()
        let images: [JSONValue] = [
            .object(["id": .string("A"), "path": .string("PROD-1-A.jpeg"),
                     "thumbnail": .string("data:image/jpeg;base64,AA"), "kind": .string("print"),
                     "caption": .string("")]),
            .object(["id": .string("B"), "path": .string("PROD-1-B.jpeg"),
                     "thumbnail": .string("data:image/jpeg;base64,BB"), "kind": .string("render"),
                     "caption": .string("")]),
        ]
        let stored: [String: JSONValue] = ["id": .string("PROD-1"), "nameEn": .string("Bracket"),
                                           "images": .array(images), "imagePath": .string("PROD-1-A.jpeg"),
                                           "thumbnail": .string("data:image/jpeg;base64,AA"),
                                           "fromANewerBuild": .string("kept")]
        let read = try await engine.productPictures(of: .object(stored))
        let staged = read.images.map {
            StagedPicture(id: $0.id, kind: $0.kind, caption: $0.caption,
                          thumbnail: $0.thumbnail, path: $0.path, bytes: nil)
        }
        let baseline = await Shop.pictureFields(staged, productId: "PROD-1", engine: engine)
        let untouched = Shop.productRecord(written: baseline, baseline: baseline, priced: [:], over: stored)
        #expect(untouched == stored, "a save that turned nothing changed the record")

        // One picture turned: only its thumbnail moves (and the legacy view
        // that mirrors images[0]); the other picture and the rest stay put.
        var turned = staged
        turned[0].thumbnail = "data:image/jpeg;base64,CC"
        let written = await Shop.pictureFields(turned, productId: "PROD-1", engine: engine)
        let record = Shop.productRecord(written: written, baseline: baseline, priced: [:], over: stored)
        guard case .array(let out)? = record["images"] else { Issue.record("images gone"); return }
        #expect(out.count == 2)
        #expect(out[1] == images[1])
        if case .object(let a) = out[0] {
            #expect(a["thumbnail"] == .string("data:image/jpeg;base64,CC"))
            #expect(a["path"] == .string("PROD-1-A.jpeg"))
        }
        #expect(record["thumbnail"] == .string("data:image/jpeg;base64,CC"))
        #expect(record["fromANewerBuild"] == .string("kept"))
    }

    @Test("the strip offers the turn on every card and in its right-click")
    func stripIsWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let strip = try String(contentsOf: root.appending(path: "ProductPictures.swift"), encoding: .utf8)
        #expect(strip.contains("turn: { by in Task { await turn(picture.id, by: by) } }"))
        #expect(strip.contains(".overlay(alignment: .bottomTrailing) { turnButtons }"))
        #expect(strip.contains("Button(shop.words.callIt(\"mac.rotate_left\")) { turn(-1) }"))
        let shop = try String(contentsOf: root.appending(path: "Shop.swift"), encoding: .utf8)
        #expect(shop.contains("ProductPhotos.target(existing: staged![i].path"),
                "the save does not write a turned picture over its own file")
    }

    // MARK: - Pictures

    static var outDir: URL? { SnapshotTests.outputDir }

    /// A photo-like thumbnail: the fixture's two halves at card size.
    static func thumbURI(sideways: Bool) -> String {
        var image = halves()
        if !sideways { image = ProductPhotos.rotated(image, quarterTurns: 1)! }
        return "data:image/jpeg;base64," + ProductPhotos.jpeg(image, maxDim: 240, quality: 0.85)!.base64EncodedString()
    }

    @Test("the product sheet's pictures, with their turn buttons, en/ar")
    func renderStrip() async throws {
        guard Self.outDir != nil else { return }
        let lang = Direction.shopLanguage()
        let shop = Shop()
        await shop.load(.sample)
        let pictures: [StagedPicture] = [
            StagedPicture(id: "a", kind: "print", caption: "", thumbnail: Self.thumbURI(sideways: true),
                          path: "a.jpeg", bytes: nil),
            StagedPicture(id: "b", kind: "render", caption: "", thumbnail: Self.thumbURI(sideways: false),
                          path: "b.jpeg", bytes: nil),
        ]
        let kinds = (try? await shop.engine?.productImageKinds()) ?? []
        // The cards themselves: a photograph cannot see inside the strip's
        // horizontal ScrollView.
        let view = HStack(alignment: .top, spacing: 10) {
            ForEach(Array(pictures.enumerated()), id: \.element.id) { index, picture in
                PictureCard(shop: shop, kinds: kinds, picture: picture, isPrimary: index == 0,
                            kind: .constant(picture.kind), makePrimary: {}, remove: {})
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Khayt.ground)
        try SnapshotTests().render(view, "product-pictures-\(lang)-light", size: CGSize(width: 320, height: 140))
        try SnapshotTests().renderDark(view, "product-pictures-\(lang)-dark", size: CGSize(width: 320, height: 140))
    }
}
