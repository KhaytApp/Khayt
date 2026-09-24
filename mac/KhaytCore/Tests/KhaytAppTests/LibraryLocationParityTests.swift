import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `LibraryLocation` is the one piece of shared logic this app writes twice, so
/// it is the one piece held to the original by running both.
///
/// Not a unit test of what I think the rules are — that would pass just as
/// happily if I had misread `lib/print-library-location.js`. Every case below
/// goes through Node and through Swift, and the values are compared.
struct LibraryLocationParityTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // …/mac/KhaytCore/Tests/KhaytAppTests/x.swift
            .deletingLastPathComponent()  // KhaytAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // KhaytCore
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // repo root
    }

    /// Evaluate an expression against the real module, under Node.
    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        const PLL = require('./lib/print-library-location.js');
        process.stdout.write(JSON.stringify(\(expression)));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.currentDirectoryURL = repoRoot
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.node(String(data: problem, encoding: .utf8) ?? "node failed")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    enum Failure: Error { case node(String) }

    /// Swift's answer, put through JSON so the two are compared as values.
    /// Comparing the encoded *text* would fail on key order alone — the lesson
    /// `MoneyParityTests` already paid for.
    static func swiftValue(_ roots: LibraryLocation.Roots) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(roots))
    }

    /// Each case: the settings object, and the default root.
    static let cases: [(name: String, settings: String, defaultRoot: String)] = [
        ("a drive root as the root, the mirror and in history — never a library folder",
         "{root:'/', mirror:' / ', history:['/', '/Volumes/old']}", "/Users/x/vault"),
        ("nothing configured — the built-in vault",
         "{}", "/Users/x/Library/Application Support/khayt/print-files-vault"),
        ("a NAS, chosen by the shop",
         "{root:'/Volumes/shop/khayt-library'}", "/Users/x/vault"),
        ("a NAS with a mirror on a local disk",
         "{root:'/Volumes/shop/lib', mirror:'/Users/x/backup'}", "/Users/x/vault"),
        ("a mirror that is the same folder as the primary",
         "{root:'/Volumes/shop/lib', mirror:'/Volumes/shop/lib'}", "/Users/x/vault"),
        ("moved twice — the first custom folder must survive",
         "{root:'/Volumes/b', history:['/Volumes/a','/Users/x/vault']}", "/Users/x/vault"),
        ("history carrying blanks and duplicates",
         "{root:'/Volumes/b', history:['', '/Volumes/a', '/Volumes/a', '   ']}", "/Users/x/vault"),
        ("a chosen root that IS the default — not custom",
         "{root:'/Users/x/vault'}", "/Users/x/vault"),
        ("untrimmed whitespace around every path",
         "{root:'  /Volumes/b  ', mirror:' /Users/x/m '}", "/Users/x/vault"),
        ("mirror set but no custom root",
         "{mirror:'/Users/x/m'}", "/Users/x/vault"),
        ("settings that are not an object at all",
         "null", "/Users/x/vault"),
    ]

    @Test("Swift and lib/print-library-location.js resolve the same roots")
    func rootsMatch() throws {
        for c in Self.cases {
            let fromNode = try Self.node("PLL.resolveRoots(\(c.settings), '\(c.defaultRoot)')")

            // The same settings, as the store would hand them over.
            let settingsJSON = try Self.node("(\(c.settings)) || {}")
            let mine = LibraryLocation.resolveRoots(settings: settingsJSON, defaultRoot: c.defaultRoot)
            let fromSwift = try Self.swiftValue(mine)

            #expect(fromSwift == fromNode, """
                \(c.name)
                  settings: \(c.settings)
                  Node:  \(fromNode)
                  Swift: \(fromSwift)
                """)
        }
    }

    /// An id as a JS string literal, in pure `\uXXXX` escapes.
    ///
    /// Passing the characters through instead makes this a test of how the
    /// shell and Foundation normalise text rather than of the rule. "e" with an
    /// acute as ONE code unit, and as "e" plus a combining accent, legitimately
    /// sanitise to different folder names — both implementations agree about
    /// that — so the comparison only means anything once both sides are handed
    /// the same code units. Escaping pins them.
    static func jsLiteral(_ s: String) -> String {
        "'" + s.utf16.map { String(format: "\\u%04X", $0) }.joined() + "'"
    }

    @Test("Swift and Node name a record's folder identically")
    func itemDirNamesMatch() throws {
        let ids = [
            "PF-mtjwvj1w05A", "PF_abc-123", "", "   ", "PF-with spaces", "!!!",
            // An id with a separator in it must not be able to walk out of the
            // library root: only the last segment survives.
            "PF/../../etc", "a/b/c", #"a\b\c"#,
            // A trailing separator pops an EMPTY segment in JS, not the one
            // before it, so this is "unsorted" rather than "b".
            "a/b/",
            // Outside the BMP: one Swift Character, two UTF-16 code units, so
            // two underscores rather than one.
            "PF-\u{1F600}-face", "\u{1F600}",
            // The same letter composed and decomposed — one code unit against
            // two, so "_" against "e_". A difference in the id, which both
            // sides have to carry through the same way.
            "PF-\u{00E9}moji", "PF-e\u{0301}moji", "\u{2713}",
        ]
        for id in ids {
            let fromNode = try Self.node("PLL.itemDirName(\(Self.jsLiteral(id)))")
            let mine = JSONValue.string(LibraryLocation.itemDirName(id))
            #expect(mine == fromNode, "id \(id.debugDescription): Node \(fromNode), Swift \(mine)")
        }
    }
}
