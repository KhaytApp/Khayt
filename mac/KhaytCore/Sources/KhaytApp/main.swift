import Foundation

// The writing direction must be settled before AppKit starts, so this runs
// first and `KhaytApp` is not `@main`. See `Direction.swift` for why the
// SwiftUI environment cannot be used for this.
// Before anything else that could fail: an uncaught Objective-C exception
// produces a crash report with a backtrace and NO REASON, and finding out why
// the app died should not require reproducing it.
LastWords.listen()
// Nothing unless `KHAYT_TEST_ABORT` is set, and the whole point of the line
// above when it is.
LastWords.abortIfAsked()

// `--check-resources`: can this bundle find what is inside it?
//
// BEFORE `Words.preload`, which is where the answer used to be a crash rather
// than an answer. See `ResourceCheck` — it exists because two notarised alphas
// shipped unable to launch anywhere but the Mac that built them, and nothing in
// the release ever asked the built app a single question.
if CommandLine.arguments.contains("--check-resources") {
    exit(ResourceCheck.run())
}
Direction.settle()
// The menu bar is built as the scene is created and its item titles are never
// rewritten, so the shop's own words for the stages have to be in hand BEFORE
// AppKit starts. See `Words.warm`.
Words.preload(Direction.shopLanguage())

// `--import` runs WITHOUT the window, and returns before AppKit is started.
//
// Not inside `applicationDidFinishLaunching` like the screenshot runner: that
// needs the app, and the app means a window opening and taking focus in the
// middle of somebody's work — for a command that prints lines and exits. The
// import touches JavaScriptCore, the filesystem and the store lock, none of
// which want an NSApplication.
//
// The main actor's work is serviced by pumping this thread's run loop, because
// blocking it outright would leave every `@MainActor` hop with nowhere to run.
switch ImportCommand.parse(CommandLine.arguments) {
case .notAsked:
    break
case .usage(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)                                    // EX_USAGE
case .run(let options):
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code: Int32 = 1
    Task { @MainActor in
        code = await ImportCommand.run(options)
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    exit(code)
}

// See `DisplayCycle` for the crash this prevents and the measurement.
// Before `NSApplication` exists: the first window is built during launch and
// the assertion can fire on it.
DisplayCycle.stopAssertingOnSwiftUIsLoop()

KhaytApp.main()
