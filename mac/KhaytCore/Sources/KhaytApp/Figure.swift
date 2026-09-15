import SwiftUI

/// Numbers — §5, which the spec calls the most important section, and it is.
///
/// ── A MISSING FIGURE IS `—`, NEVER `0` ────────────────────────────────────
///
/// They are different facts. `﷼ 0.00` means the shop earned nothing; `—` means
/// Khayt was never told. Drawing the second as the first is the subtly-wrong
/// figure the brief calls worse than a missing one — a shop prices against it,
/// and nothing on screen ever admits the number was invented.
///
/// So `Figure` takes an OPTIONAL and draws the dash itself. There is no path
/// through this type that turns an absent value into a zero, which is the only
/// reliable way to keep one out.
///
/// ── AND A PARTIAL SUM SAYS SO ─────────────────────────────────────────────
///
/// When part of a sum is unknown the total is labelled "at least" or "at most"
/// and says why in one line underneath — never silently averaged over a hole.
/// `Certainty` is that label, and it travels with the number rather than being
/// left to whichever screen happens to remember.
///
/// ── EVERY LEAF IS BIDI-ISOLATED ───────────────────────────────────────────
///
/// Khayt's content is permanently mixed-script: `bust_abdulaziz_v4.stl`,
/// `Prusa MK4 #1`, `180 g`, `2h 14m`, an email address. Dropped into an Arabic
/// paragraph without isolation, trailing punctuation jumps to the front of the
/// sentence and units drift off their numbers. In SwiftUI, isolation is what
/// you get by making each value its OWN `Text` with its own resolved
/// direction — so this type never concatenates, and neither may its callers.
/// `NoConcatenatedValuesTests` checks that.
struct Figure: View {
    /// Nil is "not known", and is drawn as an em dash. This is an Optional on
    /// purpose: a caller with nothing to show cannot pass 0 without saying so.
    let value: Double?
    var style: Style = .plain
    var certainty: Certainty = .exact
    var size: CGFloat = 11
    var weight: Font.Weight = .medium
    var tint: Color = Role.text

    enum Style {
        /// A bare number.
        case plain
        /// Money, formatted through the locale's currency position — the
        /// riyal glyph ﷼ is bidi class AL and WILL jump to the wrong side of
        /// its digits if a string is assembled by hand.
        case money(code: String)
        /// A quantity with a Latin unit: `180 g`, `540 h`.
        case unit(String)
        /// A signed percentage, where the sign is part of the meaning.
        case signedPercent
    }

    /// What the number is worth as a claim.
    enum Certainty {
        case exact
        /// Some of the parts are unknown, so the truth is no lower than this.
        case atLeast
        /// Some of the parts are unknown, so the truth is no higher than this.
        case atMost

        var prefixKey: String? {
            switch self {
            case .exact:   nil
            case .atLeast: "mac.at_least"
            case .atMost:  "mac.at_most"
            }
        }
    }

    var body: some View {
        Text(renderedText)
            .font(TypeScale.figure(size, weight: weight))
            .monospacedDigit()
            .foregroundStyle(value == nil ? Role.text3 : tint)
            // The whole value is one run with its own direction. This is the
            // isolation: SwiftUI resolves a Text's base direction from its own
            // content, so a Latin figure inside an Arabic column stays Latin
            // and keeps its unit attached.
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityLabel(renderedText)
    }

    /// The string this draws. Not private: `DesignSpecTests` asserts that an
    /// unknown figure is a dash and a real zero is not, and a rule that cannot
    /// be read back is a rule on trust.
    var renderedText: String {
        guard let value else { return "—" }
        switch style {
        case .plain:
            return Self.plain.string(from: NSNumber(value: value)) ?? "—"
        case .money(let code):
            return Self.money(code).string(from: NSNumber(value: value)) ?? "—"
        case .unit(let unit):
            // A non-breaking space binds the unit to its digits, so a narrow
            // column cannot wrap "180" onto one line and "g" onto the next.
            let n = Self.plain.string(from: NSNumber(value: value)) ?? "—"
            return n + "\u{00A0}" + unit
        case .signedPercent:
            let n = Self.percent.string(from: NSNumber(value: value)) ?? "—"
            return value > 0 ? "+" + n : n
        }
    }

