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
enum SheetMetrics {
    /// Room for the menu bar, the window's title bar and a margin, so a sheet
    /// stops short of the screen rather than exactly filling it.
    static let chrome: CGFloat = 160

    /// The margin a sheet keeps between its content and its own edges.
    ///
    /// Named because a photograph has to know it: `SheetFrame(width:)` takes
    /// the CONTENT width, so a picture taken at that number comes back cropped
    /// through the trailing column — which is how the first supplier sheet
    /// snapshots came out with the currency mark cut in half.
    static let padding: CGFloat = 18

    /// How wide a sheet of this content width actually is.
    static func outerWidth(_ content: CGFloat) -> CGFloat { content + padding * 2 }

    /// The height available to a sheet, as a SEAM rather than a reading.
    ///
    /// A test measuring these sheets runs on whatever display the machine
    /// running it happens to have — usually a large one — and would therefore
    /// measure the cap as enormous and conclude every sheet fits. The screen
    /// size that matters is the SMALL one nobody develops on. So it is
    /// injectable, and `SheetsFitALaptopTests` sets it to a 13-inch laptop's.
    ///
    /// Here rather than on `SheetFrame` because that is generic, and Swift has
    /// no static stored properties in a generic type.
    nonisolated(unsafe) static var screenHeight: @Sendable () -> CGFloat = {
        // `visibleFrame` already excludes the menu bar and the Dock. Nil only
        // when there is no screen at all, which is a headless run.
        NSScreen.main?.visibleFrame.height ?? 900
    }

    static var ceiling: CGFloat { max(320, screenHeight() - chrome) }

    /// The room under the last row of a sheet's content, inside its scroll
    /// view: scrolled to the end, the last row stands this far clear of the
    /// rule over the buttons instead of touching it.
    static let contentFoot: CGFloat = 10

    /// The room between that rule and the buttons.
    static let footerHead: CGFloat = 10

    /// More content than room, by more than a rounding error: half a point of
    /// difference is two sizes that are the same size.
    static func overflows(content: CGFloat, room: CGFloat) -> Bool { content > room + 1 }
}

/// Lay a `SheetFrame`'s content flat instead of in its ScrollView, for a
/// photograph.
///
/// `ImageRenderer` draws NOTHING inside a `ScrollView`: the picture comes back
/// fully transparent and reads as a white page. Three sheets in this frame
/// photographed as blank pages for weeks with nothing failing, because the
/// check that would have said so runs only with a snapshot directory set.
///
/// AN ENVIRONMENT VALUE, NOT A STATIC. The first cut was a process-wide flag
/// like `SheetMetrics.screenHeight`, and Swift Testing runs suites in
/// parallel: the snapshot run set it while the sheets-fit measurement was
/// measuring, and a frame that must cap its height did not. Scoped to the
/// view being rendered, it can reach nothing else. The app never sets it.
private struct PhotographFlatKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var photographFlat: Bool {
        get { self[PhotographFlatKey.self] }
        set { self[PhotographFlatKey.self] = newValue }
    }
}

/// The frame: scrolling content over pinned buttons.
///
/// ── THE MARGIN IS INSIDE THE SCROLL VIEW (Nov 11 2026 review, B4 and B5) ──
///
/// It used to be outside: the whole frame was padded, so the scroll view was
/// exactly as wide as the content and CLIPPED there. A bordered text field
/// draws its border and its focus ring a point or two outside the frame layout
/// gives it, so every field that ran the full width of a sheet — a customer's
/// name, a product's, a machine's — lost its trailing border and both trailing
/// corners to the clip, in three sheets, by one cause.
///
/// The same clip was the bottom edge: a long sheet's content stopped dead
/// against the gap over the buttons, mid-line, with nothing to say there was
/// more, and scrolled to its end the last row touched that edge.
///
/// So the scroll view now runs edge to edge and to the top of the sheet, and
/// the margins are inside it: nothing is drawn against a clip, the scroller
/// sits at the sheet's edge and not over the fields, the content ends with a
/// foot of its own (`SheetMetrics.contentFoot`), and a hairline is drawn over
/// the buttons only while there is more content than room — which is the cue
/// that the sheet scrolls. A short sheet gains seven points of air over its
/// buttons and is otherwise as it was.
struct SheetFrame<Content: View, Footer: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    private var ceiling: CGFloat { SheetMetrics.ceiling }
    @Environment(\.photographFlat) private var flat
    /// Is there more content than the sheet has room for?
    @State private var scrolls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if flat {
                VStack(alignment: .leading, spacing: 14) { content }
                    .frame(width: width, alignment: .leading)
                    .padding(.horizontal, SheetMetrics.padding)
                    .padding(.top, SheetMetrics.padding)
                    .padding(.bottom, SheetMetrics.contentFoot)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) { content }
                        // The scroll view is as wide as the sheet; without this the
                        // content collapses to its ideal width inside it.
                        .frame(width: width, alignment: .leading)
                        .padding(.horizontal, SheetMetrics.padding)
                        .padding(.top, SheetMetrics.padding)
                        .padding(.bottom, SheetMetrics.contentFoot)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    SheetMetrics.overflows(content: geometry.contentSize.height,
                                   room: geometry.containerSize.height)
                } action: { _, now in scrolls = now }
            }

            Rectangle().fill(Khayt.hairline).frame(height: 1)
                .opacity(scrolls ? 1 : 0)
                .accessibilityHidden(true)

            footer
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, SheetMetrics.padding)
                .padding(.top, SheetMetrics.footerHead)
                .padding(.bottom, SheetMetrics.padding)
        }
        .frame(maxHeight: flat ? nil : ceiling)
        .fixedSize(horizontal: true, vertical: false)
    }
}
