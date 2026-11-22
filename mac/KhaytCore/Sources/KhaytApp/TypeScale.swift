import SwiftUI

/// The type scale — §2 of the design spec.
///
/// Six steps and no others. Each is named for what it SAYS, not for its size,
/// so a view cannot quietly invent a seventh by nudging a number: there is no
/// `.font(.system(size: 12.5))` to write if the only way in is through here.
///
/// ── THE BRAND FACE, AND THE SUBSTITUTION WHEN IT IS ABSENT ────────────────
///
/// Space Grotesk carries the display, title, row and label steps. The repo
/// ships `.woff2` only, which Core Text cannot register — the spec calls that
/// a packaging mistake rather than a decision, and a static TTF cut of
/// 400/500/600/700 is on the way.
///
/// Until it lands the app runs on SF, and §2 is explicit that this is NOT a
/// drop-in: the tracking was authored for Grotesk's narrower figures and
/// smaller x-height, and SF is optically sized, so it already carries what
/// Grotesk needs added. Leaving −0.02em on SF display numerals "closes them up
/// and the money stops scanning".
///
/// So every step here asks `tracking(for:)` rather than carrying one number,
/// and the two columns of §2's substitution table are both written down. When
/// the TTF arrives, `brandIsBundled` flips and the Grotesk column applies with
/// nothing else to change.
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

    /// §2's tracking, per step, for whichever face is actually rendering.
    ///
    /// In ems, as the spec writes it; callers multiply by their own size.
    /// Grotesk needs it authored; SF has most of it already.
    enum Step { case display, title, row, label }

    static func tracking(_ step: Step, size: CGFloat) -> CGFloat {
        let em: CGFloat
        switch (step, brandIsBundled) {
        case (.display, true):  em = -0.02
        case (.display, false): em = -0.01
        case (.title, _), (.row, _): em = 0
        case (.label, true):  em = 0.10
        case (.label, false): em = 0.075
        }
        return em * size
    }

    /// The label step is heavier in SF, which is lighter than Grotesk at the
    /// same nominal weight — §2's substitution table asks for 800 where
    /// Grotesk is 700.
    static func labelWeight() -> Font.Weight { brandIsBundled ? .bold : .heavy }

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
    static func label(_ size: CGFloat = 9.5, weight: Font.Weight? = nil) -> Font {
        brand(size, weight ?? labelWeight())
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
            .tracking(TypeScale.tracking(.label, size: size))
            .foregroundStyle(tint)
    }
}
