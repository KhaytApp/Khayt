import SwiftUI

/// A sheet that fits the screen it is shown on.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// A macOS sheet is attached to the top of its window and **cannot be moved**.
/// A sheet taller than the display therefore hangs its bottom edge off the
/// screen — and the bottom edge is where Cancel and Save live. A shop opening a
/// product with enough parts, tiers and papers on it could neither save nor
/// close, and could not drag the thing into view either. Reported from a real
/// Mac, not imagined: "I just opened a product to edit and can't close it
/// because the buttons are hidden below and I can't move the window."
///
/// Escape still worked, because every one of these sheets puts
/// `.keyboardShortcut(.cancelAction)` on Cancel. That is the difference between
/// an annoyance and a trap, and it is worth keeping.
///
/// ── WHY A SHARED MODIFIER RATHER THAN A HEIGHT ON EACH SHEET ──────────────
///
/// Because the number to cap at is not a number anyone can write down. It is
/// the height of the screen this Mac is plugged into today, minus room for the
/// window's own title bar — a 13" laptop, a 27" display and a laptop with the
/// lid shut all give different answers, and the one it was built on is the one
/// it is least likely to be wrong at.
///
/// So: the content scrolls, the buttons do not. `content` goes in a ScrollView
/// that gives up its height when there is not enough; `footer` is pinned below
/// it and is always reachable. A short sheet is unchanged — a ScrollView whose
/// content fits adds nothing and shows no bars.
struct SheetFrame<Content: View, Footer: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    /// Room for the menu bar, the window's title bar and a margin, so the sheet
    /// stops short of the screen rather than exactly filling it.
    private static var chrome: CGFloat { 160 }

    private var ceiling: CGFloat {
        // `visibleFrame` already excludes the menu bar and the Dock. Nil only
        // when there is no screen at all, which is a screenshot run.
        let available = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, available - Self.chrome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) { content }
                    // The scroll view is as wide as the sheet; without this the
                    // content collapses to its ideal width inside it.
                    .frame(width: width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
                .frame(width: width, alignment: .leading)
        }
        .padding(18)
        .frame(maxHeight: ceiling)
        .fixedSize(horizontal: true, vertical: false)
    }
}
