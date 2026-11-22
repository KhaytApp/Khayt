import Foundation
import Testing
@testable import KhaytApp

/// A count of one must read as one, not as "1 1".
///
/// ── THE BUG, AND WHY NOTHING CAUGHT IT ────────────────────────────────────
///
/// `Words.counting(n, key)` takes the `_one` form for a count of one, and then
/// — unless the value places the numeral itself with `{n}` — puts the numeral
/// in front of it. Eight English values wrote the number INTO the string as
/// well, so a shop with exactly one of something read:
///
///     1 1 job unrecorded      1 One job is late
///     1 1 carries no cost     1 One thing needs you
///     1 1 open                1 One day over
///     1 1 closed
///     1 1 quoted price
///
/// On the Dashboard and the attention strip, shipped, and wrong only in the
/// case a small shop is in most of the time. The Arabic values were right the
/// whole way: whoever wrote them handled `واحد` — the branch that returns a
/// value already carrying its own number — and left English behind. Nothing
/// compared the two.
///
/// It was found by photographing a card, not by reading the catalogue: the
/// picture said "1 1 purchase" and the source said nothing at all.
@MainActor
struct CountedOneTests {

    /// Every key with an `_one` form, taken from the catalogue rather than
    /// listed here, so a key added tomorrow is covered by a test written today.
    static func countedKeys() throws -> [String] {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Words.swift"), encoding: .utf8)
        var keys: [String] = []
        for match in source.ranges(of: /"([a-z][a-zA-Z_.]*)_one":/) {
            let text = String(source[match])
            keys.append(String(text.dropFirst().prefix(while: { $0 != "\"" })
                .dropLast(4)))
        }
        return keys.sorted()
    }

    @Test("a count of one never draws the number twice")
    func oneIsNotDoubled() throws {
        let words = Words()
        var doubled: [String] = []
        for key in try Self.countedKeys() {
            let said = words.counting(1, key)
            // Two numerals, or a numeral followed by the number spelled out.
            // Both are the same fault: the value carried its own count AND was
            // given another.
            if said.hasPrefix("1 1 ") || said.hasPrefix("1 One ") {
                doubled.append("\(key) → \(said)")
            }
        }
        #expect(doubled.isEmpty, Comment(rawValue: """
            \(doubled.count) counted string(s) draw the number twice for a count \
            of one. The value must place its own numeral with {n}, or carry none \
            at all and let `counting` put it in front:

            \(doubled.joined(separator: "\n"))
            """))
    }

    @Test("the fixed eight read as they should now")
    func theEight() {
        let words = Words()
        #expect(words.counting(1, "mac.n_jobs_unrecorded") == "1 job unrecorded")
        #expect(words.counting(1, "mac.n_without_cost") == "1 carries no cost")
        #expect(words.counting(1, "mac.n_open") == "1 open")
        #expect(words.counting(1, "mac.n_closed") == "1 closed")
        #expect(words.counting(1, "mac.quotes_word") == "1 quoted price")
        #expect(words.counting(1, "mac.n_things_need_you") == "1 thing needs you")
        #expect(words.counting(1, "mac.attn_order") == "1 job is late")
        #expect(words.counting(1, "mac.days_over") == "1 day over")
    }

    @Test("and the plural forms still read as they did")
    func pluralsAreUntouched() {
        // The `_one` form is the only thing that moved. A fix that quietly
        // changed what two of something says would be a worse bug than the one
        // it replaced.
        let words = Words()
        #expect(words.counting(3, "mac.n_jobs_unrecorded") == "3 jobs unrecorded")
        #expect(words.counting(3, "mac.n_open") == "3 open")
        #expect(words.counting(3, "mac.attn_order") == "3 jobs are late")
        #expect(words.counting(2, "mac.quotes_word") == "2 quoted prices")
    }

    @Test("a value that carries no numeral still gets one in front")
    func theOtherShapeStillWorks() {
        // Both shapes are legitimate and the catalogue has both; this is the
        // one the fix must not have broken.
        let words = Words()
        #expect(words.counting(1, "mac.to_order") == "1 thing to order")
        #expect(words.counting(4, "mac.to_order") == "4 things to order")
    }
}
