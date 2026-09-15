import SwiftUI

/// The type scale — §2 of the design spec.
///
/// Six steps and no others. Each is named for what it SAYS, not for its size,
/// so a view cannot quietly invent a seventh by nudging a number: there is no
/// `.font(.system(size: 12.5))` to write if the only way in is through here.
///
/// ── THE BRAND FACE, AND WHAT HAPPENS WITHOUT IT ───────────────────────────
///
/// Space Grotesk carries the display, title, row and label steps. The repo
/// ships it as `.woff2` for the Electron app, which macOS cannot register —
/// Core Text takes OTF and TTF. Until a desktop cut is bundled, `brand`
/// resolves to the system face at the same size and weight, which is what SF
/// is for and is a great deal better than shipping a font that fails to load
/// and silently falls back anyway.
///
/// `brandIsBundled` says which of the two is happening, so a screenshot can
/// be read honestly rather than guessed at.
///
/// ── ARABIC ────────────────────────────────────────────────────────────────
///
/// Arabic swaps to the system's Arabic face at the same steps and gains a
/// notch of line height — the script is taller, and a line box set for Latin
/// clips it. `.body` is the only step that sets line spacing, because it is
/// the only step that ever wraps.
enum TypeScale {

    /// Money figures and view titles. The only step that is ever large.
    static func display(_ size: CGFloat = 20, weight: Font.Weight = .bold) -> Font {
        brand(size, weight)
    }

    /// Section and card headings.
    static func title(_ size: CGFloat = 13, weight: Font.Weight = .semibold) -> Font {
        brand(size, weight)
    }

    /// Table row titles and nav items.
    static func row(_ size: CGFloat = 11.5, weight: Font.Weight = .medium) -> Font {
        brand(size, weight)
    }

    /// Sentences and explanations — the only step set in the system face by
    /// choice rather than by fallback, because prose is what SF is best at.
    static func body(_ size: CGFloat = 11.5, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Column heads and group heads. Caps and tracked; see `Label`.
    static func label(_ size: CGFloat = 9.5, weight: Font.Weight = .bold) -> Font {
        brand(size, weight)
    }

    /// EVERY number. Monospaced digits so a column of figures lines up on its
    /// decimal without a single alignment guide — the spec asks for tabular
    /// and this is what tabular means on this platform.
    static func figure(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Body line spacing. SwiftUI's `lineSpacing` is the GAP between lines,
    /// not the line box, so the spec's 1.55 becomes the leftover after the
    /// glyphs — and Arabic's 1.6 is one notch more.
    static func bodyLeading(_ size: CGFloat = 11.5, arabic: Bool = false) -> CGFloat {
        size * ((arabic ? 1.6 : 1.55) - 1)
    }

    /// Whether the brand face is actually available to Core Text.
    ///
    /// Read at first use rather than assumed: a bundled font that failed to
    /// register looks exactly like one that was never added, and the whole
    /// point of asking is to be able to say which.
    static let brandIsBundled: Bool = NSFontManager.shared
        .availableFontFamilies.contains(brandFamily)

    static let brandFamily = "Space Grotesk"

    private static func brand(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        brandIsBundled
            ? .custom(brandFamily, fixedSize: size).weight(weight)
            : .system(size: size, weight: weight)
    }
}

/// A caps, tracked label — §2's Label step, which is never just a small font.
///
/// The tracking is the point. Caps set at 9.5pt with normal tracking read as a
/// smudge; the spec's 0.08–0.12em is what turns them back into words. Written
/// once here so no screen has to remember it.
struct CapsLabel: View {
    let text: String
    var tint: Color = Role.text3
    var size: CGFloat = 9.5

    /// Unlabelled, because at every call site the word IS the argument:
    /// `CapsLabel("Owed")` reads as the thing it draws.
    init(_ text: String, tint: Color = Role.text3, size: CGFloat = 9.5) {
        self.text = text
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(TypeScale.label(size))
            .tracking(size * 0.1)
            .foregroundStyle(tint)
    }
}
