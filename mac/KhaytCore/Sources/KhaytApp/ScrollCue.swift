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
struct HorizontalScrollCue: ViewModifier {
    var fade: CGFloat = 28

    @State private var before = false
    @State private var after = false

    private struct Edges: Equatable {
        let before: Bool
        let after: Bool
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edges.self) { g in
                // A point of slack either side, so a row that fits to within
                // rounding is not given a fade it does not need.
                Edges(before: g.contentOffset.x > -g.contentInsets.leading + 1,
                      after: g.contentOffset.x + g.containerSize.width
                             < g.contentSize.width + g.contentInsets.trailing - 1)
            } action: { _, edges in
                before = edges.before
                after = edges.after
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: before ? fade : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: after ? fade : 0)
                }
            }
    }
}

extension View {
    /// Fade whichever end of a horizontal scroll still has something past it.
    func horizontalScrollCue(fade: CGFloat = 28) -> some View {
        modifier(HorizontalScrollCue(fade: fade))
    }
}
