import SwiftUI

/// A list and the page it opens, side by side: Orders and Customers in regular
/// width (iPhone Duo unfolded, an iPad).
///
/// Not `NavigationSplitView`: in portrait iPadOS draws its list as an overlay
/// over a dimmed page (measured on the iPad mini, `.balanced` and
/// `columnVisibility: .all` included), and the unfolded Duo is narrower still.
/// Apple's Duo guidance is a list beside its detail, always, and on a
/// partly-folded Duo the divide sits at the fold, each side in its own region.
struct ListBesidePage<ListPane: View, PagePane: View>: View {
    private let list: ListPane
    private let page: PagePane
    @State private var fold: FoldGap?
    @State private var width: CGFloat = 0

    init(@ViewBuilder list: () -> ListPane, @ViewBuilder page: () -> PagePane) {
        self.list = list()
        self.page = page()
    }

    /// The narrowest a side may be and still hold a row of the list.
    nonisolated static var minSide: CGFloat { 280 }

    /// The list's width and the divide after it. At a fold that leaves room on
    /// both sides, the fold; otherwise about two fifths, 300–400 points.
    nonisolated static func split(total: CGFloat, fold: FoldGap?) -> (list: CGFloat, divide: CGFloat) {
        if let f = fold, f.lead >= minSide, f.trail >= minSide { return (f.lead, f.gap) }
        return (min(max(total * 0.42, 300), 400), 1)
    }

    var body: some View {
        let s = Self.split(total: width, fold: fold)
        HStack(spacing: 0) {
            list.frame(width: s.list)
            // The fold is kept clear of anything to tap; flat, a hairline.
            Rectangle()
                .fill(fold == nil ? KhaytDesign.hairline : KhaytDesign.ground)
                .frame(width: s.divide)
                .ignoresSafeArea()
            page.frame(maxWidth: .infinity)
        }
        .readsFold($fold)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}
