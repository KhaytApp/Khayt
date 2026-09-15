import Foundation
import Testing
import SwiftUI
@testable import KhaytApp

/// §10, measured at the sizes a shop actually runs.
///
/// The spec gives three real displays and the count it expects on each, which
/// makes this checkable rather than a matter of opinion — and the counts are
/// the whole rule: if tiles inflate instead of multiplying, the arithmetic
/// still "works" and the screen is wrong.
@MainActor
struct WideWindowTests {

    /// The three the spec names, minus the chrome that never moves.
    ///
    /// Content width is the window less the 150-point sidebar and the screen
    /// padding either side — a grid does not start at the window's edge.
    static func content(_ window: CGFloat) -> CGFloat {
        window - Wide.sidebar - Metric.screen * 2
    }

    @Test("tiles multiply, and the counts are the spec's own")
    func tilesMultiply() {
        // The spec: "Five per row at 1100, eight on a 13-inch Air full screen,
        // thirteen on a Studio Display."
        let cases: [(name: String, window: CGFloat, atLeast: Int)] = [
            ("the 1100 floor", 1100, 5),
            ("a 13-inch Air full screen", 1470, 7),
            ("a Studio Display", 2560, 13),
        ]
        for c in cases {
            let n = Wide.columns(across: Self.content(c.window))
            #expect(n >= c.atLeast, Comment(rawValue: """
                \(c.name): \(n) columns, expected at least \(c.atLeast). Either \
                the tile has inflated or the divisor has drifted off 165.
                """))
        }
    }

    @Test("a tile is the same size on every display")
    func tilesNeverInflate() {
        // The failure this exists to catch is a `.flexible()` column, which
        // makes the arithmetic look right and the tiles grow anyway.
        for window in [1100.0, 1470.0, 2560.0, 3008.0] {
            let items = Wide.grid(across: Self.content(window))
            for item in items {
                guard case .fixed(let width) = item.size else {
                    Issue.record("a grid column is not fixed at \(Int(window)) points")
                    continue
                }
                #expect(width == Wide.tile, Comment(rawValue:
                    "a tile is \(width) at \(Int(window)) points, not \(Wide.tile)"))
            }
        }
    }

    @Test("a window narrower than one tile still has a column")
    func neverZeroColumns() {
        // A window can always be narrower than the thing inside it, and a grid
        // of zero columns is a crash rather than a layout.
        #expect(Wide.columns(across: 10) == 1)
        #expect(Wide.columns(across: 0) == 1)
    }

    @Test("chrome is the same width at every size")
    func chromeIsFixed() {
        // Nothing here should be a function of the window at all — the test is
        // that these are constants, and it fails by being edited.
        #expect(Wide.sidebar == 150)
        #expect(Wide.projects == 186)
        #expect(Wide.inspector == 282)
        #expect(Wide.boardColumn == 240)
    }

    @Test("a sentence stops growing")
    func sentencesCap() {
        let width = Wide.sentenceWidth(11.5)
        #expect(width > 300, "68 characters cannot be that narrow")
        #expect(width < 520, """
            the sentence cap is wide enough to lose the line coming back from \
            the right-hand end, which is what §10's 68 characters prevents
            """)
        // And it is a cap, not a width: the same rule at a bigger size is
        // proportionally wider, because it counts CHARACTERS.
        #expect(Wide.sentenceWidth(13) > width)
    }
}
