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
        if case .money(let code) = style, value != nil, Self.hasOwnMark(code) {
            // ── TWO LEAVES, AND THE MARK IS NOT IN THE FIGURE FACE ────────
            //
            // §5: "Never ask the figure face for the mark — it has no U+20C1
            // and substitutes whatever is nearest, which is how a non-currency
            // glyph got into the figures." So the mark is its own leaf in a
            // face that HAS it, the digits are their own leaf in the tabular
            // one, and a non-breaking space joins them and nothing else.
            //
            // The mark is isolated (U+2068 … U+2069) because U+20C1 is bidi
            // class AL: without it the algorithm carries it to the far side of
            // the digits even in a leaf pinned left-to-right.
            HStack(spacing: 0) {
                // The mark carries its own binding space, so the gap is part
                // of the mark's leaf rather than a third leaf of its own — a
                // bare `Text(" ")` in a view is also a string literal, and the
                // guard that keeps English out of views is right to say so.
                Text(Self.markLeaf)
                    .font(Self.markFont(size))
                Text(renderedText)
                    .font(TypeScale.figure(size, weight: weight))
                    .monospacedDigit()
            }
            .foregroundStyle(tint)
            .environment(\.layoutDirection, .leftToRight)
            // A figure is one thing. Three leaves in a row can each be
            // squeezed on their own, and the first squeeze broke "52,691.57"
            // across two lines — a money figure that wraps is a money figure
            // somebody misreads.
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .combine)
        } else {
            plain
        }
    }

    private var plain: some View {
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
            // Digits only. The mark is a separate leaf — see `body`.
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

    /// How a money figure is composed, so the rule can be read back.
    ///
    /// Three pieces and no string that contains all of them: that IS the rule
    /// — the mark and the digits are set in different faces and joined by one
    /// non-breaking space.
    struct MoneyParts: Equatable {
        let mark: String
        let gap: String
        let digits: String
    }

    var moneyParts: MoneyParts? {
        guard case .money(let code) = style, let value, Self.hasOwnMark(code) else { return nil }
        // What is DRAWN, not what is intended — a description that reports
        // the glyph while the view renders the ISO code is a test passing on
        // a screen nobody has.
        return MoneyParts(mark: Self.isolated(Self.hasMarkFont ? Self.mark : "SAR"),
                          gap: "\u{00A0}",
                          digits: Self.money(code).string(from: NSNumber(value: value)) ?? "—")
    }

    /// U+20C1 SAUDI RIYAL SIGN — §5, and NOT U+FDFC, which is the Iranian
    /// rial and which Unicode is explicit fonts must not remap.
    static let mark = "\u{20C1}"

    /// Which currencies Khayt draws a mark for itself rather than leaving to
    /// the formatter. One, for now, and it is the shop's own.
    static func hasOwnMark(_ code: String) -> Bool { code == "SAR" }

    /// First-strong isolate … pop. The `<bdi>` of the reference implementation.
    static func isolated(_ text: String) -> String { "\u{2068}" + text + "\u{2069}" }

    /// What the mark leaf actually says.
    ///
    /// ── NEVER THE SYSTEM'S GLYPH, EVEN WHEN THE SYSTEM HAS ONE ───────────
    ///
    /// macOS 26 carries U+20C1, so falling back to the system face produces no
    /// missing-glyph box — and §5 is explicit that this is the problem rather
    /// than the reassurance: at masthead size the system cut reads closer to a
    /// hash than to a currency mark, so the app looks finished and is wrong,
    /// and nothing files a bug about it. A box gets reported; a
    /// plausible-but-wrong mark ships.
    ///
    /// So until `KhaytRiyal` is registered the leaf says the ISO code, which
    /// is unambiguous and visibly not the final design. The composition does
    /// not change — one flag swaps the text for the glyph when the font lands.
    ///
    /// The general rule, which is worth more than this one case: any mark
    /// Khayt's meaning depends on comes from a font Khayt ships. A system face
    /// is allowed to be ABSENT. It is not allowed to be a surprise.
    static var markLeaf: String {
        isolated(hasMarkFont ? mark : "SAR") + "\u{00A0}"
    }

    /// Whether the mark's own font is registered.
    static var hasMarkFont: Bool {
        NSFontManager.shared.availableFontFamilies.contains("KhaytRiyal")
    }

    /// The face the mark is set in — `KhaytRiyal`, or nothing.
    static func markFont(_ size: CGFloat) -> Font {
        hasMarkFont ? .custom("KhaytRiyal", fixedSize: size)
                    : TypeScale.label(size)
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
        // Digits, grouping and decimals — not the symbol. Khayt composes the
        // mark itself (§5), because the formatter places it where the LOCALE
        // wants rather than where the design does.
        f.numberStyle = hasOwnMark(code) ? .decimal : .currency
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
