import XCTest
@testable import KhaytCompanion

/**
 * The widget and the app have to mean the same thing by a snapshot.
 *
 * ── WHAT DRIFT DOES HERE, AND WHY NOTHING SAYS SO ─────────────────────────
 *
 * `WidgetSnapshot`, `WidgetPrint` and `WidgetSnapshotStore` are declared TWICE:
 * once in the app, once in `KhaytWidget/KhaytQueueWidget.swift`, whose own
 * comment says "Duplicate for the widget target — keep in sync". They are two
 * targets and the type travels between them as JSON through an App Group, so
 * there is no compiler anywhere that sees both.
 *
 * Add a non-optional field to the app's copy and the widget's decode throws.
 * `load()` swallows it — it is `try?` — and returns nil, and the widget falls
 * back to `sample`. The failure is a shop looking at a Home Screen widget
 * showing somebody else's invented numbers, with nothing logged and nothing on
 * fire. It would be read as "the widget is stale", which is the wrong problem.
 *
 * ── THIS IS A GUARD, NOT THE FIX ──────────────────────────────────────────
 *
 * The fix is one declaration compiled into both targets, which means an
 * exception set in the project file so the two folders can share a source file.
 * That is a change worth making deliberately and with the widget built on a
 * device. Until then, this refuses the drift rather than waiting for a shop to
 * find it.
 */
final class WidgetSnapshotIsOneShapeTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // KhaytCompanionTests
            .deletingLastPathComponent()      // ios
            .appending(path: relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The stored properties of `struct <name>`, in order, as "name: Type".
    private func fields(of name: String, in swift: String) throws -> [String] {
        guard let start = swift.range(of: "struct \(name)") else {
            throw XCTSkip("struct \(name) not found — it has been renamed or moved")
        }
        let body = swift[start.upperBound...]
        guard let open = body.firstIndex(of: "{"), let close = body.firstIndex(of: "}") else {
            throw XCTSkip("could not read the body of \(name)")
        }
        return body[body.index(after: open)..<close]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("var ") || $0.hasPrefix("let ") }
            .map { line -> String in
                // "var queued: Int        // a comment" -> "queued: Int"
                let noKeyword = line.dropFirst(4)
                let noComment = noKeyword.components(separatedBy: "//")[0]
                return noComment.trimmingCharacters(in: .whitespaces)
            }
    }

    func testTheTwoCopiesOfTheSnapshotAgree() throws {
        let app = try source("KhaytCompanion/Services/WidgetSnapshotStore.swift")
        let widget = try source("KhaytWidget/KhaytQueueWidget.swift")

        for type in ["WidgetSnapshot", "WidgetPrint"] {
            let inApp = try fields(of: type, in: app)
            let inWidget = try fields(of: type, in: widget)
            XCTAssertFalse(inApp.isEmpty, "\(type) has no stored properties in the app — the parse is wrong")
            XCTAssertEqual(inApp, inWidget, """
                \(type) has drifted between the app and the widget.

                app:    \(inApp)
                widget: \(inWidget)

                They travel as JSON through the App Group, so no compiler sees both. A field
                the widget does not know about makes its decode throw, `load()` swallows it,
                and the widget shows SAMPLE data on a shop's Home Screen with nothing logged.
                """)
        }
    }

    func testBothCopiesReadTheSameBoxWithTheSameKey() throws {
        let app = try source("KhaytCompanion/Services/WidgetSnapshotStore.swift")
        let widget = try source("KhaytWidget/KhaytQueueWidget.swift")

        // The App Group and the defaults key are the address. Change one copy
        // and the widget reads an empty box forever — which looks exactly like
        // an app that has not run yet.
        for token in ["group.com.khaytapp.companion", "khayt.widget.snapshot"] {
            XCTAssertTrue(app.contains(token), "the app no longer uses \(token)")
            XCTAssertTrue(widget.contains(token), "the widget no longer uses \(token)")
        }
    }
}
