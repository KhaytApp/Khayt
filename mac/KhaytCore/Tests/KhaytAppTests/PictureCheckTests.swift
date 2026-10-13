import Foundation
import Testing
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import KhaytCore
@testable import KhaytApp

/// "Check pictures" (Oct 2026): the shop's assistant LOOKS at a candidate
/// photo beside the print's own preview. Its own switch, off until turned on;
/// what it sends is pinned here — a redrawn JPEG of at most 512 px with none
/// of the file's metadata, at most two images a request, 40 checks a scan.
struct PictureCheckTests {

    static let pictures: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(true),
                                                               "features": .object(["pictures": .bool(true)])])]
    static let libraryOnly: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(true),
                                                                  "features": .object(["library": .bool(true)])])]

    /// A 2000×1000 JPEG carrying EXIF, GPS and XMP, as a phone writes one.
    static func phonePhoto() throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        let meta = CGImageMetadataCreateMutable()
        _ = CGImageMetadataSetValueWithPath(meta, nil, "dc:creator" as CFString, "Somebody" as CFString)
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 24.7, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 46.7, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret", kCGImagePropertyExifLensModel: "Lens"],
        ]
        CGImageDestinationAddImageAndMetadata(dest, image, meta, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("the source really carries EXIF, GPS and XMP — and the photo sent carries none, at most 512 px")
    func redrawnWithNoMetadata() throws {
        let source = try Self.phonePhoto()
        let before = CGImageSourceCreateWithData(source as CFData, nil)!
        let beforeProps = CGImageSourceCopyPropertiesAtIndex(before, 0, nil) as? [CFString: Any] ?? [:]
        #expect(beforeProps[kCGImagePropertyGPSDictionary] != nil)

        let sent = try PictureSend.jpeg(data: source)
        let after = CGImageSourceCreateWithData(sent as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(after, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(max(w, h) <= 512)
        #expect(max(w, h) >= 500)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifUserComment] == nil)
        #expect(exif[kCGImagePropertyExifLensModel] == nil)
        #expect(props[kCGImagePropertyIPTCDictionary] == nil)
        let xmp = CGImageSourceCopyMetadataAtIndex(after, 0, nil)
        let creator = xmp.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "dc:creator" as CFString) }
        #expect(creator == nil)
        let ut = CGImageSourceGetType(after) as String?
        #expect(ut == UTType.jpeg.identifier)
    }

    @Test("a source over 8 MB is never read for a check")
    func sourceCap() {
        let big = Data(count: PictureSend.maxSourceBytes + 1)
        #expect(throws: PictureSend.Failure.tooBig) { try PictureSend.jpeg(data: big) }
    }

    @Test("the Mac's figures are the shared ones: 2 images, 40 checks, 512 px, 8 MB")
    func limits() async throws {
        let engine = try KhaytEngine()
        let l = try await engine.aiLibraryLimits()
        #expect(l["pictureImages"] == 2)
        #expect(l["pictureChecksPerScan"] == PictureSend.checksPerScan)
        #expect(l["picturePixels"] == PictureSend.maxPixel)
        #expect(l["pictureSourceBytes"] == PictureSend.maxSourceBytes)
        #expect(PictureSend.checksPerScan == 40)
        #expect(PrintPhotos.perPass == 40, "its own budget, beside the picture downloads'")
    }

    @Test("off by default, not switched on by Sort linked folders or the old toggle; nothing is built when off")
    func offByDefault() async throws {
        let engine = try KhaytEngine()
        let old = try await engine.aiFeatures(settings: ["ai": .object(["enabled": .bool(true)])])
        #expect(old.first { $0.id == "pictures" }?.enabled == false)
        let lib = try await engine.aiFeatures(settings: Self.libraryOnly)
        #expect(lib.first { $0.id == "pictures" }?.enabled == false)
        await #expect(throws: (any Error).self) {
            _ = try await engine.aiPictureRequest(settings: Self.libraryOnly, printName: "Kart Racer",
                                                  photo: "AAAA", reference: nil, apiKey: "k")
        }
    }

    @Test("a request carries at most two images: the photo, then the print's own preview")
    func twoImages() async throws {
        let engine = try KhaytEngine()
        let r = try await engine.aiPictureRequest(settings: Self.pictures, printName: "Kart Racer",
                                                  photo: "UEhPVE8=", reference: "UkVG", apiKey: "k")
        let body = String(describing: r.body)
        #expect(body.contains("UEhPVE8="))
        #expect(body.contains("UkVG"))
        #expect(body.contains("image/jpeg"))
        #expect(body.contains("check_print_picture"))
        #expect(body.contains("Kart Racer"))
        let alone = try await engine.aiPictureRequest(settings: Self.pictures, printName: "Kart Racer",
                                                      photo: "UEhPVE8=", reference: nil, apiKey: "k")
        #expect(!String(describing: alone.body).contains("UkVG"))
    }

    @Test("a provider that cannot take images is skipped: nothing is built")
    func unsupportedProvider() async throws {
        let engine = try KhaytEngine()
        let compatible: [String: JSONValue] = ["ai": .object(["provider": .string("compatible"), "enabled": .bool(true),
                                                              "baseUrl": .string("http://localhost:1234"),
                                                              "features": .object(["pictures": .bool(true)])])]
        let takes = try await engine.aiTakesImages(settings: compatible)
        #expect(takes == false)
        #expect(try await engine.aiTakesImages(settings: Self.pictures))
        await #expect(throws: (any Error).self) {
            _ = try await engine.aiPictureRequest(settings: compatible, printName: "x", photo: "AAAA",
                                                  reference: nil, apiKey: "k")
        }
    }

    @Test("yes with a preview attaches; yes without one is ticked; no is turned down; unsure is unticked")
    func outcomeMatrix() async throws {
        let engine = try KhaytEngine()
        let yesRef = try await engine.aiPictureOutcome(verdict: "yes", hasReference: true)
        let yesNoRef = try await engine.aiPictureOutcome(verdict: "yes", hasReference: false)
        let no = try await engine.aiPictureOutcome(verdict: "no", hasReference: true)
        let unsure = try await engine.aiPictureOutcome(verdict: "unsure", hasReference: true)
        #expect(yesRef == "attach")
        #expect(yesNoRef == "ticked")
        #expect(no == "rejected")
        #expect(unsure == "unticked")
        // A reply that is not a verdict is "unsure", never a yes.
        let reply: JSONValue = .object([
            "stop_reason": .string("tool_use"),
            "content": .array([.object(["type": .string("tool_use"), "name": .string("check_print_picture"),
                                        "input": .object(["verdict": .string("definitely")])])]),
        ])
        let read = try await engine.aiPictureRead(settings: Self.pictures, response: reply, hasReference: true)
        #expect(read.verdict == "unsure")
        #expect(read.outcome == "unticked")
    }

    @Test("a verdict is kept by the photo's bytes and the print: the same pair is never sent twice")
    func verdictCache() {
        let root = URL(fileURLWithPath: "/Drive/Linked")
        let hash = PictureSend.hash(Data("photo bytes".utf8))
        let target = LooseSort.Suggestion.Target.print("#loose/kart racer")
        let key = PictureVerdicts.key(hash: hash, root: root, target: target)
        var book: [String: JSONValue] = [:]
        PictureVerdicts.write([key: .init(verdict: "no", reference: true)],
                              hashes: [root.path + "|kart.jpg": hash], into: &book)
        guard case .object(let settings)? = book["settings"] else { Issue.record("no settings"); return }
        let read = PictureVerdicts.read(settings)
        #expect(read[key]?.verdict == "no")
        let latest = PictureVerdicts.latest(read, root: root, target: target, image: "kart.jpg",
                                            hashes: PictureVerdicts.hashes(settings))
        #expect(latest == .init(verdict: "no", reference: true))
        // Other bytes are another picture, asked about afresh.
        #expect(read[PictureVerdicts.key(hash: PictureSend.hash(Data("other".utf8)), root: root, target: target)] == nil)
    }

    @Test("a 'no' is remembered: the pairing is not offered again")
    @MainActor func noIsRemembered() {
        let drive = LooseSortTests.drive
        let images = LooseSortTests.shoot.filter { $0.hasSuffix(".jpg") }
        let p = PrintSort.plan(root: drive, models: LooseSortTests.shoot.filter { !$0.hasSuffix(".jpg") }.map { drive.appending(path: $0) },
                               images: images.map { drive.appending(path: $0) }, births: LooseSortTests.shootBirths)
        let offered = PictureRow.rows([p], settings: [:], hasPicture: { _, _ in false }, outcome: { _ in nil })
        guard let owl = offered.first(where: { $0.image.lastPathComponent == "Owl Lamp.jpg" }) else {
            Issue.record("Owl Lamp.jpg not offered"); return
        }
        let hash = "abc"
        let key = PictureVerdicts.key(hash: hash, root: drive, target: owl.suggestion.target)
        var book: [String: JSONValue] = [:]
        PictureVerdicts.write([key: .init(verdict: "no", reference: false)],
                              hashes: [drive.standardizedFileURL.path + "|Owl Lamp.jpg": hash], into: &book)
        guard case .object(let settings)? = book["settings"] else { Issue.record("no settings"); return }
        let after = PictureRow.rows([p], settings: settings, hasPicture: { _, _ in false },
                                    outcome: { $0.verdict == "no" ? "rejected" : nil })
        #expect(!after.contains { $0.id == owl.id })
        // A yes without a preview turns an offer's tick on.
        var yes: [String: JSONValue] = [:]
        PictureVerdicts.write([key: .init(verdict: "yes", reference: false)],
                              hashes: [drive.standardizedFileURL.path + "|Owl Lamp.jpg": hash], into: &yes)
        guard case .object(let ys)? = yes["settings"] else { Issue.record("no settings"); return }
        let ticked = PictureRow.rows([p], settings: ys, hasPicture: { _, _ in false },
                                     outcome: { $0.verdict == "yes" ? "ticked" : nil })
        #expect(ticked.first { $0.id == owl.id }?.ticked == true)
    }

    // MARK: - The 3MF's own preview

    static func file(_ id: String, _ name: String, thumb: String?) throws -> LibraryFile {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name),
                                      "sourceFile": .object(["filename": .string(name)])]
        if let thumb { o["thumbFile"] = .string(thumb) }
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(o)))
    }

    @Test("a group with no picture of its own wears a 3MF's embedded preview before an STL's drawing")
    func threeMFPreviewFallback() throws {
        let stl = try Self.file("a", "aaa part.stl", thumb: "thumb.png")
        let threeMF = try Self.file("b", "zzz kit.3mf", thumb: "thumb.png")
        let online = try Self.file("c", "bbb kit.3mf", thumb: nil)              // never downloaded: no preview
        #expect(threeMF.hasEmbeddedPreview)
        #expect(!stl.hasEmbeddedPreview)
        #expect(!online.hasEmbeddedPreview)
        let cover = LibraryEntry.cover(of: [stl, online, threeMF]) { $0.name < $1.name }
        #expect(cover?.id == "b")
    }
}
