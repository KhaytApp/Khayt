import SwiftUI

/// A horizontal scroll that SAYS it scrolls.
///
/// The board's sixth column and the library's chip row both ran straight into
/// the window edge. A macOS scroll view hides its scroller until it is touched,
/// so a row cut off mid-chip looked like a row that ended there — the lanes
/// after Post-Processing, the tags after the eighth creator, were not missing,
/// they were unannounced.
///
/// So the edge where more is waiting FADES, and only that edge: nothing at the
/// start of the row, a fade at the far end, and once scrolled, a fade at the
/// near end too. A row that fits has no fade at all, which is the difference
/// between a cue and decoration.
///
/// ── WHY THIS CANNOT LOOP ──────────────────────────────────────────────────
///
/// The only thing the measurement changes is a MASK. The mask does not take
/// part in layout, so the scroll view's size, its content's size and the offset
/// that were measured are the same after the change as before it. Nothing here
/// feeds a size back into the view that produced it — see `SwiftUI layout
/// loops` in the Mac notes for what happens when something does.
///
/// Leading and trailing, never left and right: the mask is an `HStack`, which
/// mirrors in Arabic the way the scroll view it sits on does.
///
/// ── A ROW THAT FITS FADES NOWHERE, AND THAT IS NOW A CONDITION ──────────
///
/// In Arabic the first chip of Gift cards and of the Catalogue was faded out
/// where it stood — "ـطة 3" for "نشطة 3" — on a row of three chips that did
/// not scroll at all (Nov 11 2026 review, B19). "A row that fits has no fade"
/// was a sentence in this comment and nowhere in the code: it was left to
/// fall out of the offsets, and on a right-to-left row that fits they did not
/// say what the arithmetic assumed.
///
/// So `ScrollEdges.hidden` asks first whether there is anything to scroll to,
/// and only then reads the offset. The offset itself needs no mirroring:
/// measured on a real scroll view (`ScrollEdgesTests.aRealRowAtRest`), SwiftUI
/// counts it from the LEADING edge in both directions — a right-to-left row
/// of forty chips rests at zero, as a left-to-right one does. What the offset
/// reads on the fitting Arabic row in the app was not measured; with the
/// first rule it no longer matters.
struct HorizontalScrollCue: ViewModifier {
    var fade: CGFloat = 28

    @State private var edges = ScrollEdges.none

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollEdges.self) { g in
                ScrollEdges.hidden(offset: g.contentOffset.x, container: g.containerSize.width,
                                   content: g.contentSize.width,
                                   insetLeading: g.contentInsets.leading,
                                   insetTrailing: g.contentInsets.trailing)
            } action: { _, now in
                edges = now
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: edges.before ? fade : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: edges.after ? fade : 0)
                }
            }
    }
}

/// Which ends of a horizontal scroll have something past them: `before` the
/// leading edge, `after` the trailing one.
struct ScrollEdges: Equatable {
    var before: Bool
    var after: Bool

    static let none = ScrollEdges(before: false, after: false)

    /// - Parameter offset: how far the content has moved, counted from the
    ///   LEADING edge (which is how SwiftUI reports it in both directions).
    ///
    /// A point of slack everywhere, so a row that fits to within rounding is
    /// not given a fade it does not need.
    static func hidden(offset: CGFloat, container: CGFloat, content: CGFloat,
                       insetLeading: CGFloat = 0, insetTrailing: CGFloat = 0) -> ScrollEdges {
        // Nothing to scroll to: no cue, whatever the offset reads.
        guard content + insetLeading + insetTrailing > container + 1 else { return .none }
        return ScrollEdges(before: offset > -insetLeading + 1,
                           after: offset + container < content + insetTrailing - 1)
    }
}

extension View {
    /// Fade whichever end of a horizontal scroll still has something past it.
    func horizontalScrollCue(fade: CGFloat = 28) -> some View {
        modifier(HorizontalScrollCue(fade: fade))
    }
}
