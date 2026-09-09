import Foundation

/// Saying why the app died.
///
/// A macOS crash report for an uncaught Objective-C exception carries the
/// backtrace and NOT the reason: the `Last Exception Backtrace` names
/// `objc_exception_throw` and nothing tells you what the exception said. That
/// cost a whole investigation — an AppKit abort out of
/// `_postWindowNeedsUpdateConstraints` with no message, on a machine that was
/// not this one, from a build that could not be made to do it on demand.
///
/// So the app writes its own last words: the exception's name, its reason and
/// its backtrace, beside the store where a shop can find them and send them on.
/// One file, overwritten each time, because the interesting crash is the one
/// that just happened.
///
/// **PROVEN, NOT ASSUMED.** `KHAYT_TEST_ABORT` makes the app raise on purpose
/// and `KHAYT_CRASH_NOTE` sends the note somewhere a test can read it, so
/// "the app can say why it died" is a thing this repository checks rather than
/// a thing it believes. It is checked because the belief was tested and had
/// been wrong before: after the abort of 2026-09-07 there was no note, and
/// three separate explanations for that were plausible and unmeasurable.
///
/// **This does not catch Swift runtime traps** — a force-unwrap of nil, an
/// array out of bounds, a `precondition`. Those are not exceptions and nothing
/// can catch them; they still produce an ordinary crash report, which for a
/// Swift trap DOES name the reason. It catches the AppKit and Foundation
/// exceptions, which are the ones that arrive mute.
@MainActor
enum LastWords {

    /// Where it goes. Beside the store, not in a log directory nobody opens.
    static func file(for build: StoreReader.Build) -> URL {
        build.storeURL.deletingLastPathComponent().appending(path: "last-crash.txt")
    }

    /// Install the handler. Safe to call twice; the second wins.
    ///
    /// NOT a `try/catch` around anything — an uncaught Objective-C exception
    /// has already unwound past every Swift frame by the time this runs, and
    /// the process is going to die. The one job here is to leave a note.
    /// Where the note goes, as plain paths.
    ///
    /// A `static` rather than a capture: `NSSetUncaughtExceptionHandler` takes
    /// a C function pointer, which cannot close over anything, so whatever the
    /// handler needs has to be somewhere it can reach without a capture.
    nonisolated(unsafe) static var targets: [URL] = []

    static func listen() {
        // Both books, because which one is open is not known this early and a
        // crash before the book opens is exactly the kind worth reading.
        //
        // `KHAYT_CRASH_NOTE` sends it somewhere else instead. That is how the
        // test proves this works without writing over the note from a real
        // crash on the machine running the test — and it is the answer for a
        // shop asked to put one somewhere it can be collected from.
        if let elsewhere = ProcessInfo.processInfo.environment["KHAYT_CRASH_NOTE"],
           !elsewhere.isEmpty {
            targets = [URL(fileURLWithPath: elsewhere)]
        } else {
            targets = StoreReader.Build.allCases.map(file(for:))
        }
        NSSetUncaughtExceptionHandler { exception in
            LastWords.leave(what: exception.name.rawValue,
                            why: exception.reason,
                            where: exception.callStackSymbols)
        }
    }

    /// Write the note.
    nonisolated static func leave(what: String, why: String?, where stack: [String]) {
        let note = """
            Khayt for Mac stopped unexpectedly.

            when:   \(ISO8601DateFormatter().string(from: Date()))
            what:   \(what)
            why:    \(why ?? "(no reason given)")

            where:
            \(stack.prefix(40).joined(separator: "\n"))
            """
        for url in LastWords.targets {
            // Best effort by design: a handler that throws while reporting a
            // crash has turned one problem into two.
            try? note.write(to: url, atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(Data((note + "\n").utf8))
    }

    /// Die on purpose, the way AppKit does, when asked to.
    ///
    /// Only reachable by setting `KHAYT_TEST_ABORT`, and it runs before AppKit
    /// starts, so it costs a shop nothing and never opens a window. It exists
    /// because the wiring here is only worth having if it is PROVEN — and the
    /// way to prove a crash handler is to crash.
    static func abortIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard let reason = env["KHAYT_TEST_ABORT"], !reason.isEmpty else { return }
        NSException(name: .init("KhaytDeliberateException"),
                    reason: reason, userInfo: nil).raise()
    }

    /// The note from the last crash, if there is one.
    static func read(for build: StoreReader.Build) -> String? {
        try? String(contentsOf: file(for: build), encoding: .utf8)
    }

    /// Forget it — once a shop has been shown it, it is not news any more.
    static func clear(for build: StoreReader.Build) {
        try? FileManager.default.removeItem(at: file(for: build))
    }
}

/// Switch off an AppKit assertion that SwiftUI trips on its own.
///
/// ── THE CRASH ─────────────────────────────────────────────────────────────
///
///   NSGenericException: The window has been marked as needing another Update
///   Constraints in Window pass, but it has already had more Update Constraints
///   in Window passes than there are views in the window.
///
/// That is AppKit's LOOP DETECTOR, not a rule about when constraints may be
/// invalidated — the distinction cost two wrong diagnoses before anybody read
/// the reason string. SwiftUI's `AppKitPlatformViewHost` re-invalidates the
/// hosting view more times than the window has views, and AppKit throws from a
/// display-cycle observer, where nothing catches it, so the process dies.
///
/// It is a framework bug, with a twelve-line reproducer on Apple's forums
/// (thread 780803): a `.sheet` inside a `NavigationSplitView`. `ShopWindow` has
/// sixteen sheets on one split view, which is presumably why this shop meets
/// it daily and most apps never do. Both halves of the loop are SwiftUI
/// internals; there is nothing on our side of the line to fix.
///
/// With the assertion off, AppKit does what it does at every other cycle limit:
/// stops iterating and draws what it has. The cost is a frame that may be one
/// pass stale. The alternative is the app closing while somebody is working.
///
/// `register` rather than `set`, so it is a DEFAULT and not a preference — it
/// writes nothing to disk, and anybody who wants the assertion back can have it
/// with `defaults write app.khayt.mac NSWindowAssertWhenDisplayCycleLimitReached -bool YES`.
///
/// MEASURED: `KHAYT_CHURN=200` crashed 4 runs in 6 without this and 0 in 12
/// with it. Delete this when a macOS release fixes the framework, and run the
/// churn driver to find out.
enum DisplayCycle {
    static let key = "NSWindowAssertWhenDisplayCycleLimitReached"

    static func stopAssertingOnSwiftUIsLoop() {
        UserDefaults.standard.register(defaults: [key: false])
    }
}
