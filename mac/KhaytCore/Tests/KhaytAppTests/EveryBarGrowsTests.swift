import Foundation
import Testing
@testable import KhaytApp

/// Every bar in this app arrives at its reading.
///
/// ── WHY A SWEEP NEEDED A RATCHET ──────────────────────────────────────────
///
/// `Motion.gauge` has been defined as "a bar or a gauge growing to its reading"
/// since the day `Motion.swift` was written, and when it was counted, two views
/// used it. Reading the sources found a handful of charts; scanning them found
/// SIXTEEN separate shapes across fifteen files whose width or height is
/// computed from the shop's own figures and which were every one of them drawn
/// at their final size. Nobody had decided that. It is what happens when each
/// card is written on its own and the rule lives in a comment.
///
/// So the sweep is only half the work. This is the other half: it finds the
/// bars the way the sweep found them and holds the answer, so the next card
/// somebody writes either grows its bar or says here why it does not.
///
/// ── WHAT COUNTS AS A BAR ──────────────────────────────────────────────────
///
/// A `.frame(width:)` or `.frame(height:)` on a SHAPE, whose size is an
/// expression containing a multiplication or a division against something that
/// is not a literal. That is exactly what a bar is: a rectangle as long as its
/// number. A fixed `.frame(width: 60, height: 2)` is furniture and is not
/// matched; `size * 0.44` inside a drawing is matched and is allow-listed
/// below, because the thing being scaled is a picture rather than a reading.
@MainActor
struct EveryBarGrowsTests {

    /// Files whose data-sized shapes are deliberately NOT gauges, with the
    /// reason — because "it has no growth" and "it should not have growth" are
    /// different states and only one of them is a bug.
    static let notGauges: [String: String] = [
        // A nozzle, a spool and a ring are PICTURES scaled to fit their box.
        // What is multiplied is the drawing's own geometry, not a reading, and
        // a spool that inflated on every screen would be the looping
        // decoration `Motion.swift` refuses.
        "Craft.swift": "the drawn nozzle scales to its box, not to a figure",
        "Drawings.swift": "ring geometry, and the dial already uses Motion.gauge",
        "ShopFloor.swift": "a drawn spool and its filament level, not a chart",
        // ── THE INTERESTING ONE ───────────────────────────────────────────
        //
        // The paid-so-far meter in the jobs table IS a gauge, and it animates
        // when a payment lands — `Motion.gauge`, on the value. What it must
        // not do is grow on first draw: this table shows forty-two rows at
        // once, and forty-two meters unrolling every time the screen opens is
        // precisely the dashboard-always-moving that the argument at the top
        // of `Motion.swift` is against. A gauge in a LIST answers changes; a
        // gauge on a CARD can also introduce itself.
        "OrdersTable.swift": "a meter per row: it answers a payment, it does not unroll 42 times",
    ]

    /// Where a shape's size comes from a figure. Found by the same walk the
    /// sweep used, so the test and the sweep cannot disagree about what a bar
    /// is.
    struct Bar {
        let file: String
        let line: Int
        let expression: String
    }

