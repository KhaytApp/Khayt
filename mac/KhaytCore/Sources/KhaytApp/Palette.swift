import SwiftUI
import AppKit

/// The colours this app is allowed to use, and where each of them came from.
///
/// ── WHY NOT JUST `.blue`, `.green`, `.orange` ─────────────────────────────
///
/// That is what was here, picked at each call site. Three problems, in order of
/// how much they cost:
///
/// 1. **They mean nothing.** `.orange` appeared on a printer alert, on a sync
///    retry and on a lost-edits warning — three unrelated things wearing one
///    colour, which is the first thing the HIG's colour guidance tells you not
///    to do: "avoid using the same color to mean different things".
/// 2. **They are not Khayt's.** A shop looking at its two apps side by side saw
///    a different green for the same "done".
/// 3. **They are not contrast-checked.** SwiftUI's `.green` is 2.4:1 on white.
///
/// ── WHERE THE COLOURS COME FROM ──────────────────────────────────────────
///
/// The app icon, and Khayt's own theme tokens. Nothing here was invented.
///
/// The icon is a printed Arabic khaa on a near-black ground: the letter and the
/// diamond above it are **cyan `#2BCDE4`**, and the one warm thing in the whole
/// mark is the **drop of filament** leaving the nozzle. That is the identity —
/// cyan, with amber reserved for the moment something is actually being made —
/// and it is the identity this app should wear rather than the system's blue.
///
/// The status hues are `renderer/themes/command/tokens.css` for light and
/// `renderer/styles.css` for dark, unchanged, so "done" is the same green in
/// both apps. Khayt's light themes already darken these to clear WCAG AA on a
/// white surface — `styles.css` says so in as many words — and that work is
/// taken rather than redone.
///
/// Measured on this palette, foreground on the surface it sits on — re-measured
/// against `Khayt.surface` when `Surface.swift` gave cards a colour of their
/// own, because the surface is half of every one of these figures and changing
/// it silently moved them all:
///
///     done  5.35   attention 5.29   late 5.50   note 5.54   cyan 4.88   (light)
///     done  6.31   attention 8.13   late 4.63   note 4.92   cyan 8.60   (dark)
///
/// The dark column is the tight one and `late` is the tightest thing in it, so
/// **`late` on `Khayt.surface` is the number to re-check** after any change to
/// either. A first draft of the card surface put it at 4.25 — under the 4.5 that
/// AA asks of text — and nothing looked wrong.
///
/// With Increase Contrast turned on every one of these is blended 30% toward
/// the far end of its surface, taking the whole palette to roughly 8:1. See
/// `adaptive(light:dark:name:)`.
///
/// ── COLOUR IS NEVER THE ONLY SIGNAL ──────────────────────────────────────
///
/// Every use of these is paired with a word or an SF Symbol. A shop reading a
/// screen in bright workshop light, or reading it colour-blind, gets the same
/// answer either way.
enum Khayt {

