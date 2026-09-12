import Foundation
import KhaytCore

/// `Khayt --check-resources` — is this bundle self-contained?
///
/// ── WHY THIS COMMAND EXISTS ───────────────────────────────────────────────
///
/// 4.0.0-alpha.1 and 4.0.0-alpha.2 were signed, notarised, stapled, and could
/// not launch. `Bundle.module` compiles down to two hard-coded paths — the app
/// bundle's root, and the absolute path of the `.build` directory on the
/// machine that compiled it — so every build made on the developer's Mac ran by
/// reaching OUTSIDE the app into a directory no shop has. On CI that path is
/// `/Users/runner/work/Khayt/Khayt/…`, and the app died on its first line:
///
///     Fatal error: could not load resource bundle
///
/// Everything in the release reported success, because nothing in the release
/// ever asked the built app a question.
///
/// ── WHY IT ASKS THE QUESTION THIS WAY ─────────────────────────────────────
///
/// Launching the app is not the check. On the build machine — and CI IS a build
/// machine — the `.build` directory is right there, so a broken app launches
/// perfectly and the check passes. The invariant that actually matters is not
/// "it started", it is WHERE IT FOUND ITS RESOURCES: inside itself, or
/// somewhere else on that particular disk. So this resolves each bundle and
/// requires the path to be within `Bundle.main.bundleURL`.
///
/// That makes it true on CI without moving anything, and it needs no window
/// server — it runs before AppKit, and it is the whole path that crashed:
/// `BundledResources` → `JSRuntime` → every module and locale.
enum ResourceCheck {

    static func run() -> Int32 {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        var failed = false

        func report(_ what: String, _ bundle: Bundle) {
            let url = bundle.bundleURL.resolvingSymlinksInPath()
            // `path` with a trailing separator, so `/tmp/Khayt.app` does not
            // count as being inside `/tmp/Khayt.app.old`.
            let inside = (url.path + "/").hasPrefix(app.path + "/")
            say("\(inside ? "  ok  " : "FAIL  ")\(what): \(url.path)")
            if !inside {
                say("     ↑ OUTSIDE \(app.path) — this build depends on the machine that made it")
                failed = true
            }
        }

        say("checking \(app.path)")
        report("shared JavaScript", BundledResources.javaScript)
        report("app resources", AppResources.bundle)

        // Resolving the bundles is not the same as being able to read them: a
        // directory that exists and is missing a module fails at the first call
        // into the engine, which is a screen away rather than a line away.
        do {
            _ = try KhaytEngine()
            say("  ok  engine: every bundled module and locale loaded")
        } catch {
            say("FAIL  engine: \(error)")
            failed = true
        }

        for (what, name, ext) in [("sample shop", "sample-shop", "json"),
                                  ("invoice stylesheet", "invoice", "css"),
                                  // Missing, the filament search silently finds
                                  // nothing — which reads as "Khayt does not
                                  // have your filament" rather than as a broken
                                  // build.
                                  ("filament catalogue", "filament-catalog", "json")] {
            if let url = AppResources.bundle.url(forResource: name, withExtension: ext),
               let size = try? Data(contentsOf: url).count, size > 0 {
                say("  ok  \(what): \(size) bytes")
            } else {
                // Neither of these crashes the app. The sample book simply
                // refuses to open, and the invoice prints with no styling at
                // all — a shop's own document, sent to a customer, as raw HTML.
                say("FAIL  \(what): \(name).\(ext) is not in this bundle")
                failed = true
            }
        }

        say(failed ? "NOT self-contained" : "self-contained")
        return failed ? 1 : 0
    }

    /// stdout, unbuffered — this runs before AppKit and may be the last thing
    /// the process does.
    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
