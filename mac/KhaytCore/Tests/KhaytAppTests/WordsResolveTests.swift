import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Every word this app asks for is a word it has.
///
/// `Words.callIt` ends `return key`. A key that resolves nowhere therefore
/// renders AS ITSELF: a button reading `common.ok`, a heading reading
/// `plib.unfiled`. Nothing throws, nothing is logged, and no existing test
/// notices — the same fault the other app shipped in a `data-` attribute and
/// nobody saw for months.
///
/// Found that way: `Banners.swift` asked for `common.ok`, which is in neither
/// this app's own table nor the shared catalogue, so the button that dismisses
/// "Khayt drafted N purchase orders" read `common.ok`.
///
/// BEHAVIOURAL, not a catalogue diff. It asks the real `Words` — loaded from
/// the real engine, in each language the app supports — whether the key comes
/// back as something other than itself. A test that compared two parsed files
/// would agree with any mistake both files shared.
@MainActor
struct WordsResolveTests {

    /// Every key asked for as a COMPLETE literal.
    ///
    /// Only where the string is the whole first argument and the call closes
    /// straight after it. `callIt("waste.ft." + type)` is deliberately excluded:
    /// the literal there is a PREFIX, and demanding `waste.ft.` resolve would
    /// fail on correct code. Those are covered by the suffix test below.
    static func keysAskedFor() -> [(file: String, line: Int, key: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        // Assert the root before trusting an empty result — a path walk that
        // lands nowhere is how a guard passes by finding nothing to check.
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Words.swift").path),
                "the source directory was not found — this test would pass vacuously")

        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                     includingPropertiesForKeys: nil)) ?? []
        // Plain scanning rather than a regex: the first draft used a regex
        // literal that matched 14 of 1,375 calls, and the count guard below is
        // the only reason that was noticed rather than shipped as a clean pass.
        var out: [(String, Int, String)] = []
        for url in files where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for opener in ["callIt(\"", "upfront(\""] {
                    var from = line.startIndex
                    while let start = line.range(of: opener, range: from ..< line.endIndex) {
                        from = start.upperBound
                        guard let close = line.range(of: "\"", range: from ..< line.endIndex)
                        else { break }
                        let key = String(line[from ..< close.lowerBound])
                        // The whole first argument, closed straight after: a
                        // key built as `"prefix" + value` is a PREFIX and is
                        // covered by `builtKeysResolve`, not here.
                        let rest = line[close.upperBound...].drop { $0 == " " }
                        let complete = rest.first == "," || rest.first == ")"
                        let plain = !key.isEmpty && key.allSatisfy {
                            $0.isLetter || $0.isNumber || $0 == "." || $0 == "_"
                        }
                        if complete && plain { out.append((url.lastPathComponent, n + 1, key)) }
                    }
                }
            }
        }
        return out
    }

    static func words(_ language: String) async throws -> Words {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load(language, engine: engine)
        return words
    }

    @Test("every word the app asks for resolves, in both languages",
          arguments: Words.supported)
    func everyKeyResolves(_ language: String) async throws {
        let words = try await Self.words(language)
        // The catalogue really loaded. Without this the whole test passes by
        // finding nothing, or fails on all 1,300 — neither of which says
        // anything about the app.
        #expect(words.callIt("common.save") != "common.save",
                "the \(language) catalogue did not load — every key would look broken")

        let asked = Self.keysAskedFor()
        #expect(asked.count > 800, "only \(asked.count) keys found — the scan is wrong")

        let unresolved = asked.filter { words.callIt($0.key) == $0.key }
        let said = unresolved.map { "\($0.file):\($0.line) \($0.key)" }.sorted()
        #expect(said.isEmpty,
                Comment(rawValue: "these render as their own key in \(language):\n  "
                        + said.joined(separator: "\n  ")))
    }

    /// The prefix form, checked against the values it is actually given.
    ///
    /// `callIt("maint.status_" + task.status)` cannot be checked by reading the
    /// source, so the domains are listed here. A value outside its list renders
    /// raw exactly as a missing key does — `pe.kind_` already guards itself
    /// with the `fallback:` overload, which is the other way to be safe.
    @Test("the built-up keys resolve for every value they are built from",
          arguments: Words.supported)
    func builtKeysResolve(_ language: String) async throws {
        let words = try await Self.words(language)
        let domains: [String: [String]] = [
            "maint.status_": ["ok", "due", "warning", "overdue"],
            "day.": ["sun", "mon", "tue", "wed", "thu", "fri", "sat"],
            "cl.source_": ["walk_in", "instagram", "website", "referral",
                           "exhibition", "online", "other"],
            "pay.method.": ["cash", "transfer", "mada", "visa", "applepay",
                            "stcpay", "other"],
            "exp.cat.": ["filament", "electricity", "maintenance", "shipping",
                         "tools", "other"],
            "sup.cat.": ["filament", "hardware", "packaging", "services",
                         "tools", "other"],
        ]
        var missing: [String] = []
        for (prefix, values) in domains {
            for value in values where words.callIt(prefix + value) == prefix + value {
                missing.append(prefix + value)
            }
        }
        #expect(missing.isEmpty,
                Comment(rawValue: "built-up keys with no word in \(language): "
                        + missing.sorted().joined(separator: ", ")))
    }
}
