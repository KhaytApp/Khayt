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
/// ── AND THE MEASUREMENT HAS TO MIRROR TOO (Nov 11 2026 review, B19) ──────
///
/// The mask mirrored and the arithmetic did not. A scroll view's offset is
/// counted from the LEFT in both directions, and a right-to-left row rests at
/// its right-hand end — so "is the offset past zero" was asking about the far
/// end and fading the near one. In Arabic the first chip of Gift cards and of
/// the Catalogue was faded out where it stood: "ـطة 3" for "نشطة 3", on a row
/// of three chips that did not scroll at all.
///
/// Two rules now, in `ScrollEdges.hidden`, which is plain arithmetic and is
/// tested as such:
///
/// 1. **A row that fits fades nowhere**, whatever its offset says. That is the
///    sentence above ("a row that fits has no fade at all") finally written as
///    a condition instead of being left to fall out of the offsets.
/// 2. What is hidden to the LEFT is "before" in a left-to-right row and
///    "after" in a right-to-left one.
struct HorizontalScrollCue: ViewModifier {
    var fade: CGFloat = 28

    @State private var edges = ScrollEdges.none
    @Environment(\.layoutDirection) private var direction

    func body(content: Content) -> some View {
        let rtl = direction == .rightToLeft
        content
            .onScrollGeometryChange(for: ScrollEdges.self) { g in
                ScrollEdges.hidden(offset: g.contentOffset.x, container: g.containerSize.width,
                                   content: g.contentSize.width,
                                   insetLow: rtl ? g.contentInsets.trailing : g.contentInsets.leading,
                                   insetHigh: rtl ? g.contentInsets.leading : g.contentInsets.trailing,
                                   rightToLeft: rtl)
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

    /// - Parameters:
    ///   - offset: how far the content has moved, counted from the LEFT.
    ///   - insetLow / insetHigh: the content insets at the left and the right.
    ///
    /// A point of slack everywhere, so a row that fits to within rounding is
    /// not given a fade it does not need.
    static func hidden(offset: CGFloat, container: CGFloat, content: CGFloat,
                       insetLow: CGFloat = 0, insetHigh: CGFloat = 0,
                       rightToLeft: Bool) -> ScrollEdges {
        // Nothing to scroll to: no cue, whatever the offset reads.
        guard content + insetLow + insetHigh > container + 1 else { return .none }
        let left = offset > -insetLow + 1
        let right = offset + container < content + insetHigh - 1
        return rightToLeft ? ScrollEdges(before: right, after: left)
                           : ScrollEdges(before: left, after: right)
    }
}

extension View {
    /// Fade whichever end of a horizontal scroll still has something past it.
    func horizontalScrollCue(fade: CGFloat = 28) -> some View {
        modifier(HorizontalScrollCue(fade: fade))
    }
}
