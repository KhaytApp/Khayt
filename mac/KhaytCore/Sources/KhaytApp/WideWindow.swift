import SwiftUI

/// What happens above 1100×620 — §10.
///
/// ── CHROME IS FIXED, CONTENT GROWS, TILES MULTIPLY ────────────────────────
///
/// 1100×620 is the floor, not the design. The rule that makes a Mac app feel
/// stretched is chrome that grows with the window, so none of it does: the
/// sidebar, the project sidebar, the inspector and the board column are
/// reading widths chosen for their content. A 400-point inspector is not a
/// better inspector.
///
/// What grows is the middle. In a dense table the extra width goes to the
/// NAME column only — every numeric column keeps its width, so figures stay on
/// their shared decimal and the eye keeps its landing spots. In a grid nothing
/// grows at all: tiles multiply.
enum Wide {

    // MARK: Chrome that never moves

    /// The navy sidebar.
    static let sidebar: CGFloat = 150
    /// The project sidebar in the media grid.
    static let projects: CGFloat = 186
    /// The trailing inspector.
    static let inspector: CGFloat = 282
    /// One column of the board.
    static let boardColumn: CGFloat = 240

    // MARK: Grids

    /// A tile, and the gap between two of them.
    static let tile: CGFloat = 152
    static let tileGap: CGFloat = 13

    /// How many tiles fit, and never how wide a tile should be.
    ///
    /// Five at the 1100 floor, eight on a 13-inch Air full screen, thirteen on
    /// a Studio Display. `floor(available ÷ 165)` — the tile plus its gap —
    /// with at least one, because a window can always be narrower than the
    /// thing inside it and a grid of zero columns is a crash rather than a
    /// layout.
    static func columns(across available: CGFloat) -> Int {
        max(1, Int((available / (tile + tileGap)).rounded(.down)))
    }

    /// The grid itself: fixed columns, leading-aligned, remainder as trailing
    /// space.
    ///
    /// NEVER centred. A grid whose leading edge moves as the window resizes is
    /// worse than a ragged trailing edge — the eye loses the column it was
    /// reading down, which is the one thing a grid is for.
    static func grid(across available: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.fixed(tile), spacing: tileGap, alignment: .topLeading),
              count: columns(across: available))
    }

    // MARK: Sentences

    /// Explanatory copy stops growing at 68 characters.
    ///
    /// A sentence that runs the width of a 2560-point display is a sentence
    /// nobody finishes: the eye loses the line it was on coming back from the
    /// right-hand end. The card keeps the rest as trailing space.
    static let sentence = 68

    /// The width 68 characters occupies at a given size, near enough.
    ///
    /// An em is about half the point size in a text face, and a character
    /// averages a little over half an em. Measured rather than guessed would be
    /// better; this is deliberately approximate because the rule is "stop
    /// growing", not "be exactly this wide".
    static func sentenceWidth(_ size: CGFloat = 11.5) -> CGFloat {
        CGFloat(sentence) * size * 0.52
    }
}

extension View {
    /// Cap explanatory copy at §10's reading length, leading-aligned.
    func sentenceWidth(_ size: CGFloat = 11.5) -> some View {
        frame(maxWidth: Wide.sentenceWidth(size), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
