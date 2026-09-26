import SwiftUI
import KhaytCore

/// Money on screen.
///
/// Two rules, and both of them are why a spreadsheet reads better than most
/// apps: figures are right-aligned so the units line up, and they are set in
/// monospaced digits so they do not shuffle sideways as the numbers change. The
/// Electron app sets money in the proportional UI face inside a flex row, and
/// the columns wander by a character or two down the page.
enum Money {

    // MARK: - The mark a currency is written with

    /// The official Saudi Riyal sign, U+20C1.
    ///
    /// NOT U+20C0, which is the codepoint everyone reaches for and which draws
    /// an empty box: measured on this Mac, it falls through to `LastResort` —
    /// Apple's tofu font — and it did the same on an iPhone. U+20C1 is what the
    /// system font actually carries the mark at.
    private static let riyal = "\u{20C1}"

    /// Does the font this Mac draws with actually have it?
    ///
    /// ── ASKED, NOT ASSUMED ────────────────────────────────────────────────
    ///
    /// The mark was adopted in 2025 and the glyph arrived with a system font
    /// after it. macOS 26 draws it — measured, not assumed — but a shop whose
    /// prices are empty boxes is worse served than one reading "SAR", which is
    /// what it read yesterday and is not wrong, only older.
    ///
    /// So the question is put to CoreText once, on the face the app draws in,
    /// and the answer decides. There is no version check here on purpose: what
    /// matters is whether the glyph exists, and a font can arrive in a point
    /// release that no `if #available` knows about. That is why raising the
    /// app's floor to macOS 26 changed nothing here: the question was never
    /// which version this is.
    static let drawsTheRiyal: Bool = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var chars = Array(riyal.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        let ok = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        return ok && glyphs.allSatisfy { $0 != 0 }
    }()

    /// How to write this currency: its own mark where there is one, its code
    /// otherwise. Every other currency keeps its code, which is what stops the
    /// one symbol this shop uses becoming an assumption about the rest.
    static func mark(_ currency: String) -> String {
        currency.uppercased() == "SAR" && drawsTheRiyal ? riyal : currency
    }

    // MARK: - The digits a figure is written in

    /// The locale every figure below is formatted in, PINNED.
    ///
    /// ── WESTERN DIGITS, ON AN ARABIC MAC TOO ──────────────────────────────
    ///
    /// A `NumberFormatter` left alone takes the system locale. On a Mac set to
    /// العربية (السعودية) that is `ar_SA`, and every price in this app came out
    /// ١٬٢٣٤٫٥٠ — with the app's own language in English too, because the
    /// digits never came from the app's language.
    ///
    /// Saudi products ship Western figures. Codepoint scans of live Arabic
    /// pages — Al Rajhi, SNB, Absher, Tawakkalna, Salla, STC, SAMA — find them
    /// on essentially every financial figure, and the Electron app already
    /// carries the rule and a guard for it (`test/arabic-numerals.test.js`).
    /// The one place Khayt does write Arabic-Indic digits is an invoice whose
    /// shop asked for them, where it is a deliberate pass over the document.
    ///
    /// `en_US` and not the reflexive `en_US_POSIX`: POSIX suppresses grouping
    /// altogether and hands back "1234567.89".
    private static let digits = Locale(identifier: "en_US")

    /// A value that shows as zero at `decimals` places, as an UNSIGNED zero.
    ///
    /// −0.0 is a real Double — `-row.expenses` on a quarter that spent
    /// nothing — and NumberFormatter keeps its sign, so the P&L chart labelled
    /// an empty bar "−0.00", which reads as a figure somebody worked out. So
    /// does −0.001 at two places. Every formatter here goes through this.
    static func unsignedZero(_ x: Double, decimals: Int) -> Double {
        let scale = pow(10, Double(max(0, decimals)))
        return (x * scale).rounded() == 0 ? 0 : x
    }


