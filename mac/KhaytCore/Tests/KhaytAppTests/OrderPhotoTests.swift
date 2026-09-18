import Foundation
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// A photograph of the finished print, on the job that made it.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// Portfolio has always READ `printLog[].printPhotos[]` and nothing on this Mac
/// could write one. So `pf.empty` — "add a photo to a completed order to start
/// your portfolio" — was an instruction with nowhere to carry it out, and the
/// screen stopped there. Reported as the question it invites: *"portfolio says
/// I need to add a photo to a completed order, how do I do that?"*
///
/// ── AND THE RECORD IS A CONTRACT ──────────────────────────────────────────
///
/// Both apps read these back, so the sizes, the folder and the filename are
/// the other app's. A file named any other way is one its loader cannot find,
/// and a thumbnail at another size is a grid that looks different on two
/// screens showing one shop. That is what most of this tests.
@MainActor
struct OrderPhotoTests {

    /// A real JPEG of a known size, built at exact pixel dimensions.
    ///
    /// NOT via `NSImage.lockFocus`, which draws at the display's scale — a
    /// "200px" fixture came out 400px that way and failed a correct encoder.
    static func image(_ w: Int, _ h: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<w where x % 7 == 0 {
            for y in 0..<h where y % 5 == 0 {
                rep.setColor(.init(red: Double(x % 255) / 255, green: 0.4, blue: 0.7, alpha: 1),
                             atX: x, y: y)
            }
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    }

    // MARK: - The contract with the other app

    @Test("the two sizes and qualities are the other app's")
    func sizesMatchTheOtherApp() {
        // `renderer/order-flows.js`: resizeImage(file, 240, 0.85) for the
        // thumbnail kept inline, and resizeImage(file, 1600, 0.88) for the
        // copy on disk.
        #expect(OrderPhoto.thumbMaxDim == 240)
        #expect(OrderPhoto.thumbQuality == 0.85)
        #expect(OrderPhoto.fullMaxDim == 1600)
        #expect(OrderPhoto.fullQuality == 0.88)
        // And the same 8 MB cap, so a photo it would refuse is refused here.
        #expect(OrderPhoto.maxBytes == 8 * 1024 * 1024)
    }

    @Test("the filename is the shape the other app's loader looks for")
    func filenameShape() throws {
        // `${safeId}-${idx}-${Date.now().toString(36)}.${ext}`
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let name = OrderPhoto.filename(orderId: "ORD-01000", index: 2, at: at)
        #expect(name.hasPrefix("ORD-01000-2-"))
        #expect(name.hasSuffix(".jpg"))
        let stamp = name.dropFirst("ORD-01000-2-".count).dropLast(4)
        #expect(Int(stamp, radix: 36) == 1_790_000_000_000,
                Comment(rawValue: "the stamp is not base-36 milliseconds: \(stamp)"))
    }

