import Foundation
import Testing
@testable import KhaytApp

/// A key written twice in the vocabulary table kills the app on launch.
///
/// ── WHY THIS IS WORTH A TEST OF ITS OWN ───────────────────────────────────
///
/// `Words.base` is a dictionary LITERAL, and Swift traps on a repeated key
/// rather than letting the later one win. The trap fires inside the type's
/// one-time initialiser, which runs the first time anything reads a word —
/// which is while SwiftUI is building the menu bar, before a window exists
/// and before a single line reaches stderr.
///
/// So the whole failure a person sees is: the app does not open. No message,
/// no crash dialogue, an empty log, and a `.ips` report whose top frame is
/// `specialized Dictionary.init(dictionaryLiteral:)`. It cost a build, a
/// snapshot run and a decode of that report to find one duplicated line —
/// and it was introduced by adding a string that was already there twenty
/// lines further down.
///
/// The table cannot be read to check this (reading it is what traps), so the
/// SOURCE is what gets checked.
struct DuplicateWordKeyTests {

    /// Every `"some.key":` at the head of a line in the table.
    private func keys(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { return nil }
            guard let close = trimmed.dropFirst().firstIndex(of: "\"") else { return nil }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            // Only the table's own keys, not a language code inside a value.
            guard trimmed[close...].dropFirst().hasPrefix(":") else { return nil }
            return key.contains(".") ? key : nil
        }
    }

    @Test("no key is written twice in Words.swift")
    func noDuplicateKeys() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // KhaytAppTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // KhaytCore
            .appending(path: "Sources/KhaytApp/Words.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let all = keys(in: source)
        #expect(all.count > 300, "read \(all.count) keys — the scan stopped matching the table")

        var seen = Set<String>(), twice = Set<String>()
        for key in all where !seen.insert(key).inserted { twice.insert(key) }
        #expect(twice.isEmpty, "these keys are written twice and will trap on launch: \(twice.sorted())")
    }
}