    /// A negative figure, held left-to-right.
    ///
    /// ── THE MINUS WENT TO THE WRONG END IN ARABIC ────────────────────────
    ///
    /// A leading "-" is a neutral to the bidi algorithm, and in a right-to-left
    /// paragraph a neutral before digits takes the paragraph's direction — so
    /// the Arabic Reports chart and table printed "35.91-" and "⃁ 35.91-"
    /// (alpha.51 review). The figure is wrapped in a LEFT-TO-RIGHT ISOLATE
    /// (U+2066 … U+2069): inside it the minus sits before the digits in any
    /// paragraph, and outside it the figure is one unit, so the currency mark
    /// still falls where the language puts it. Invisible in English.
    ///
    /// Only negatives. A positive figure has no neutral to move, and leaving it
    /// bare keeps every string a test or a pasteboard compares unchanged.
    static func held(_ figure: String) -> String {
        figure.hasPrefix("-") || figure.hasPrefix("\u{2212}") ? "\u{2066}" + figure + "\u{2069}" : figure
    }

    /// A quantity that is NOT money — grams, hours, millilitres.
    ///
    /// Here rather than in the screen that wanted it, because the one thing it
    /// has to get right is the digits rule above: Western figures, whatever
    /// language the app is in. A formatter built next to the view that uses it
    /// is a formatter that will one day be built with `Locale.current` and
    /// write Arabic-Indic grams on an Arabic screen, which nothing in Khayt
    /// does outside an invoice a shop asked for.
    ///
    /// Two decimals is a money habit and wrong here: nobody weighs a spool to
    /// the centigram, and `559.10 g` asks a reader to skip four digits to find
    /// the two that matter.
    static func quantity(_ value: Double, decimals: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = digits
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        let value = unsignedZero(value, decimals: decimals)
        return held(f.string(from: value as NSNumber) ?? "\(value)")
    }

    static func text(_ amount: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = digits
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let amount = unsignedZero(amount, decimals: 2)
        let n = held(f.string(from: amount as NSNumber) ?? "\(amount)")
        return "\(n) \(mark(currency))"
    }

    /// A COST LINE in Reports, written the way it acts on the net: negative.
    ///
    /// ── ONE CONVENTION, NOT TWO ──────────────────────────────────────────
    ///
    /// The alpha.51 review found "Cost of goods sold -35.91" in the P&L table
    /// and "35.91" for the same figure in the side panel beside it. The
    /// waterfall already draws a cost as a signed step down, and the table
    /// already signed it, so the panel follows them: every cost line on the
    /// Reports screen goes through here and reads negative. `amount` is the
    /// cost as the rule reports it (positive); zero stays an unsigned zero.
    static func cost(_ amount: Double, _ currency: String) -> String {
        text(-amount, currency)
    }

    /// Just the figure, for columns where the currency is stated once at the top
    /// rather than repeated on all forty rows.
    static func figure(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = digits
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let amount = unsignedZero(amount, decimals: 2)
        return held(f.string(from: amount as NSNumber) ?? "\(amount)")
    }

    /// Grams, as a shop says them: whole numbers, and a half when there is one.
    ///
    /// For anything on a shelf prefer `Quantity.say`, which asks the item what
    /// it is counted in. This stays for the figures that genuinely ARE grams
    /// whatever the shop stocks: a nozzle's wear, and the filament weight a
    /// slicer wrote into a 3MF.
    /// `figure` is for money and always shows two decimals, which turned a
    /// 180g failure into "180.00 grams".
    static func grams(_ n: Double) -> String { quantity(n) }

    /// A figure a shop reads as a QUANTITY rather than as money: hours,
    /// grams, a percentage. Whole where it is whole, and a half when there is
    /// one.
    ///
    /// Separate from `figure` for the reason that comment gives — two forced
    /// decimals turned a 180 g failure into "180.00 grams" — and named for the
    /// kind of number rather than for grams, because hours and percentages
    /// want exactly the same treatment and a second copy of this formatter is
    /// a second chance to get the locale wrong.
    static func quantity(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = digits
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        let n = unsignedZero(n, decimals: 1)
        return held(f.string(from: n as NSNumber) ?? "\(n)")
    }

