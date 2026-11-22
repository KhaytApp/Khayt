import SwiftUI

/// Spacing, radius and elevation — §3 of the design spec.
///
/// ── FIVE GAPS, AND NOTHING BETWEEN ────────────────────────────────────────
///
/// 4 · 6 · 9 · 13 · 22. The value of a scale is entirely in what it REFUSES:
/// a screen built from 4/6/9/13/22 has a rhythm, and the same screen built
/// from 4/6/8/9/10/12/13/16/22 has none, while looking almost identical in any
/// one place. Nudging a gap by two points to fix one alignment is how the
/// second happens, so the in-between values do not exist to be typed.
enum Space {
    /// Inside a chip; between a glyph and its word.
    static let xs: CGFloat = 4
    /// Between tightly related rows; a card's inner stack.
    static let sm: CGFloat = 6
    /// Between a heading and what it heads.
    static let md: CGFloat = 9
    /// A card's padding; between cards in a row.
    static let lg: CGFloat = 13
    /// Between the major regions of a screen.
    static let xl: CGFloat = 22
}

/// Three radii, matched to what the thing IS.
enum Radius {
    /// Chips and small marks.
    static let chip: CGFloat = 4
    /// Controls and buttons.
    static let control: CGFloat = 6
    /// Cards, panels and sheets.
    static let card: CGFloat = 10
}

/// Exactly three elevations — §3.
///
/// Flat is the default and covers almost everything: the design separates
/// things with a ground and a hairline, not with depth. The other two exist
/// for the two cases where something genuinely floats.
enum Elevation {
    /// A segmented control's selected pill. Barely there on purpose — it says
    /// "this one" without lifting off the control.
    static func pill<V: View>(_ view: V) -> some View {
        view.shadow(color: .black.opacity(0.07), radius: 1, x: 0, y: 1)
    }

    /// Sheets, popovers, and a card being dragged. The only real shadow in the
    /// app, and it is large and soft rather than tight — a tight shadow at
    /// this size reads as a border that went wrong.
    static func floating<V: View>(_ view: V) -> some View {
        view.shadow(color: .black.opacity(0.30), radius: 26, x: 0, y: 11)
    }
}

extension View {
    /// A card: `surf`, a hairline, radius 10, and the spec's padding.
    ///
    /// `state` draws the 3px leading rule that says a card is ABOUT something
    /// — late, attention, a machine that needs looking at. Nil means the card
    /// is about nothing in particular, which is most of them.
    func card(state: Color? = nil, padding: CGFloat = Space.lg) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Role.surf)
            .overlay(alignment: .top) {
                // Top rather than leading, matching the reference: a rule
                // along the top of a card in a row of cards lines the row up;
                // one down the side of each makes a picket fence.
                if let state {
                    Rectangle().fill(state).frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Role.line, lineWidth: 1)
            }
    }
}
