import SwiftUI

/// The design system's colour roles — §1 of `Khayt — design spec.md`.
///
/// ── A ROLE, NEVER A SHADE ─────────────────────────────────────────────────
///
/// Every entry here is named for the JOB it does, not for the colour it
/// happens to be. A view asks for `Role.late` because the thing is late, never
/// for an orange. That is the whole reason this type exists: the spec's own
/// rule is *"never reach for a raw hex in a view"*, and a hex written into a
/// view is a decision that cannot be revised, measured, or made to differ
/// between light and dark.
///
/// `NoRawHexInViewsTests` holds the app to it.
///
/// ── TWO AUTHORED PALETTES, NOT ONE DIMMED ─────────────────────────────────
///
/// Light and dark are both written out. Dark is not light with the brightness
/// pulled down: the accent LIGHTENS (`#E2621B` → `#F57A33`) because a dark
/// ground needs a brighter mark to carry the same weight, and the state
/// grounds go from tinted paper to tinted near-black rather than to grey.
///
/// ── THE ORANGE RULE ───────────────────────────────────────────────────────
///
/// `acc` never carries text. The moment orange sits under white type it
/// becomes `accink`. Orange on white measures about 3.5:1; `accink` on white
/// is about 4.9:1, which clears AA. This is the one pair in the palette that
/// exists solely because of a contrast measurement, and `AccentCarriesTextTests`
/// is what stops the two being used interchangeably again.
///
/// In DARK both roles resolve to the same value — `#F57A33` on a near-black
/// ground already clears AA, so there is nothing to correct. That is not an
/// oversight to be tidied up: collapsing them in light is what the rule
/// forbids.
enum Role {

    // MARK: Grounds

    /// The window ground behind content.
    static let bg = adaptive(light: 0xFBF9F5, dark: 0x14161A, name: "roleBg")
    /// Cards, tables, sheets — the paper things sit on.
    static let surf = adaptive(light: 0xFFFFFF, dark: 0x1B1E24, name: "roleSurf")
    /// Toolbars, footers, the inspector: a surface that is NOT the content.
    static let surf2 = adaptive(light: 0xFAF6EE, dark: 0x171A1F, name: "roleSurf2")
    /// Chips, wells, inert fills — a surface nothing is written on.
    static let surf3 = adaptive(light: 0xF3EDE1, dark: 0x232830, name: "roleSurf3")

    // MARK: Lines
    //
    // Two weights, and they are not interchangeable: `line` separates rows
    // INSIDE a container, `line2` is the container's own edge. The spec's rule
    // — never both on one edge — is what keeps a table from growing a double
    // rule where its last row meets its frame.

    /// The hairline between rows.
    static let line = adaptive(light: 0xEEE7DA, dark: 0x262B33, name: "roleLine")
    /// Container borders and dividers.
    static let line2 = adaptive(light: 0xE2DBCD, dark: 0x323945, name: "roleLine2")

    // MARK: Text

    /// Primary text.
    static let text = adaptive(light: 0x0F1B2E, dark: 0xEEF1F5, name: "roleText")
    /// Secondary text — a sentence that explains the primary one.
    static let text2 = adaptive(light: 0x4A463F, dark: 0xA4ACB8, name: "roleText2")
    /// Tertiary. LABELS ONLY: column heads, group heads, units. Never a
    /// sentence a shop has to read, because at this contrast it is a texture.
    static let text3 = adaptive(light: 0x6E675C, dark: 0x8A929E, name: "roleText3")

    // MARK: Navy — the app's own furniture

    /// Sidebar, menu bar, primary buttons.
    static let navy = adaptive(light: 0x0F1B2E, dark: 0x0B1220, name: "roleNavy")
    /// The money masthead strip, one step off the sidebar so the two read as
    /// different things rather than one continuous slab.
    static let navy2 = adaptive(light: 0x132238, dark: 0x101A2C, name: "roleNavy2")

    /// What sits ON navy. Three weights, mirroring text/text2/text3 — a navy
    /// surface needs its own ink scale or every label on it is either shouting
    /// or invisible.
    static let onNavy = Color.white
    static let onNavy2 = Color.white.opacity(0.75)
    static let onNavy3 = Color.white.opacity(0.52)
    /// The hairline on navy.
    static let navyLine = Color.white.opacity(0.12)

    // MARK: Accent

