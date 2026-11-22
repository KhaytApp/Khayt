import SwiftUI

/// Money on screen.
///
/// The companion wrote "SAR" beside a figure in three places and had no idea
/// what the shop it was paired to actually charged in. That is not a bug for
/// the shop that wrote it and is wrong every time for everybody else — the
/// same mistake the desktop's public intake form made until it was handed the
/// shop's currency, and the phone was the last surface still making it.
///
/// The rule and the reasoning are the Mac app's `KhaytApp/Money.swift`, which
/// is the app this one is a companion to. Kept as a separate file rather than
/// shared because the two targets share no code and never have: what must not
/// diverge is the DECISION — ask the font, fall back to the code — not the
/// lines.
enum Money {

    // MARK: - The mark a currency is written with

    /// The official Saudi Riyal sign, U+20C1.
    ///
    /// NOT U+20C0, which is the codepoint everyone reaches for and which draws
    /// an empty box — measured as tofu on both a Mac and an iPhone.
    private static let riyal = "\u{20C1}"

    /// Does the face this phone draws with actually have it?
    ///
    /// ── ASKED, NOT ASSUMED ────────────────────────────────────────────────
    ///
    /// The mark was adopted in 2025 and the glyph arrived with a system font
    /// after it. This app deploys to iOS versions older than that, and a shop
    /// whose prices are empty boxes is worse served than one reading "SAR",
    /// which is what it read yesterday and is not wrong, only older.
    ///
    /// So the question is put to CoreText once, on the face the app draws in.
    /// No `#available` check on purpose: what matters is whether the glyph
    /// exists, and a font can arrive in a point release no version check knows
    /// about.
    static let drawsTheRiyal: Bool = {
        let font = UIFont.preferredFont(forTextStyle: .body)
        var chars = Array(riyal.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        let ok = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        return ok && glyphs.allSatisfy { $0 != 0 }
    }()

    /// How to write this currency: its own mark where there is one, its code
    /// otherwise. Every other currency keeps its code, which is what stops the
    /// one symbol this shop uses becoming an assumption about the rest.
    static func mark(_ currency: String) -> String {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.uppercased() == "SAR" && drawsTheRiyal ? riyal : code
    }

    /// An amount, written the way the paired shop writes it.
    ///
    /// A SHOP THAT HAS NOT SET A CURRENCY GETS THE FIGURE ALONE. The desktop
    /// takes the same line on its intake form: a bare number is honest, and a
    /// currency the app invented is not.
    static func text(_ amount: Double, _ currency: String?, places: Int = 2) -> String {
        let n = figure(amount, places: places)
        let m = mark(currency ?? "")
        return m.isEmpty ? n : "\(n) \(m)"
    }

    /// Just the figure — grouped, so a four-figure quote does not read as one
    /// long digit string, which `String(format: "%.2f")` gave it.
    ///
    /// ── WESTERN DIGITS, ON AN ARABIC PHONE TOO ────────────────────────────
    ///
    /// The locale is PINNED. A `NumberFormatter` left alone takes the system
    /// locale, and a shop phone set to العربية (السعودية) then renders every
    /// price as ١٢٣٤٫٥٠ with Arabic separators — including when the app's own
    /// language is English, because the digits do not come from the app's
    /// language at all.
    ///
    /// That is a leak, not a house style: codepoint scans of live Saudi
    /// products — Al Rajhi, SNB, Absher, Tawakkalna, Salla, STC, SAMA — find
    /// Western digits on essentially every financial figure. The desktop
    /// already ships this rule and guards it (`test/arabic-numerals.test.js`),
    /// and the one place Khayt does write Arabic-Indic digits is an invoice
    /// the shop explicitly asked for them on.
    /// `en_US`, and NOT the reflexive `en_US_POSIX`: the POSIX locale
    /// suppresses grouping entirely, so pinning to it swaps one problem for
    /// the other and gives back "1234567.89". `en_US` is Western digits with
    /// a comma every three, which is what the desktop draws.
    private static let formatterLocale = Locale(identifier: "en_US")

    static func figure(_ amount: Double, places: Int = 2) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = formatterLocale
        f.minimumFractionDigits = places
        f.maximumFractionDigits = places
        return f.string(from: amount as NSNumber) ?? String(format: "%.\(places)f", amount)
    }
}
