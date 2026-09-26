import Foundation
import Testing

/// `make-app.sh` writes `Info.plist` from an UNQUOTED heredoc.
///
/// It has to be unquoted: it substitutes `$VERSION`, `$BUILD_VERSION` and
/// `$SPARKLE_KEYS`. The cost is that everything else in there expands too, and
/// a comment is just text to the shell.
///
/// THIS ALREADY HAPPENED. A comment explaining the Bonjour list named two files
/// in backticks:
///
///     The five are `lib/printer-discovery.js`'s SERVICES, and adding a
///     protocol there means adding it here — `PrinterFinderTests` says so.
///
/// The shell ran both as commands — "Permission denied" and "command not
/// found" in the build log — and substituted their empty output, so the shipped
/// plist read "The five are 's SERVICES". Harmless in a comment. Not harmless
/// as a rule: anything backticked in that heredoc EXECUTES during a release
/// build, and any `$NAME` silently becomes empty if it is not a real variable.
///
/// So this reads the script and refuses an unescaped backtick, and an unknown
/// `$NAME`, inside that one heredoc.
struct MakeAppHeredocTests {

    /// The variables the heredoc is allowed to substitute — the whole reason it
    /// is unquoted. Anything else is a typo that would expand to nothing.
    static let expected: Set<String> = ["VERSION", "BUILD_VERSION", "SPARKLE_KEYS", "GOOGLE_KEYS"]

    static func heredoc() throws -> String {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "make-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        guard let start = text.range(of: "<<PLIST\n") else {
            Issue.record("the Info.plist heredoc is gone — has make-app.sh changed shape?")
            return ""
        }
        guard let end = text.range(of: "\nPLIST\n", range: start.upperBound..<text.endIndex) else {
            Issue.record("the Info.plist heredoc never closes")
            return ""
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    @Test("no unescaped backtick can run during a release build")
    func noLiveBackticks() throws {
        let body = try Self.heredoc()
        guard !body.isEmpty else { return }
        // Remove the escaped ones; anything left is live.
        let stripped = body.replacingOccurrences(of: "\\`", with: "")
        #expect(!stripped.contains("`"), """
            An unescaped backtick in the Info.plist heredoc. It is unquoted, so \
            the shell RUNS what is between backticks during a release build and \
            substitutes the output. Escape them as \\` — see the note in the \
            heredoc itself.
            """)
    }

    @Test("every $NAME in the heredoc is a variable that exists")
    func noStrayVariables() throws {
        let body = try Self.heredoc()
        guard !body.isEmpty else { return }
        var found: Set<String> = []
        let pattern = try NSRegularExpression(pattern: #"(?<!\\)\$\{?([A-Za-z_][A-Za-z_0-9]*)\}?"#)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        for m in pattern.matches(in: body, range: range) {
            if let r = Range(m.range(at: 1), in: body) { found.insert(String(body[r])) }
        }
        let stray = found.subtracting(Self.expected)
        #expect(stray.isEmpty, """
            \(stray.sorted().joined(separator: ", ")) — a $NAME the heredoc \
            substitutes that is not one of \(Self.expected.sorted()). An \
            undefined one expands to NOTHING and the plist ships with a hole \
            in it. Escape it as \\$NAME, or add it above if it is real.
            """)
    }
}