    // MARK: - Formatters
    //
    // Built once. A NumberFormatter is expensive enough that one per cell in a
    // table of forty-two jobs is measurable, and they are not free to make.

    private static let plain: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let percent: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 0
        return f
    }()

    private static var moneyCache: [String: NumberFormatter] = [:]

    private static func money(_ code: String) -> NumberFormatter {
        if let made = moneyCache[code] { return made }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        // The LOCALE decides which side the symbol sits on, and for the riyal
        // that is not a detail: writing "﷼ 1,240" by hand puts an AL-class
        // glyph next to Latin digits with nothing to say where the run ends.
        f.locale = Locale.current
        // ── WHICH RIYAL MARK ──────────────────────────────────────────────
        //
        // §5 names U+FDFC (﷼), and that is what this uses. The app elsewhere
        // draws U+20C1, the newer sign — a decision taken for the invoice,
        // where the glyph is drawn as a path rather than set as text. Here it
        // is set in the monospaced figure face, which does not carry U+20C1
        // and substitutes something that is not a currency mark at all.
        //
        // Worth one look before this spreads: the two marks disagreeing across
        // the app is a question for the spec, not for this formatter.
        if code == "SAR" {
            // ISOLATED, not merely placed. U+FDFC is bidi class AL: beside
            // Latin digits it forms its own right-to-left run and the algorithm
            // reorders it to the far side of the number — the pattern below
            // puts it first and it rendered last, which is precisely the jump
            // §5 describes. U+2068/U+2069 (first-strong isolate, pop) are the
            // `<bdi>` the reference implementation wraps it in.
            f.currencySymbol = "\u{2068}\u{FDFC}\u{2069}"
            // ── AND BOUND TO ITS DIGITS ───────────────────────────────────
            //
            // §5: the mark "must be bidi-isolated and bound to its digits with
            // a non-breaking space". The machine's locale decides position for
            // ITS currency, not for the shop's — on an en_US Mac it put the
            // riyal after the number with nothing between, which is neither the
            // Saudi convention nor readable.
            //
            // A PATTERN rather than a concatenation: the formatter still places
            // the mark, so this is not the string-building §5 forbids.
            f.positiveFormat = "¤\u{00A0}#,##0.00"
            f.negativeFormat = "-¤\u{00A0}#,##0.00"
        }
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        moneyCache[code] = f
        return f
    }
}

/// A figure with a label above it — the masthead's shape, and the shape of
/// every figure in an inspector.
///
/// The label and the value are two `Text`s in a stack, never one string. That
/// is not a style choice: "OWED ﷼ 4,820" as a single run is exactly the
/// concatenation §5 forbids, and it breaks in Arabic in a way nobody notices
/// until a shop reads it.
struct LabelledFigure: View {
    let label: String
    let value: Double?
    var style: Figure.Style = .plain
    var certainty: Figure.Certainty = .exact
    var note: String?
    var words: Words
    var onNavy = false
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            CapsLabel(label, tint: onNavy ? Role.onNavy3 : Role.text3, size: 9)
            HStack(spacing: Space.xs) {
                if let prefix = certainty.prefixKey {
                    Text(words.callIt(prefix))
                        .font(TypeScale.body(10))
                        .foregroundStyle(onNavy ? Role.onNavy3 : Role.text3)
                }
                Figure(value: value, style: style, size: size, weight: .bold,
                       tint: onNavy ? Role.onNavy : Role.text)
            }
            // WHY it is unknown, in one line. A dash with no explanation tells
            // a shop something is missing and nothing about what to do.
            if let note {
                Text(note)
                    .font(TypeScale.body(9.5))
                    .foregroundStyle(onNavy ? Role.onNavy3 : Role.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
