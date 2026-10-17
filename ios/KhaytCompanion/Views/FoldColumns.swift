import SwiftUI

/// Where iPhone Duo's fold crosses a two-column layout, in that layout's own
/// coordinates: the width before the fold, the fold itself (its reserved
/// region's frame, which includes the margins Apple wants kept clear of
/// interactive content), and the width after it.
///
/// Apple's "Strike a pose with adaptive layouts on iPhone Duo": partly folded
/// like a book, the inner display divides into regions at the fold; for a grid,
/// "preserve the outer margins while increasing the spacing around the hinge,
/// keeping each container within its region", and prefer an even number of
/// columns. Flat, the division region is inactive and zero wide, so the columns
/// split evenly as before. Propped on a table the fold runs across the screen;
/// scrolling content "doesn't displace", so only a fold running down the screen
/// moves anything.
struct FoldGap: Equatable, Sendable {
    var lead: CGFloat
    var gap: CGFloat
    var trail: CGFloat

    /// The first fold running down `size` that leaves room on both sides, from
    /// active division-region frames. Frames are already mirrored for
    /// right-to-left (SwiftUI's default), as a `Layout` or grid places them.
    static func find(_ frames: [CGRect], in size: CGSize) -> FoldGap? {
        for f in frames where f.height > f.width && f.minX > 0 && f.maxX < size.width {
            return FoldGap(lead: f.minX, gap: f.width, trail: size.width - f.maxX)
        }
        return nil
    }

    static func reading(_ proxy: GeometryProxy) -> FoldGap? {
        guard #available(iOS 27.1, *) else { return nil }
        let frames = proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
        return find(frames, in: proxy.size)
    }

    /// Never narrower than the layout's own spacing: a fold thinner than the
    /// usual gap takes the usual gap, centred on it.
    func widened(to spacing: CGFloat) -> FoldGap {
        guard gap < spacing else { return self }
        let half = (spacing - gap) / 2
        return FoldGap(lead: lead - half, gap: spacing, trail: trail - half)
    }

    /// Grid columns: two, split at the fold when there is one, evenly when
    /// not; one in compact width.
    static func columns(_ fold: FoldGap?, regularWidth: Bool, spacing: CGFloat) -> [GridItem] {
        guard regularWidth else { return [GridItem(.flexible(), spacing: spacing, alignment: .top)] }
        guard let f = fold?.widened(to: spacing), f.lead > 0, f.trail > 0 else {
            return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: 2)
        }
        return [GridItem(.fixed(f.lead), spacing: f.gap, alignment: .top),
                GridItem(.fixed(f.trail), alignment: .top)]
    }
}

extension View {
    /// Keeps `fold` set to the fold crossing this view, or nil.
    func readsFold(_ fold: Binding<FoldGap?>) -> some View {
        onGeometryChange(for: FoldGap?.self, of: { FoldGap.reading($0) }) { fold.wrappedValue = $0 }
    }
}

/// Two views side by side — Home's figures and its work — halved evenly, or at
/// the fold when the device is partly folded.
struct FoldColumns: Layout {
    var fold: FoldGap?
    var spacing: CGFloat = 0

    private func widths(_ width: CGFloat) -> (lead: CGFloat, gap: CGFloat, trail: CGFloat) {
        if let f = fold?.widened(to: spacing), f.lead > 0, f.trail > 0,
           abs(f.lead + f.gap + f.trail - width) < 1 {
            return (f.lead, f.gap, f.trail)
        }
        let half = max(0, (width - spacing) / 2)
        return (half, spacing, half)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let w = widths(width)
        let heights = zip(subviews, [w.lead, w.trail]).map { view, cw in
            view.sizeThatFits(ProposedViewSize(width: cw, height: nil)).height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width)
        for (i, view) in subviews.prefix(2).enumerated() {
            let x = i == 0 ? bounds.minX : bounds.minX + w.lead + w.gap
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: i == 0 ? w.lead : w.trail, height: nil))
        }
    }
}
