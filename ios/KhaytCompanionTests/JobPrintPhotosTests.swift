import XCTest
import UIKit
import KhaytCore
@testable import KhaytCompanion

/// The job's photos as the Mac (`OrderPhoto.record`) and the desktop
/// (`captureFinishPhotos`, the order editor) write them into
/// `printLog[].printPhotos[]`: `{ thumb: data URI, filename }`.
final class JobPrintPhotosTests: XCTestCase {
    typealias API = KhaytAPIClient

    /// A real 2×2 JPEG, as both apps' thumbnails are.
    private lazy var jpeg: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.jpegData(compressionQuality: 0.85)!
    }()
    private var uri: String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }

    func testTheRecordsTheMacAndTheDesktopWriteDecode() {
        let store: [String: JSONValue] = ["printLog": .array([
            .object(["id": .string("J0"), "printPhotos": .array([])]),
            .object(["id": .string("J1"), "printPhotos": .array([
                // The shop's own photo, on the Mac.
                .object(["thumb": .string(uri), "filename": .string("J1-0-mabc123.jpg")]),
                // The printer's snapshot at the end of a print (desktop #2259):
                // the same shape, with nothing saying where it came from.
                .object(["thumb": .string(uri), "filename": .string("J1-0-mabc999.jpg")]),
            ])]),
        ])]
        let photos = API.printPhotos(in: store, orderId: "J1")
        XCTAssertEqual(photos.map(\.index), [0, 1])
        XCTAssertEqual(photos.map(\.filename), ["J1-0-mabc123.jpg", "J1-0-mabc999.jpg"])
        XCTAssertEqual(photos.first?.thumb, jpeg)
        XCTAssertNotNil(UIImage(data: photos[0].thumb), "the thumbnail draws")
        XCTAssertEqual(API.printPhotos(in: store, orderId: "J0"), [])
        XCTAssertEqual(API.printPhotos(in: store, orderId: "J9"), [])
        XCTAssertEqual(API.printPhotos(in: [:], orderId: "J1"), [])
    }

    func testAPhotoWithoutAFileStillShowsAndBadRowsKeepTheOthersIndex() {
        let store: [String: JSONValue] = ["printLog": .array([
            .object(["id": .string("J1"), "printPhotos": .array([
                // An old book's bare filename: nothing to draw.
                .string("a.jpg"),
                // The desktop editor's row before its file is saved.
                .object(["thumb": .string(uri), "filename": .null]),
                .object(["thumb": .string(uri), "filename": .string("")]),
                // Never fetched: only inline image bytes are read.
                .object(["thumb": .string("https://elsewhere.example/x.jpg"), "filename": .string("x.jpg")]),
                .object(["filename": .string("y.jpg")]),
                .object(["thumb": .string(uri), "filename": .string("J1-5-z.jpg")]),
            ])]),
        ])]
        let photos = API.printPhotos(in: store, orderId: "J1")
        XCTAssertEqual(photos.map(\.index), [1, 2, 5])
        XCTAssertEqual(photos.map(\.filename), [nil, nil, "J1-5-z.jpg"])
    }

    func testOnlyAnInlineJpegOrPngIsDecoded() {
        XCTAssertEqual(API.thumbBytes(uri), jpeg)
        XCTAssertEqual(API.thumbBytes("DATA:IMAGE/JPEG;BASE64," + jpeg.base64EncodedString()), jpeg)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(API.thumbBytes("data:image/png;base64," + png.base64EncodedString()), png)
        // The type says JPEG, the bytes say otherwise.
        XCTAssertNil(API.thumbBytes("data:image/jpeg;base64," + Data("<svg/>".utf8).base64EncodedString()))
        XCTAssertNil(API.thumbBytes("data:image/svg+xml;base64," + Data("<svg/>".utf8).base64EncodedString()))
        XCTAssertNil(API.thumbBytes("data:image/jpeg;base64,"))
        XCTAssertNil(API.thumbBytes("J1-0-abc.jpg"))
        // Far bigger than any thumbnail either app writes.
        let huge = Data([0xFF, 0xD8, 0xFF]) + Data(count: API.maxThumbBytes + 10)
        XCTAssertNil(API.thumbBytes("data:image/jpeg;base64," + huge.base64EncodedString()))
    }
}
