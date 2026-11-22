import XCTest
import UIKit
import ImageIO
import KhaytCore
@testable import KhaytCompanion

/// Order photos against khayt-cloud's contract ("Customer portal & published
/// items", 2026-10-10): the path, the limits, the refusals, and upright pixels.
final class OrderPhotosTests: XCTestCase {
    typealias API = KhaytAPIClient

    func testTheTokenComesFromTheOrderAndAnUnpublishedOrderHasNone() {
        let store: [String: JSONValue] = ["printLog": .array([
            .object(["id": .string("S-1"), "trackingToken": .string("tok_abc")]),
            .object(["id": .string("S-2")]),
            .object(["id": .string("S-3"), "trackingToken": .string("")]),
        ])]
        XCTAssertEqual(API.trackingToken(in: store, orderId: "S-1"), "tok_abc")
        XCTAssertNil(API.trackingToken(in: store, orderId: "S-2"))
        XCTAssertNil(API.trackingToken(in: store, orderId: "S-3"))
        XCTAssertNil(API.trackingToken(in: store, orderId: "S-9"))
        XCTAssertNil(API.trackingToken(in: [:], orderId: "S-1"))
    }

    func testThePathIsTheContractsWithTheTokenAsOneSegment() {
        XCTAssertEqual(API.photosTail(token: "tok_abc-1"), "/published/tok_abc-1/photos")
        // A token is opaque: a slash in it must not become a second segment.
        XCTAssertEqual(API.photosTail(token: "a/b?c"), "/published/a%2Fb%3Fc/photos")
    }

    func testAListedPhotoIsFetchedOnlyFromTheCloudItself() {
        let base = "https://cloud.khaytapp.com/"
        XCTAssertEqual(API.cloudURL(base, path: "/v1/p/tok/photos/abc")?.absoluteString,
                       "https://cloud.khaytapp.com/v1/p/tok/photos/abc")
        XCTAssertNil(API.cloudURL(base, path: "https://elsewhere.example/x.jpg"))
        XCTAssertNil(API.cloudURL(base, path: "//elsewhere.example/v1/x"))
        XCTAssertNil(API.cloudURL(base, path: "/v1/../admin"))
        XCTAssertNil(API.cloudURL("http://cloud.khaytapp.com", path: "/v1/p/tok"), "never over plain http")
    }

    func testEachRefusalSaysWhatToDo() {
        func body(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        XCTAssertEqual(API.photoFailure(status: 409, body: body(["error": "full", "max": 6])), .full(max: 6))
        XCTAssertEqual(API.photoFailure(status: 409, body: Data()), .full(max: 6))
        XCTAssertEqual(API.photoFailure(status: 413, body: body(["error": "Photo too large", "maxBytes": 2_000_000])), .tooLarge)
        XCTAssertEqual(API.photoFailure(status: 404, body: Data()), .notPublished)
        XCTAssertEqual(API.photoFailure(status: 403, body: Data()), .viewer)
        XCTAssertEqual(API.photoFailure(status: 400, body: body(["error": "That image is damaged"])), .notAnImage)
        XCTAssertEqual(API.photoFailure(status: 500, body: body(["error": "Storage is down"])), .other("Storage is down"))
        for f in [API.PhotoFailure.full(max: 6), .tooLarge, .notPublished, .viewer, .notAnImage] {
            let words = f.errorDescription ?? ""
            XCTAssertFalse(words.isEmpty || words.hasPrefix("photos."), "\(f) has no words")
        }
        XCTAssertTrue(API.PhotoFailure.full(max: 6).errorDescription!.contains("6"))
    }

    /// A portrait photo as the camera writes it: landscape pixels with an
    /// orientation tag. What is sent must be portrait PIXELS, because the cloud
    /// strips the tag.
    func testAPhotoIsSentUprightWithoutAnOrientationTag() throws {
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300),
                                                format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) }
        let tagged = UIImage(cgImage: try XCTUnwrap(landscape.cgImage), scale: 1, orientation: .right)
        XCTAssertEqual(tagged.size, CGSize(width: 300, height: 400))

        let data = try XCTUnwrap(OrderPhotoPrep.upright(tagged))
        XCTAssertLessThanOrEqual(data.count, API.maxPhotoBytes)
        XCTAssertFalse(OrderPhotoPrep.isPNG(data))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 300)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 400)
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        XCTAssertEqual(orientation, 1, "upright pixels, no rotation left for a viewer to apply")
    }

    func testALargePhotoIsShrunkToTheCap() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 6000, height: 4000),
                                          format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in
                // Noise compresses badly — the worst case for the byte cap.
                for i in 0..<400 {
                    UIColor(hue: CGFloat(i % 37) / 37, saturation: 1, brightness: 1, alpha: 1).setFill()
                    ctx.fill(CGRect(x: (i * 151) % 6000, y: (i * 97) % 4000, width: 300, height: 200))
                }
            }
        let data = try XCTUnwrap(OrderPhotoPrep.upright(big))
        XCTAssertLessThanOrEqual(data.count, API.maxPhotoBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(props[kCGImagePropertyPixelWidth] as? Int ?? .max, Int(OrderPhotoPrep.maxEdge))
    }

    func testTheListShapeDecodes() throws {
        let json = #"{"kind":"order","payload":{},"action":null,"payment":null,"photos":[{"id":"0123456789abcdef0123456789abcdef","url":"/v1/p/tok/photos/0123456789abcdef0123456789abcdef","mime":"image/jpeg","bytes":81234,"at":"2026-10-10T08:00:00Z"}]}"#
        struct Item: Decodable { let photos: [API.OrderPhoto]? }
        let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(item.photos?.first?.bytes, 81234)
        XCTAssertEqual(item.photos?.first?.url, "/v1/p/tok/photos/0123456789abcdef0123456789abcdef")
    }
}