    static func sources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KhaytAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // KhaytCore
            .appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(at: root,
                                                                includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// The closing bracket that matches the one at `open`.
    static func balanced(_ text: [Character], from open: Int) -> Int? {
        var depth = 0
        for i in open..<text.count {
            if text[i] == "(" { depth += 1 }
            else if text[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        return nil
    }

    static func bars(in url: URL) throws -> [Bar] {
        let source = try String(contentsOf: url, encoding: .utf8)
        let characters = Array(source)
        var found: [Bar] = []
        var search = source.startIndex

        while let hit = source.range(of: #"\.frame\((width|height|maxWidth|maxHeight):"#,
                                     options: .regularExpression,
                                     range: search..<source.endIndex) {
            search = hit.upperBound
            let open = source.distance(from: source.startIndex,
                                       to: source.range(of: "(", range: hit)!.lowerBound)
            guard let close = balanced(characters, from: open) else { continue }
            let inside = String(characters[(open + 1)..<close])

            // A size worked out from something, rather than a fixed one.
            guard inside.range(of: #"[A-Za-z_)\]]\s*[*/]|[*/]\s*[A-Za-z_(]"#,
                               options: .regularExpression) != nil else { continue }

            // On a shape. A `.frame` on a Text or a VStack is layout.
            let from = max(0, open - 300)
            let before = String(characters[from..<open])
            guard before.range(of: #"Capsule|RoundedRectangle|Rectangle\(\)|Circle\(\)|LayerLinesShape|\.fill\(|Shape"#,
                               options: .regularExpression) != nil else { continue }

            let line = source[source.startIndex..<hit.lowerBound]
                .reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            found.append(Bar(file: url.lastPathComponent, line: line,
                             expression: inside.split(separator: "\n")
                                 .map { $0.trimmingCharacters(in: .whitespaces) }
                                 .joined(separator: " ")))
        }
        return found
    }

    /// THE RATCHET. Every file that draws a bar grows at least as many as it
    /// draws, or says in `notGauges` why it does not.
    @Test("every bar in the app grows to its reading")
    func everyBarGrows() throws {
        var complaints: [String] = []
        for url in try Self.sources() {
            let found = try Self.bars(in: url)
            guard !found.isEmpty else { continue }
            let name = url.lastPathComponent
            if Self.notGauges[name] != nil { continue }

            let source = try String(contentsOf: url, encoding: .utf8)
            let grows = source.components(separatedBy: "growsToItsReading").count - 1
            // The extension's own definition does not count as a use.
            let uses = name == "Motion.swift" ? 0 : grows
            if uses < found.count {
                complaints.append("""
                    \(name): \(found.count) bar(s), \(uses) grow(s)
                    \(found.map { "      line \($0.line): \($0.expression)" }.joined(separator: "\n"))
                    """)
            }
        }
        #expect(complaints.isEmpty, """
            A shape sized from one of the shop's figures is a gauge, and \
            `Motion.gauge` is what a gauge arriving at its reading uses. Add \
            `.growsToItsReading(_:from:)`, or add the file to `notGauges` with \
            the reason it is not one.

            \(complaints.joined(separator: "\n"))
            """)
    }

    /// And the count itself, so a bar APPEARING is visible in a diff rather
    /// than only a bar losing its growth.
    ///
    /// Not a total across the app — per file, because a total lets one file
    /// gain a bar while another loses one and says nothing. Updating this
    /// table is the moment somebody decides whether the new shape is a gauge.
    @Test("the bars in this app are the ones listed here")
    func theCountIsPinned() throws {
        let expected: [String: Int] = [
            "BreakEven.swift": 1, "Capacity.swift": 2, "CashFlow.swift": 1,
            "ClientSources.swift": 1, "ClientValue.swift": 1, "Craft.swift": 3,
            "CustomerMix.swift": 1, "CycleTime.swift": 1, "Downtime.swift": 1,
            "Drawings.swift": 3, "ExpenseCategories.swift": 1,
            "MachineReliability.swift": 1, "MaintenanceCost.swift": 1,
            "OrdersTable.swift": 1, "ProductProfit.swift": 1,
            "QuoteFunnel.swift": 1, "RatingTrend.swift": 1, "ShopFloor.swift": 7,
            "Trends.swift": 1, "WasteTrend.swift": 1,
        ]
        var actual: [String: Int] = [:]
        for url in try Self.sources() {
            let found = try Self.bars(in: url)
            if !found.isEmpty { actual[url.lastPathComponent] = found.count }
        }
        let gained = actual.filter { expected[$0.key] != $0.value }
        let lost = expected.filter { actual[$0.key] != $0.value }
        #expect(gained.isEmpty && lost.isEmpty, """
            The set of data-sized shapes has moved. Decide whether each new one \
            is a gauge — it almost certainly is — and update this table.
            now:      \(actual.sorted { $0.key < $1.key })
            expected: \(expected.sorted { $0.key < $1.key })
            """)
    }

    /// The allow-list cannot outlive the files it excuses. A stale entry is a
    /// file that quietly stopped being checked.
    @Test("nothing is excused that no longer draws a bar")
    func theAllowListIsNotStale() throws {
        var drawing: Set<String> = []
        for url in try Self.sources() where try !Self.bars(in: url).isEmpty {
            drawing.insert(url.lastPathComponent)
        }
        for (name, reason) in Self.notGauges {
            #expect(drawing.contains(name),
                    Comment(rawValue: "\(name) is excused — \(reason) — but draws no bar any more"))
        }
    }
}
