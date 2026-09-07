import SwiftUI

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
    /// after it. This package runs on macOS 14, where it is not there — and a
    /// shop whose prices are empty boxes is worse served than one reading
    /// "SAR", which is what it read yesterday and is not wrong, only older.
    ///
    /// So the question is put to CoreText once, on the face the app draws in,
    /// and the answer decides. There is no version check here on purpose: what
    /// matters is whether the glyph exists, and a font can arrive in a point
    /// release that no `if #available` knows about.
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

    static func text(_ amount: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let n = f.string(from: amount as NSNumber) ?? "\(amount)"
        return "\(n) \(mark(currency))"
    }

    /// Just the figure, for columns where the currency is stated once at the top
    /// rather than repeated on all forty rows.
    static func figure(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: amount as NSNumber) ?? "\(amount)"
    }

    /// Grams, as a shop says them: whole numbers, and a half when there is one.
    /// `figure` is for money and always shows two decimals, which turned a
    /// 180g failure into "180.00 grams".
    static func grams(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f.string(from: n as NSNumber) ?? "\(n)"
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
        // Both bounds, or a tidy figure loses its trailing zero and sits next
        // to one that kept it: "839.3 SAR" beside "1,243.08 SAR".
        let places = amount >= 10_000 ? 0 : 2
        f.maximumFractionDigits = places
        f.minimumFractionDigits = places
        let n = f.string(from: amount as NSNumber) ?? "\(amount)"
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
