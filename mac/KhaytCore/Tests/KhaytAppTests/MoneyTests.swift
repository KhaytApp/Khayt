import Foundation
import Testing
@testable import KhaytApp

/// How figures are written on screen.
///
/// Four formatters, and the one thing that keeps going wrong is using the money
/// one for something that is not money. `figure` always shows two decimals,
/// which is correct for a price and wrong for anything a shop weighs: it turned
/// a 180g failure into "180.00 grams" once, and was still printing a part as
/// "129.18 g" in the job inspector afterwards. Two decimals of a gram is a
/// precision no filament scale has.
@MainActor
struct MoneyTests {

    @Test("money always shows its small change")
    func moneyKeepsTwoPlaces() {
        #expect(Money.figure(50) == "50.00")
        #expect(Money.figure(46.694) == "46.69")
        // The MARK is whatever this Mac can draw — U+20C1 where the font has
        // it, "SAR" where it does not — and that is `CurrencyMarkTests`'
        // business. What this line is about is the two decimal places, so it
        // asks for the token rather than pinning one and failing on half the
        // Macs in the world.
        #expect(Money.text(575, "SAR") == "575.00 \(Money.mark("SAR"))")
    }

    /// The distinction this file exists for.
    @Test("grams are not money")
    func gramsAreNotMoney() {
        // The part that started it: 129.18 g on the job inspector.
        #expect(Money.grams(129.18) == "129.2")
        #expect(Money.figure(129.18) == "129.18", "which is why it was wrong")

        // A whole number stays whole. "180.0 grams" is as wrong as "180.00".
        #expect(Money.grams(180) == "180")
        #expect(Money.grams(0) == "0")
        // And a half is worth saying: spools are weighed to a tenth.
        #expect(Money.grams(12.5) == "12.5")
        #expect(Money.grams(12.44) == "12.4")
    }

    /// A tile is read across a workshop. The last two digits are not what
    /// anybody is looking at from there, but a tidy figure must not lose its
    /// trailing zero beside one that kept it.
    @Test("a dashboard tile rubs off the small change above ten thousand")
    func tilesRound() {
        let sar = Money.mark("SAR")
        #expect(Money.short(52_691.57, "SAR") == "52,692 \(sar)")
        #expect(Money.short(1_243.08, "SAR") == "1,243.08 \(sar)")
        #expect(Money.short(839.3, "SAR") == "839.30 \(sar)", "and keeps its zero")
    }

    /// Not a preference: this is why the columns line up.
    @Test("no formatter hands back an empty string for a real number")
    func nothingComesBackBlank() {
        for value in [0.0, 0.004, 1, 1_000_000, -5] {
            #expect(!Money.figure(value).isEmpty)
            #expect(!Money.grams(value).isEmpty)
            #expect(!Money.short(value, "SAR").isEmpty)
        }
    }
}
