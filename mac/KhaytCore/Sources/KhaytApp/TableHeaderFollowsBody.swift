import AppKit
import SwiftUI

/// Keeps a table's heading over its own columns when the table is wider than
/// its pane.
///
/// ── THE FAULT (Nov 11 2026 UI review, B20) ────────────────────────────────
///
/// In Arabic the Waste table drew "الوزن المهدر (غ)" — wasted weight — over
/// the column of dates: the headings stood two columns along from the cells
/// under them. English was fine, and so was the Arabic Jobs table, which is
/// also wider than its pane. What Waste and Expenses have that Jobs does not
/// is an `HSplitView`: the table is laid out at the full width first and the
/// summary beside it then takes its share.
///
/// READ FROM PICTURES, NOT FROM A DEBUGGER — this is the explanation that
/// fits all four of them (English and Arabic, large window and small), and it
/// has not been watched happening: a right-to-left table rests at its RIGHT
/// end, so when its pane narrows the body's horizontal origin moves to keep
/// that end in view. The heading is a second clip view that AppKit moves when
/// the body SCROLLS, and a pane changing size is not a scroll — so the body
/// moved and the heading stayed. Left to right both rest at zero and a
/// narrower pane moves neither, which is why nobody saw it in English.
///
/// So the heading's clip view is put where the body's is whenever the body's
/// moves or changes size. Nothing here changes a size, so it cannot feed a
/// layout back into itself; where the two already agree it does nothing.
struct TableHeaderFollowsBody: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.lookSoon() }

    /// Where the heading's clip view should start, given the body's — or nil
    /// when it is already there. The whole rule, apart from AppKit.
    static func correction(header: CGFloat, body: CGFloat) -> CGFloat? {
        abs(header - body) > 0.5 ? body : nil
    }

    final class Probe: NSView {
        private weak var watched: NSClipView?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { forget() } else { lookSoon() }
        }

        /// After this turn: the table next to this view may not be in the
        /// window yet when this one arrives.
        func lookSoon() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func forget() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            watched = nil
        }

        /// The table this view was put behind: the one whose scroll view
        /// covers the point this view is at. Not "the first table found" —
        /// the sidebar is a table too, and it comes first.
        private func table() -> NSTableView? {
            let here = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            func find(_ view: NSView, into found: inout [NSTableView]) {
                if let table = view as? NSTableView { found.append(table) }
                for sub in view.subviews { find(sub, into: &found) }
            }
            var up = superview
            while let ancestor = up {
                var tables: [NSTableView] = []
                find(ancestor, into: &tables)
                if let mine = tables.first(where: { table in
                    guard let scroll = table.enclosingScrollView else { return false }
                    return scroll.convert(scroll.bounds, to: nil).contains(here)
                }) { return mine }
                up = ancestor.superview
            }
            return nil
        }

        private func attach() {
            guard window != nil, let table = table(), let clip = table.enclosingScrollView?.contentView else { return }
            if watched !== clip {
                forget()
                watched = clip
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    tokens.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.align() }
                    })
                }
            }
            align()
        }

        private func align() {
            guard let clip = watched, let table = clip.documentView as? NSTableView,
                  let header = table.headerView, let headerClip = header.superview as? NSClipView,
                  let x = TableHeaderFollowsBody.correction(header: headerClip.bounds.origin.x,
                                                            body: clip.bounds.origin.x) else { return }
            headerClip.setBoundsOrigin(NSPoint(x: x, y: headerClip.bounds.origin.y))
            header.needsDisplay = true
        }
    }
}

extension View {
    /// See `TableHeaderFollowsBody`. For a `Table` that shares an
    /// `HSplitView` with something else.
    func headerFollowsBody() -> some View {
        background(TableHeaderFollowsBody().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
