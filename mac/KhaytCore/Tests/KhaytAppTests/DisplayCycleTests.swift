import Foundation
import Testing
@testable import KhaytApp

/// The crash a shop met on an ordinary morning, and the two ways to lose the fix.
///
/// A `UserDefaults` default registered in `main.swift` is invisible to every
/// test in this suite, because `main.swift` does not run in one. That is the
/// shape of bug this repository keeps finding: a correct thing with no caller,
/// or a caller quietly deleted. So there are two tests — one that the function
/// does what it says, and one that the app still calls it.
@MainActor
struct DisplayCycleTests {

    @Test("registering the default actually switches the assertion off")
    func theDefaultTakesEffect() {
        DisplayCycle.stopAssertingOnSwiftUIsLoop()
        #expect(UserDefaults.standard.bool(forKey: DisplayCycle.key) == false,
                "the assertion is still armed, so the app can still die mid-click")
    }

    /// A default is a default: it must not be written to disk, or it becomes a
    /// preference nobody can see and nobody set.
    @Test("it registers a default rather than writing a preference")
    func nothingIsPersisted() {
        DisplayCycle.stopAssertingOnSwiftUIsLoop()
        #expect(UserDefaults.standard.object(forKey: DisplayCycle.key) == nil
                || UserDefaults.standard.persistentDomain(forName: "app.khayt.mac")?[DisplayCycle.key] == nil,
                "the key was written to the user's own domain")
    }

    /// THE WIRING. Delete the call from `main.swift` and this fails; without it
    /// the test above passes forever while the app crashes.
    @Test("main.swift calls it, before AppKit starts")
    func theAppStillCallsIt() throws {
        let source = try Self.mainSwift()
        let call = source.range(of: "DisplayCycle.stopAssertingOnSwiftUIsLoop()")
        let start = source.range(of: "KhaytApp.main()")
        #expect(call != nil, "main.swift no longer switches the assertion off")
        if let call, let start {
            #expect(call.lowerBound < start.lowerBound,
                    "the call is after KhaytApp.main(), which never returns")
        }
    }

    /// `#filePath` rather than a bundle resource: the file being checked is
    /// source, not something that ships.
    static func mainSwift() throws -> String {
        let here = URL(fileURLWithPath: #filePath)          // …/Tests/KhaytAppTests/…
        let root = here.deletingLastPathComponent()          // KhaytAppTests
            .deletingLastPathComponent()                     // Tests
            .deletingLastPathComponent()                     // KhaytCore
        let main = root.appending(path: "Sources/KhaytApp/main.swift")
        return try String(contentsOf: main, encoding: .utf8)
    }
}
