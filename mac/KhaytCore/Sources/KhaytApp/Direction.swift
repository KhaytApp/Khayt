import Foundation
import AppKit

/// Which way this window reads.
///
/// ── WHY NOT `.environment(\.layoutDirection, .rightToLeft)` ──────────────────
/// Because it does not work. That one line sends SwiftUI's `NavigationSplitView`
/// into an unbounded layout loop on macOS 26 — `SplitViewChildController`
/// re-invalidates on every pass, the window grows past 3000pt, and AppKit aborts
/// with "more Update Constraints in Window passes than there are views in the
/// window". Measured, bisected, and not caused by either column's width.
///
/// ── WHAT DOES WORK ──────────────────────────────────────────────────────────
/// The way AppKit has always done it. `NSForceRightToLeftWritingDirection` and
/// `AppleTextDirection` are the defaults Apple documents for testing right-to-left
/// layout, and setting them flips the whole application: the split view, the
/// toolbar, the table's columns, the traffic lights. SwiftUI is never asked to
/// mirror anything, so there is nothing for it to loop over.
///
/// ── WHY IT HAS TO HAPPEN BEFORE `main()` ────────────────────────────────────
/// AppKit reads them once, on the way up. Setting them from inside a running app
/// changes nothing until the next launch — which is why this is a `main.swift`
/// and `KhaytApp` is not `@main`.
enum Direction {

    /// Languages that read right to left. Only Arabic is bundled today; the
    /// list is the thing to add to, not the condition below.
    static let rtlLanguages: Set<String> = ["ar", "fa", "he", "ur"]

    /// The language this Mac's book is kept in, resolved without SwiftUI,
    /// AppKit or the engine — none of which exist yet at this point.
    static func shopLanguage() -> String {
        if let forced = ProcessInfo.processInfo.environment["KHAYT_LANG"] { return forced }
        let stores = StoreReader.Build.allCases
            .filter(\.exists)
            .sorted { ($0.lastWritten ?? .distantPast) > ($1.lastWritten ?? .distantPast) }
        for build in stores {
            guard let data = try? Data(contentsOf: build.storeURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let settings = root["settings"] as? [String: Any],
                  let lang = settings["lang"] as? String, !lang.isEmpty else { continue }
            return lang
        }
        return "en"
    }

    /// Settle the writing direction, then hand over to the app.
    ///
    /// Both keys are always written, never only the true one: a shop that moves
    /// from Arabic to English would otherwise keep a mirrored window for ever,
    /// because the value it set last time is still sitting in its own defaults.
    static func settle() {
        let rtl = rtlLanguages.contains(shopLanguage())
        let defaults = UserDefaults.standard
        let wasRTL = defaults.bool(forKey: "NSForceRightToLeftWritingDirection")
        defaults.set(rtl, forKey: "NSForceRightToLeftWritingDirection")
        defaults.set(rtl, forKey: "AppleTextDirection")

        // AppKit has already read them if it is going to. When the answer has
        // changed since last launch, the only way to apply it is to start again
        // — once, and only when it actually changed, so this can never loop.
        guard rtl != wasRTL, ProcessInfo.processInfo.environment["KHAYT_NO_RELAUNCH"] == nil else { return }
        defaults.synchronize()
        relaunch()
    }

    /// Start this binary again, once. `execv` rather than a new process: the Dock
    /// icon, the window and the terminal that started it all stay put, and there
    /// is never a moment with two Khayts holding one book.
    private static func relaunch() {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var args = CommandLine.arguments
        args[0] = path
        // Marks the child so it cannot decide to relaunch again, whatever it
        // reads. One restart, or none.
        setenv("KHAYT_NO_RELAUNCH", "1", 1)
        let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        execv(path, cArgs)
        // execv only returns on failure, and a failure here is not worth
        // refusing to start over: carry on in the direction we have.
    }
}