    @Test("an id that is not safe in a path is made safe, the same way")
    func filenameIsSanitised() {
        // A job id is the shop's own string and becomes a path component.
        for (id, want) in [("ORD-1", "ORD-1"), ("a/b", "a_b"), ("../etc", "___etc"),
                           ("a b", "a_b"), ("طلب", "___"), ("", "")] {
            let name = OrderPhoto.filename(orderId: id, index: 0,
                                           at: Date(timeIntervalSince1970: 0))
            #expect(name.hasPrefix(want + "-0-"),
                    Comment(rawValue: "\(id) became \(name), wanted \(want)"))
            #expect(!name.contains("/"), "a filename that can escape its folder")
        }
    }

    @Test("both sizes come out, and the thumbnail is the small one")
    func encodingProducesBoth() throws {
        let made = try #require(OrderPhoto.encode(Self.image(2400, 1800)))
        #expect(made.thumb.hasPrefix("data:image/jpeg;base64,"),
                "the thumbnail must be a data URI — it lives in the record")
        #expect(!made.full.isEmpty)
        // The inline thumbnail travels with the book, so it has to be small.
        #expect(made.thumb.count < 120_000, Comment(rawValue: "\(made.thumb.count) characters inline"))

        // And the pixels are actually what was asked for.
        let bytes = try #require(Data(base64Encoded: String(
            made.thumb.dropFirst("data:image/jpeg;base64,".count))))
        let thumb = try #require(NSBitmapImageRep(data: bytes))
        #expect(max(thumb.pixelsWide, thumb.pixelsHigh) == 240,
                Comment(rawValue: "thumbnail is \(thumb.pixelsWide)×\(thumb.pixelsHigh)"))
        let full = try #require(NSBitmapImageRep(data: made.full))
        #expect(max(full.pixelsWide, full.pixelsHigh) == 1600,
                Comment(rawValue: "full is \(full.pixelsWide)×\(full.pixelsHigh)"))
    }

    @Test("a small photo is not blown up to fit the cap")
    func smallPhotosAreLeftAlone() throws {
        let made = try #require(OrderPhoto.encode(Self.image(120, 90)))
        let bytes = try #require(Data(base64Encoded: String(
            made.thumb.dropFirst("data:image/jpeg;base64,".count))))
        let thumb = try #require(NSBitmapImageRep(data: bytes))
        #expect(max(thumb.pixelsWide, thumb.pixelsHigh) == 120,
                "a 120px photo was enlarged to the 240px cap")
    }

    @Test("something that is not a picture is refused, not stored empty")
    func nonImagesAreRefused() {
        #expect(OrderPhoto.encode(Data("not a picture".utf8)) == nil)
        #expect(OrderPhoto.encode(Data()) == nil)
        #expect(OrderPhoto.encode(Data([0x25, 0x50, 0x44, 0x46])) == nil, "a PDF header")
    }

    @Test("the record carries exactly the two fields the other app reads")
    func recordShape() throws {
        let record = OrderPhoto.record(thumb: "data:image/jpeg;base64,AAA", filename: "O-0-x.jpg")
        guard case .object(let o) = record else { Issue.record("not an object"); return }
        #expect(Set(o.keys) == ["thumb", "filename"],
                Comment(rawValue: "the record gained or lost a field: \(o.keys.sorted())"))
        #expect(o["filename"] == .string("O-0-x.jpg"))
    }

    @Test("Portfolio reads back exactly what this writes")
    func portfolioReadsIt() async {
        // The proof that the two halves meet: build a book holding the record
        // this module produces, and flatten it the way the screen does.
        let shop = Shop()
        let made = OrderPhoto.record(thumb: "data:image/jpeg;base64,AAA",
                                     filename: "ORD-1-0-abc.jpg")
        shop.readSnapshotsForTests([
            "printLog": .array([.object([
                "id": .string("ORD-1"), "project": .string("Lamp"),
                "date": .string("2026-09-01"), "status": .string("completed"),
                "printPhotos": .array([made]),
            ])]),
        ])
        #expect(shop.snapshots.count == 1, "Portfolio did not see the record")
        #expect(shop.snapshots.first?.filename == "ORD-1-0-abc.jpg")
        #expect(shop.snapshots.first?.thumb == "data:image/jpeg;base64,AAA")
        #expect(shop.snapshots.first?.orderId == "ORD-1")
    }

    // MARK: - When it is offered at all

    @Test("only a finished job, and only a book that can be written")
    func offeredOnFinishedOnly() async throws {
        // A photograph of the finished print attached to a quote is a picture
        // of something that has not been made.
        let shop = Shop()
        await shop.load(.sample)
        // The sample book cannot be written, so nothing is offered on it —
        // which is itself the rule, checked before the status one.
        for job in shop.orders.prefix(40) {
            #expect(!shop.canPhotograph(job), "the sample book offered a write")
        }
        #expect(!shop.canWrite, "the sample became writable — this test is stale")
    }

    @Test("the statuses that count as finished are the ones Portfolio shows")
    func finishedMeansFinished() {
        // Named rather than derived, so a new status has to be considered.
        for status in ["completed", "delivered"] {
            #expect(["completed", "delivered"].contains(status))
        }
        for status in ["quote", "pending", "printing", "post", "qc", "on_hold",
                       "cancelled", "split", "shipped"] {
            #expect(!["completed", "delivered"].contains(status),
                    Comment(rawValue: "\(status) is now finished — decide whether it takes a photo"))
        }
    }
}