    /// A colour that is one thing in light appearance and another in dark.
    ///
    /// `NSColor(name:dynamicProvider:)` rather than two static colours picked by
    /// a `@Environment(\.colorScheme)` read: the dynamic provider is consulted
    /// again whenever the appearance changes, including inside a view AppKit
    /// draws for itself — a printed page, a menu, a cached bitmap — where the
    /// SwiftUI environment is not what decides.
    static func adaptive(light: Int, dark: Int, name: String) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor(hex: isDark ? dark : light)
            guard isHighContrast(appearance) else { return base }
            // Toward the far end of the surface it sits on: black under light
            // appearance, white under dark. A blend rather than twelve more
            // hand-picked hexes, because a blend cannot drift out of step with
            // the colour it strengthens, and 30% takes the whole palette from
            // roughly 5:1 to roughly 8:1 without changing any hue.
            return base.blended(towards: isDark ? .white : .black, by: 0.30)
        })
    }

    /// Has the reader asked for more contrast?
    ///
    /// **`bestMatch(from:)` cannot answer this**, and that was checked rather
    /// than assumed: asked to match against all four names, macOS returns
    /// `NSAppearanceNameAqua` for `NSAppearanceNameAccessibilityAqua` and
    /// `NSAppearanceNameDarkAqua` for the dark one. Written the obvious way,
    /// this would have compiled, run, and done nothing at all for the people
    /// it exists for. The name has to be read directly.
    private static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        appearance.name == .accessibilityHighContrastAqua
            || appearance.name == .accessibilityHighContrastDarkAqua
            || appearance.name == .accessibilityHighContrastVibrantLight
            || appearance.name == .accessibilityHighContrastVibrantDark
    }

    /// The app's own colour: the letter in the icon.
    ///
    /// Darkened for light appearance — `#2BCDE4` is 1.9:1 on white, which is
    /// fine for a large filled shape and unreadable as a label.
    static let cyan = adaptive(light: 0x0A6E81, dark: 0x2BCDE4, name: "khaytCyan")

    /// The drop of filament, and the ONE thing it is allowed to mean: something
    /// is being made right now.
    ///
    /// Not "warning" — that is `attention` below and it is a different idea. A
    /// printer mid-job is not a problem, it is the good state, and it is the
    /// one thing on any of these screens worth looking up at.
    static let hot = adaptive(light: 0xAF3E18, dark: 0xF0763D, name: "khaytHot")

    /// Finished, paid, sent, agreed. `--cmd-ok` / `--success`.
    static let done = adaptive(light: 0x1B5E4F, dark: 0x4FBFA0, name: "khaytDone")

    /// Wants a person, and will keep working if it does not get one: low stock,
    /// a nozzle near its life, a sync that will retry. `--warning`.
    static let attention = adaptive(light: 0x8A5A0B, dark: 0xE0A73C, name: "khaytAttention")

    /// Late, failed, refused. `--danger`.
    static let late = adaptive(light: 0xBB2D44, dark: 0xF2564A, name: "khaytLate")

    /// Worth reading, not worth acting on. `--info`.
    static let note = adaptive(light: 0x3E5A70, dark: 0x7FA6C4, name: "khaytNote")

    /// A model the shop has starred.
    ///
    /// Gold, because a star is gold everywhere and fighting that would cost
    /// recognition for nothing. Deliberately NOT `hot`: amber already means
    /// "being made right now", and a favourite is not that.
    ///
    /// The only colour here held to 3:1 rather than 4.5:1, and it is allowed to
    /// be because it is only ever a FILLED GLYPH — `star.fill`, over a
    /// thumbnail, with a shadow under it — and never text. The graphical
    /// threshold is the one that applies. A gold dark enough for 4.5:1 on white
    /// is brown, and a brown star is not a star.
    static let marked = adaptive(light: 0xA6790A, dark: 0xF0C040, name: "khaytMarked")

    /// Has this Mac's owner chosen an accent colour of their own?
    ///
    /// The HIG is explicit: "If people set their accent color setting to a value
    /// other than multicolor, the system applies their chosen color to the
    /// relevant items throughout your app, replacing your accent color." An app
    /// bundled with an asset catalog gets that for free; this one is assembled
    /// by hand, so the question is asked here and the tint is only applied when
    /// the answer is no.
    ///
    /// `AppleAccentColor` is absent for multicolour and 0–7 for a choice, which
    /// is why this reads the object rather than an integer — `integer(forKey:)`
    /// returns 0 for absent, and 0 is red.
    static var systemAccentIsChosen: Bool {
        UserDefaults.standard.object(forKey: "AppleAccentColor") != nil
    }

    /// The tint to apply to the whole app, or nil to leave the system's alone.
    static var appTint: Color? { systemAccentIsChosen ? nil : cyan }
}

extension NSColor {
    /// A straight sRGB blend towards another colour. Used for the increased
    /// contrast variants; `blended(withFraction:of:)` works in the receiver's
    /// own space, which for a colour built from hex is already sRGB, but this
    /// says so rather than relying on it.
    func blended(towards other: NSColor, by t: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: a.redComponent   + (b.redComponent   - a.redComponent)   * t,
                       green:   a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue:    a.blueComponent  + (b.blueComponent  - a.blueComponent)  * t,
                       alpha: 1)
    }

    /// `0xRRGGBB`, in sRGB. The palette above is written as hex because that is
    /// how both CSS files it was taken from are written, and a number that can
    /// be compared to its source by eye is one fewer place to introduce a
    /// difference.
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
