import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The phone shows a printer's camera by `lib/webcam.js`'s own rules — the
/// same calls `KhaytAPIClient.camera` and `snapshotHeadersOK` make.
final class CameraRulesTests: XCTestCase {
    private struct Allowed: Decodable { let ok: Bool; let reason: String? }

    private func allowed(_ url: String, host: String) async throws -> Allowed {
        let engine = try KhaytEngine()
        return try await engine.raw(#"KhaytWebcam.assertWebcamHostAllowed("\#(url)", {"type":"moonraker","host":"\#(host)"})"#,
                                    as: Allowed.self)
    }

    func testTheSnapshotIsTheStillNeverTheStream() async throws {
        let engine = try KhaytEngine()
        let still = try await engine.raw(#"KhaytWebcam.snapshotUrlFor({"webcam":{"enabled":true,"snapshotUrl":"http://192.168.1.50/webcam/?action=snapshot","streamUrl":"http://192.168.1.50/webcam/?action=stream"}})"#, as: String.self)
        XCTAssertEqual(still, "http://192.168.1.50/webcam/?action=snapshot")
        let streamOnly = try await engine.raw(#"KhaytWebcam.snapshotUrlFor({"webcam":{"enabled":true,"streamUrl":"http://192.168.1.50/webcam/?action=stream"}})"#, as: String.self)
        XCTAssertEqual(streamOnly, "", "a stream never ends, so it is never buffered as a still")
        let off = try await engine.raw(#"KhaytWebcam.snapshotUrlFor({"webcam":{"enabled":false,"snapshotUrl":"http://x/s"}})"#, as: String.self)
        XCTAssertEqual(off, "")
    }

    func testOnlyThePrintersOwnHostOrTheLanIsFetched() async throws {
        let onPrinter = try await allowed("http://192.168.1.50/webcam/?action=snapshot", host: "192.168.1.50")
        XCTAssertTrue(onPrinter.ok)
        let outside = try await allowed("http://evil.example.com/snap.jpg", host: "192.168.1.50")
        XCTAssertFalse(outside.ok)
    }

    func testAFrameIsReadOnlyWhenItIsAnImageOfASaneSize() async throws {
        let engine = try KhaytEngine()
        struct V: Decodable { let ok: Bool; let reason: String? }
        let jpeg = try await engine.raw(#"KhaytWebcam.checkSnapshotHeaders(200, "image/jpeg", 120000)"#, as: V.self)
        XCTAssertTrue(jpeg.ok)
        let html = try await engine.raw(#"KhaytWebcam.checkSnapshotHeaders(200, "text/html", 500)"#, as: V.self)
        XCTAssertFalse(html.ok)
        let moved = try await engine.raw(#"KhaytWebcam.checkSnapshotHeaders(302, "image/jpeg", 10)"#, as: V.self)
        XCTAssertEqual(moved.reason, "redirect_refused")
        let warming = try await engine.raw(#"KhaytWebcam.checkSnapshotHeaders(204, "", null)"#, as: V.self)
        XCTAssertEqual(warming.reason, "no_frame_yet", "a camera with no frame yet is not a broken camera")
    }
}