    /// A figure on its way INTO a text field, not onto a screen.
    ///
    /// ── WHY THIS IS NOT `quantity` ────────────────────────────────────────
    ///
    /// `quantity` is a display formatter: it groups thousands and rounds to one
    /// decimal, both of which are right for a label and wrong for a field
    /// somebody is about to edit and the app is about to parse back with
    /// `Double(_:)`.
    ///
    /// Rounding loses the shop's figures — a part recorded at 140.91 g came
    /// into the editor as "140.9" and was saved back at 140.9.
    ///
    /// The grouping is worse, and it is the bug this was found by. At a
    /// thousand and over, `quantity` writes "1,234.6" — and `Double("1,234.6")`
    /// is **nil**. So every part weighing a kilo or more read back as nothing:
    /// the part looked incomplete, nothing was costed, and a job taken from a
    /// product the catalogue prices at 3,250 opened priced at zero, with no
    /// error anywhere. A shop's biggest prints are exactly the ones over a kilo.
    ///
    /// So: no grouping, no lost precision, and an empty field — not "0" — for a
    /// figure the book has never been told.
    static func fieldValue(_ amount: Double?) -> String {
        guard let amount else { return "" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = digits
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        // Enough to hold anything a slicer writes. Four, not "as many as it
        // takes", so a double's binary tail does not surface as 140.90999999.
        f.maximumFractionDigits = 4
        return f.string(from: amount as NSNumber) ?? "\(amount)"
    }

    /// Money with the small change rubbed off, for a dashboard tile.
    ///
    /// A tile is read at a glance; "52,691.57 SAR" at 24pt either wraps or
    /// shrinks to unreadable, and the last two digits are not what anyone is
    /// looking at from across a workshop. The exact figure is a column away on
    /// the jobs shelf.
    static func short(_ amount: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = digits
        // Both bounds, or a tidy figure loses its trailing zero and sits next
        // to one that kept it: "839.3 SAR" beside "1,243.08 SAR".
        let places = amount >= 10_000 ? 0 : 2
        f.maximumFractionDigits = places
        f.minimumFractionDigits = places
        let n = held(f.string(from: amount as NSNumber) ?? "\(amount)")
        return "\(n) \(mark(currency))"
    }
}

extension View {
    /// Right-aligned, monospaced-digit money.
    func moneyStyle() -> some View {
        self.monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A quantity on a shelf, said in the unit the item is actually counted in.
///
/// ── ONE UNIT WAS THE ONLY UNIT ────────────────────────────────────────────
///
/// Every quantity in this app was written `"\(Int(x)) \(callIt("common.grams"))"`,
/// because grams were the only thing anything could be recorded in. A bottle of
/// resin then said "500 g" and a stack of plywood said "6 g".
///
/// The number of decimals is the unit's, not this file's: half a sheet is a
/// real thing to have left and half a gram is not.
enum Quantity {
    @MainActor
    static func say(_ amount: Double, _ unit: KhaytEngine.InventoryUnit?, _ words: Words) -> String {
        let places = unit?.decimals ?? 0
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = places
        let n = f.string(from: amount as NSNumber) ?? "\(amount)"
        // `common.grams` is where Khayt already keeps the gram, and it is `غ`
        // in Arabic — a `g` written here would be an English letter in an
        // Arabic list. The other units are this app's own.
        let word = words.callIt(unit?.unitKey ?? "common.grams")
        return "\(n) \(word)"
    }
}

extension Double {
    /// Rounded the way a figure on screen is rounded.
    ///
    /// So that arithmetic done on displayed values agrees with the values
    /// displayed: four buckets each rounded to the halala summed to 95.37 while
    /// the cost — the unrounded total, rounded once — printed 95.36, and a shop
    /// adding the row by eye got a different answer from the one beside it.
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}
