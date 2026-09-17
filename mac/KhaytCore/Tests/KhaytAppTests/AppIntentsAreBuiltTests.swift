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
struct AppIntentsAreBuiltTests {

    static func script() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytAppTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .appending(path: "../make-app.sh")
        return try String(contentsOf: url.standardizedFileURL, encoding: .utf8)
    }

    @Test("the const values are searched for by name, not down a symlinked path")
    func searchIsByName() throws {
        let text = try Self.script()
        #expect(text.contains("-name 'KhaytApp.swiftconstvalues'"),
                "the search is not by name, so a moved build layout goes quiet again")
        #expect(!text.contains(".build/release/KhaytApp.build"),
                "the symlinked products path is back; it holds no build intermediates")
    }

    @Test("the compiler is still asked to emit them")
    func emissionIsRequested() throws {
        // Without this flag there are no const values to find, wherever the
        // search looks.
        #expect(try Self.script().contains("-emit-const-values"))
    }

    @Test("a build without them complains on stderr rather than reporting a state")
    func theFailureIsLoud() throws {
        let text = try Self.script()
        let marker = "app intents: NO CONST VALUES FOUND"
        let line = try #require(text.split(separator: "\n").first { $0.contains(marker) },
                                "the loud message is gone")
        #expect(line.contains(">&2"),
                "the failure prints to stdout, which is how it hid in a build log")
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