    /// The graphic accent: fills, rules, glyphs, the selection bar. NEVER
    /// under text — see `accInk`.
    static let acc = adaptive(light: 0xE2621B, dark: 0xF57A33, name: "roleAcc")
    /// The accent THAT CARRIES WHITE TEXT. Darker in light appearance by
    /// exactly enough to clear 4.5:1; identical to `acc` in dark, where the
    /// ground is already near-black.
    static let accInk = adaptive(light: 0xB53A09, dark: 0xF57A33, name: "roleAccInk")
    /// THE LABEL THAT SITS ON `accInk` — and it is not white.
    ///
    /// The two appearances solve this differently and both are correct: light
    /// darkens the fill and keeps a white label (#FFFFFF on #B53A09 = 5.88:1);
    /// dark keeps the vivid fill and flips the label to near-black (#14161A on
    /// #F57A33 = 6.65:1). Hard-coding white passes in light and fails at
    /// 2.72:1 in dark, which is the whole reason this role exists.
    static let onAcc = adaptive(light: 0xFFFFFF, dark: 0x14161A, name: "roleOnAcc")

    /// The label on a `warn` fill, for the same reason.
    static let onWarn = adaptive(light: 0xFFFFFF, dark: 0x14161A, name: "roleOnWarn")

    /// The focus halo and the selected-nav wash — the accent at a weight that
    /// tints rather than marks.
    static let accSoft = adaptiveAlpha(light: 0xE2621B, lightAlpha: 0.09,
                                       dark: 0xF57A33, darkAlpha: 0.06)

    /// A STATE COLOUR MOUNTED ON NAVY.
    ///
    /// The sidebar, title bar and masthead are navy in BOTH appearances, so a
    /// mark on them is measured against navy rather than against a content
    /// surface — and the content-surface `late` on navy is 3.33:1, the worst
    /// ratio this app can produce, on a mark §4 says must survive being read.
    /// Theme-invariant, because the ground it sits on is.
    static let lateOnNavy = Color(nsColor: NSColor(rgb: 0xFF9E78))

    // MARK: States
    //
    // Each of these is HALF of a state. The other half is a glyph and a word —
    // see `StateMark` — because the spec's second non-negotiable is that
    // colour is never the only signal. Greyscale the app and it still reads.

    /// Late, blocked, out of stock.
    static let late = adaptive(light: 0xB03808, dark: 0xFF8A5C, name: "roleLate")
    /// The ground behind a late row or card.
    static let lateBg = adaptive(light: 0xFDF1EA, dark: 0x2B1A13, name: "roleLateBg")
    /// The border of one, which is not the text colour: a 3px rule at full
    /// strength beside tinted paper would be the loudest thing on the screen.
    static let lateLine = adaptive(light: 0xF0D4C4, dark: 0x4A2A1C, name: "roleLateLine")

    /// Due today, service due, low stock.
    static let warn = adaptive(light: 0xA64A08, dark: 0xFFB43D, name: "roleWarn")
    static let warnBg = adaptive(light: 0xFDF7EA, dark: 0x2A2112, name: "roleWarnBg")
    static let warnLine = adaptive(light: 0xEDDCB8, dark: 0x4A3A18, name: "roleWarnLine")

    /// Running, paid, healthy.
    static let ok = adaptive(light: 0x16794A, dark: 0x5FD08A, name: "roleOk")
    static let okBg = adaptive(light: 0xEDF6F0, dark: 0x14261C, name: "roleOkBg")

    // MARK: Sheets and the desk behind the window

    /// A sheet's own ground — off the window's, so a sheet reads as a
    /// different piece of paper rather than a panel of the same one.
    static let sheet = adaptive(light: 0xF7F6F4, dark: 0x1F232A, name: "roleSheet")

    // MARK: - Resolving

    /// One colour, two authored values.
    ///
    /// Named rather than anonymous so the value can be found in a rendered
    /// snapshot and in Accessibility Inspector — an unnamed colour in a
    /// screenshot is a hex somebody has to match by eye.
    private static func adaptive(light: UInt32, dark: UInt32, name: String) -> Color {
        Color(nsColor: NSColor(name: name) { appearance in
            appearance.isDark ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
    }

    private static func adaptiveAlpha(light: UInt32, lightAlpha: Double,
                                      dark: UInt32, darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(rgb: dark).withAlphaComponent(darkAlpha)
                : NSColor(rgb: light).withAlphaComponent(lightAlpha)
        })
    }
}

extension NSAppearance {
    /// Whether this appearance is one of the dark ones — including the
    /// high-contrast variants, which a plain `== .darkAqua` comparison misses
    /// and which are exactly the appearances a contrast rule must not fail in.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua,
                         .accessibilityHighContrastAqua,
                         .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}

extension NSColor {
    /// 0xRRGGBB, in sRGB. The ONE place a hex becomes a colour, which is what
    /// makes "no raw hex in a view" a rule a test can check.
    convenience init(rgb: UInt32) {
        self.init(srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}
