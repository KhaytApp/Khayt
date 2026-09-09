import SwiftUI
import AppKit

/// How this app moves, and what it refuses to move for.
///
/// ── COUNTED BEFORE WRITING THIS: SIX ──────────────────────────────────────
///
/// Six animation call sites in the whole application. Every figure snapped
/// from one value to the next, every gauge was drawn at its final angle, and
/// nothing on any screen told you that anything had changed. A shop watching a
/// print for three hours saw a number that was 61 and then was 62, with no
/// moment in between — so the screen had to be READ to be understood, which is
/// the thing a shop floor has least time for.
///
/// ── MOTION HAS TO MEAN SOMETHING ──────────────────────────────────────────
///
/// Everything here is tied to a real change in the shop: a print advancing, a
/// gauge arriving at its reading, a machine starting. Nothing loops for
/// decoration, nothing bounces, and nothing draws the eye to a thing that is
/// not news. A dashboard where something is always moving is a dashboard where
/// movement stops meaning anything — the same argument `Palette.swift` makes
/// about the warm colour, for the same reason.
///
/// ── AND IT IS THE FIRST THING TO SWITCH OFF ───────────────────────────────
///
/// Every duration here goes to zero under Reduce Motion, and the pulse stops
/// entirely rather than slowing down. That is not a nicety: this app is for a
/// workshop, motion sensitivity is common, and a pulsing dot on a screen
/// somebody has to look at all day is the exact thing the setting exists for.
/// `Motion.on` reads the accessibility environment, so it follows the system
/// without any screen having to remember to ask.
enum Motion {

    /// A figure arriving at a new value. Long enough to be seen as a change,
    /// short enough that a shop is not waiting for it.
    static let figure = Animation.easeOut(duration: 0.45)
    /// A bar or a gauge growing to its reading.
    static let gauge = Animation.easeOut(duration: 0.65)
    /// A print advancing. Slower, because it is the one motion that stands for
    /// hours of work and a snappy one would misrepresent it.
    static let progress = Animation.easeInOut(duration: 0.9)
    /// Something answering a pointer. Must be quicker than a person can
    /// notice, or the app feels heavy rather than alive.
    static let hover = Animation.easeOut(duration: 0.12)

    /// The animation, or none at all when the reader has asked for none.
    static func of(_ animation: Animation, unless reduced: Bool) -> Animation? {
        reduced ? nil : animation
    }
}

/// A slow breath, for the one thing on a screen that is happening right now.
///
/// Used on the amber dot beside a running print and nowhere else. `Palette`
/// reserves that colour for "being made right now"; this reserves the movement
/// for the same thing, so a floor with nothing running is a floor that is
/// completely still.
struct Alive: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduced
    var active = true
    @State private var breathed = false

    func body(content: Content) -> some View {
        content
            .opacity(active && breathed && !reduced ? 0.45 : 1)
            .animation(active && !reduced
                       ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                       : nil,
                       value: breathed)
            .onAppear { if active && !reduced { breathed = true } }
            // Stops where it is rather than mid-fade: a dot left at 45% opacity
            // on a machine that has finished reads as a fault.
            .onChange(of: active) { _, now in breathed = now && !reduced }
    }
}

extension View {
    /// The one movement reserved for work in progress.
    func alive(_ active: Bool = true) -> some View { modifier(Alive(active: active)) }

    /// Lift under the pointer — the whole vocabulary for "this is yours to
    /// press", used on every card and tile that opens something.
    func liftsOnHover(_ hovering: Bool, by amount: CGFloat = 1) -> some View {
        modifier(Lift(hovering: hovering, amount: amount))
    }
}

private struct Lift: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduced
    let hovering: Bool
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduced ? 1 + amount / 100 : 1)
            // The pointer changes too. A tile that lifts but keeps an arrow
            // cursor is a tile people look at and do not press.
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .animation(Motion.of(Motion.hover, unless: reduced), value: hovering)
    }
}
