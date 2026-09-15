import SwiftUI
import AppKit

/// Which title bar the window wears — one, never two.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// The new shell draws its own 40pt navy strip: the view's title, the ⌘K
/// field, the wordmark, the state of the book. The window went on drawing the
/// system's title bar ABOVE it, so every screen wore two headers — and on Jobs
/// and the Board the upper one also carried a stray "+", because those screens
/// still declared a `.toolbar` and a toolbar has nowhere to go but the window's
/// own bar.
///
/// ── THE SCENE TAKES IT OFF; THIS PUTS IT BACK ─────────────────────────────
///
/// `KhaytApp.shopScene` asks for `.windowStyle(.hiddenTitleBar)`, and that is
/// the only thing that works: doing it by hand here —
/// `titlebarAppearsTransparent`, no toolbar, `.fullSizeContentView`, all three
/// confirmed applied on the live window — still left a 32pt opaque band
/// painted over the navy strip, with 8pt of navy showing beneath it.
///
/// `SceneBuilder` takes no `if`, so the scene cannot ask that question per
/// shell. This is the other direction, which does work by hand: Settings →
/// General → Appearance switches back to the old shell, that shell is a
/// `NavigationSplitView` with a real toolbar, and a window left with no title
/// bar after the switch would have no toolbar, no title and no way to get
/// either back short of relaunching.
struct WindowChrome: NSViewRepresentable {
    /// True when the app draws its own strip and the window's must go.
    let hidesTitleBar: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.hidesTitleBar = hidesTitleBar
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.hidesTitleBar = hidesTitleBar
    }

    /// A view that draws nothing and exists to know which window it landed in.
    ///
    /// There is no supported way to reach the `NSWindow` behind a SwiftUI scene
    /// from the scene itself, and `NSApp.windows` is a guess — the Help window
    /// and the Settings window are in it too. A zero-sized view in the shell's
    /// own background is in exactly one window by construction.
    final class Probe: NSView {
        var hidesTitleBar = true {
            didSet { if hidesTitleBar != oldValue { apply() } }
        }

        /// The toolbar taken off the window, so it can be put back.
        private var parked: NSToolbar?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            // NOT synchronously: this runs from inside AppKit's own layout
            // pass, and changing a style mask there re-enters it.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let hide = self.hidesTitleBar
                // THE STYLE MASK IS LEFT ALONE, and that is the whole lesson
                // of this file. Taking `.fullSizeContentView` back off a live
                // window to give the old shell its bar back rendered a white
                // void where the sidebar should be and a rainbow block where
                // the inspector should be — a window being rebuilt underneath
                // a view tree that is not expecting it.
                //
                // The old shell does not need it: with `.hiddenTitleBar` the
                // toolbar it declares still draws, in the space the title bar
                // would have taken. All it loses is the window's title text,
                // which that scene style hides anyway.
                window.titleVisibility = hide ? .hidden : .visible
                // THE TOOLBAR, PARKED RATHER THAN DROPPED.
                //
                // The old shell's toolbar carries the book source, the owed
                // summary and the inspector toggle; SwiftUI builds it from that
                // shell's `.toolbar` and leaves it attached to the window when
                // the shell goes away. Keeping it here means the switch back
                // does not depend on SwiftUI rebuilding it.
                if hide {
                    self.parked = window.toolbar
                    window.toolbar = nil
                } else if window.toolbar == nil {
                    window.toolbar = self.parked
                }
            }
        }
    }
}

extension View {
    /// Take the window's own title bar off, or put it back.
    func windowTitleBar(hidden: Bool) -> some View {
        background(WindowChrome(hidesTitleBar: hidden).frame(width: 0, height: 0))
    }
}
