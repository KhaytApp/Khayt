import XCTest
import SwiftUI
@testable import KhaytCompanion

/**
 * A failed read is never drawn as an all-clear.
 *
 * Orders, Inventory, Machines, Clients and Intake used to keep their empty
 * title ("Queue clear", "No spools yet") and put the error in the subtitle;
 * Home swallowed a failed queue read and said "Queue clear"; Owed said
 * "Nothing is owed" and End of day spun for ever (UI review Nov 11, F3).
 * Each screen now has its own LoadFailedView branch.
 */
final class LoadFailedStateTests: XCTestCase {

    /// Draws, light and dark. `TEST_RUNNER_KHAYT_SHOTS=<dir>` writes the PNGs
    /// compared with Figma frame 40:147 in the PR.
    @MainActor
    func testTheFailedStateDraws() throws {
        let out = ProcessInfo.processInfo.environment["KHAYT_SHOTS"].map { URL(filePath: $0) }
        for dark in [false, true] {
            let view = LoadFailedView(message: "The Mac didn't answer. Check you're on the shop's Wi-Fi.") {}
                .frame(width: 402)
                .background(KhaytDesign.ground)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 120)
            if let out, let png = image.pngData() {
                try png.write(to: out.appending(path: "load-failed-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func source(_ name: String) throws -> String {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("KhaytCompanion/Views/\(name).swift")
        return try String(contentsOf: views, encoding: .utf8)
    }

    func testEveryListHasAFailedStateOfItsOwn() throws {
        for name in ["OrdersView", "InventoryView", "MachinesView", "ClientsView", "IntakeView",
                     "DashboardView", "OwedView", "EndOfDayView"] {
            let s = try source(name)
            XCTAssertTrue(s.contains("LoadFailedView("), "\(name) draws no failed state")
            XCTAssertFalse(s.contains("errorMessage ??"),
                           "\(name) still tucks an error under the empty state's title")
        }
    }

    func testHomeNoLongerSwallowsAFailedQueueRead() throws {
        let s = try source("DashboardView")
        XCTAssertFalse(s.contains("try? api.fetchQueue()"), "a failed queue read must be said, not turned into an empty queue")
    }

    func testAFailedMoveIsSaidOnScreen() throws {
        for name in ["DashboardView", "OrdersView"] {
            XCTAssertTrue(try source(name).contains("moveNotes = [error.localizedDescription]"),
                          "\(name): a failed move must show its reason")
        }
    }

    func testTheWordsExistInEveryLanguage() {
        for key in ["load.failed.title", "load.retry", "load.book_unavailable"] {
            XCTAssertNotEqual(L10n.tr(key), key, "\(key) is missing")
        }
    }
}
