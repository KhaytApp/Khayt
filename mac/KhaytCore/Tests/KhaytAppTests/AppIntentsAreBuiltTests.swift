import Foundation
import Testing

/// Khayt's App Intents have to reach the built app, and for a long time they
/// did not.
///
/// ── WHAT HAPPENED ─────────────────────────────────────────────────────────
///
/// `make-app.sh` runs `appintentsmetadataprocessor`, which needs the
/// `.swiftconstvalues` the compiler emits under `-emit-const-values`. It looked
/// for them in `$PKG/.build/release/KhaytApp.build` and found nothing —
/// **every build, for the life of the script.**
///
/// Two mistakes hiding each other: `.build/release` is a SYMLINK, now to
/// `out/Products/Release`, which holds products rather than build
/// intermediates; and `find` does not descend a symlink handed to it as a
/// starting path. The const values are beside the object files, under
/// `.build/<triple>/release/KhaytApp.build`.
///
/// The `else` branch then printed
///
///     app intents: no const values — Shortcuts and Siri will not see them
///
/// which reads like a known limitation rather than a fault, on stdout, in the
/// middle of a build log. So the app shipped with **no Shortcuts and no Siri**,
/// and nothing on any screen would have told anybody.
///
/// Fixed, and guarded here: the search is by NAME under `.build`, so the next
/// time SwiftPM moves its layout it keeps working instead of going quiet.
///
/// ── AND THEN IT MOVED AGAIN ──────────────────────────────────────────────
///
/// Searching by name held until Xcode 27 / Swift 6.4 built SwiftPM through
/// Swift Build: KhaytApp is compiled whole-module inside the product and its
/// file is `Khayt-primary.swiftconstvalues`, under `Intermediates.noindex`.
/// Every release from 4.0.0-alpha.40 to alpha.68 shipped with NO
/// `Metadata.appintents`, and the warning sat unread in each release log. So
/// the search is now by CONTENT (a file naming a `KhaytApp.` type), and a
/// build that finds none STOPS unless a dev build opts out.
struct AppIntentsAreBuiltTests {

    static func script() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytAppTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .appending(path: "../make-app.sh")
        return try String(contentsOf: url.standardizedFileURL, encoding: .utf8)
    }

    @Test("the const values are found by what they hold, not by a file name or path")
    func searchIsByContent() throws {
        let text = try Self.script()
        #expect(text.contains("-name '*.swiftconstvalues'"),
                "the search is narrowed to one file name again, so a moved build layout goes quiet")
        #expect(text.contains(#"grep -l '"KhaytApp\.'"#),
                "the search no longer picks files by the KhaytApp types they name")
        #expect(!text.contains(".build/release/KhaytApp.build"),
                "the symlinked products path is back; it holds no build intermediates")
    }

    @Test("the compiler is still asked to emit them")
    func emissionIsRequested() throws {
        // Without this flag there are no const values to find, wherever the
        // search looks.
        #expect(try Self.script().contains("-emit-const-values"))
    }

    @Test("a build without them stops, unless a dev build opts out by name")
    func theFailureStopsTheBuild() throws {
        let text = try Self.script()
        #expect(text.contains("ai_fail \"NO CONST VALUES FOUND"),
                "finding nothing no longer goes through the failing path")
        // The failing path prints to stderr and exits — a warning is what let
        // twenty-eight releases ship without Shortcuts.
        let start = try #require(text.range(of: "ai_fail() {"), "ai_fail is gone")
        let end = try #require(text.range(of: "\n}", range: start.upperBound..<text.endIndex))
        let body = String(text[start.upperBound..<end.lowerBound])
        #expect(body.contains(">&2"), "the failure prints to stdout, which is how it hid in a build log")
        #expect(body.contains("exit 1"), "the failure warns and carries on; a release can ship without intents")
        #expect(body.contains("KHAYT_ALLOW_NO_INTENTS"), "the opt-out is no longer named")
    }

    @Test("every intent the app declares is one the build can find")
    func intentsAreInTheModuleTheProcessorScans() throws {
        // The processor is given `Sources/KhaytApp` only. An intent declared in
        // KhaytCore would compile, run, and never appear in Shortcuts.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        var strays: [String] = []
        var found = 0
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains(": AppIntent") || text.contains(": AppShortcutsProvider")
            else { continue }
            found += 1
            if !url.path.contains("/Sources/KhaytApp/") {
                strays.append(url.lastPathComponent)
            }
        }
        #expect(found > 0, "no App Intents found at all — the scan has rotted")
        #expect(strays.isEmpty, Comment(rawValue:
            "declared outside KhaytApp, so `appintentsmetadataprocessor` is never "
            + "shown them and they will not appear in Shortcuts: \(strays.sorted())"))
        #expect(try Self.script().contains("$PKG/Sources/KhaytApp"),
                "the processor is no longer given the module that holds them")
    }
}
