import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The phone reads the labels both desktops print, through `lib/scan.js`.
final class LabelScanTests: XCTestCase {
    func testEveryLabelTheDesktopsPrintIsReadForWhatItNames() async throws {
        let engine = try KhaytEngine()
        let spool = try await engine.scanCode("KHAYT-SPOOL:SP-201")
        XCTAssertEqual(spool.type, "spool"); XCTAssertEqual(spool.id, "SP-201")
        let order = try await engine.scanCode("KHAYT-ORDER:INV-2026-17")
        XCTAssertEqual(order.type, "order"); XCTAssertEqual(order.id, "INV-2026-17")
        let track = try await engine.scanCode("https://cloud.khaytapp.com/p/abc123DEF")
        XCTAssertEqual(track.type, "track"); XCTAssertEqual(track.token, "abc123DEF")
        let other = try await engine.scanCode("https://example.com/menu")
        XCTAssertEqual(other.type, "unknown", "a code that is not Khayt's is said to be so, not guessed at")
    }
}
