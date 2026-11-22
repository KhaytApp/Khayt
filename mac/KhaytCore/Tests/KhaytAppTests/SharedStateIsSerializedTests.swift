import Foundation
import Testing
@testable import KhaytApp

/// A test that reaches into shared state must not run beside one that does.
///
/// ── THE FAILURE THIS EXISTS FOR ───────────────────────────────────────────
///
/// `LanStallTests` lowered `LanServer.readTimeout` — a static — ran, and put it
/// back in a `defer`. Three tests in the suite did that, and **Swift Testing
/// runs a suite's tests in parallel.** One test's restore landed while another
/// was still waiting on a connection, so that connection got the full fifteen
/// seconds, outlived its eight-second probe, and reported "held open".
///
/// Nothing was wrong in the server. It passed locally every time and failed on
/// a slower CI runner, which is what a race looks like from the outside: an
/// accusation against the code under test, made by the test.
///
/// The seam itself was the mistake and is gone — the read timeout belongs to a
/// server now, so each bench carries its own. But the SHAPE will come back the
/// next time something needs a seam, so this is the grep, committed.
///
/// The rule: **a test file that assigns a shared static on a production type
/// declares `@Suite(.serialized)`.** Every file that does it today already
/// does, which is why this holds at zero rather than starting with a list of
/// exceptions.
@MainActor
struct SharedStateIsSerializedTests {

    /// Assignments that are not shared process state, with the reason.
    ///
    /// `NSGraphicsContext.current` is per-thread by design — AppKit's own
    /// drawing context — so two tests setting it are not writing to one place.
    static let allowed: Set<String> = ["NSGraphicsContext.current"]

    @Test("every test that writes a shared static runs serially")
    func writersAreSerialized() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: tests,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, Comment(rawValue: "found only \(files.count) test files — the scan has rotted"))

        var offenders: [String] = []
        for url in files {
            let name = url.lastPathComponent
            guard name != "SharedStateIsSerializedTests.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            var writes: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // `Type.property = …` at the start of a statement. Not a
                // declaration, not `self.x`, not a comparison.
                guard let first = trimmed.first, first.isUppercase,
                      let equals = trimmed.range(of: " = "),
                      let dot = trimmed.firstIndex(of: "."), dot < equals.lowerBound
                else { continue }
                let target = String(trimmed[trimmed.startIndex..<equals.lowerBound])
                guard !target.contains("("), !target.contains("["), !target.contains(" "),
                      target.filter({ $0 == "." }).count == 1,
                      !Self.allowed.contains(target)
                else { continue }
                writes.append(target)
            }
            guard !writes.isEmpty else { continue }
            guard !text.contains("@Suite(.serialized)") else { continue }
            offenders.append("\(name) sets \(Set(writes).sorted().joined(separator: ", "))"
                             + " but is not @Suite(.serialized)")
        }
        #expect(offenders.isEmpty, Comment(rawValue:
            "a test writes shared state while its neighbours run beside it. The "
            + "failure will land on whichever test was unlucky, not on this one:\n  "
            + offenders.sorted().joined(separator: "\n  ")))
    }
}
