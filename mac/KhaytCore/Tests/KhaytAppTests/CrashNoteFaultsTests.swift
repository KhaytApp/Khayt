import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the crash note says about the rules.
///
/// A JavaScript fault does not crash this app — every engine call is asked
/// with `try?` — but it is very often what led to whatever did, and until now
/// it was written down nowhere. The note carries the shape of each failed call
/// and none of its arguments: a script carries its data inline, and a crash
/// note is a file a shop is asked to send on.
@Suite(.serialized)
@MainActor
struct CrashNoteFaultsTests {

    @Test("the note names the rules that failed, without their data")
    func notesTheFaults() throws {
        EngineFaults.clear()
        let runtime = try JSRuntime(modules: [])
        _ = try? runtime.evaluate(
            "KhaytPretendRule.doSomething({\"client\":\"Najd Architects\",\"pin\":\"2468\"})")

        let written = LastWords.engineFaults()
        #expect(written.contains("KhaytPretendRule.doSomething"), "the note does not name the rule")
        for secret in ["Najd Architects", "2468"] {
            #expect(!written.contains(secret), "the note carries \(secret)")
        }
    }

    @Test("a run with nothing wrong says so rather than leaving a blank")
    func nothingIsSaidPlainly() {
        EngineFaults.clear()
        #expect(LastWords.engineFaults() == "(none)")
    }
}
