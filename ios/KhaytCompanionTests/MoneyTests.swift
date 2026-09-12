import XCTest
@testable import KhaytCompanion

/**
 * Money on screen.
 *
 * The companion wrote "SAR" beside a figure in three places without ever
 * asking the shop what it charged in. These pin the two decisions that fixed
 * it: an unknown currency is shown as nothing rather than invented, and the
 * riyal mark is used only when the font this phone draws with actually has
 * the glyph.
 */
final class MoneyTests: XCTestCase {

    func testAnUnknownCurrencyIsNotInvented() {
        // The whole bug in one assertion: a shop that has not told us gets its
        // figure and no currency, not a guess.
        XCTAssertEqual(Money.text(120, nil), "120.00")
        XCTAssertEqual(Money.text(120, ""), "120.00")
        XCTAssertEqual(Money.text(120, "   "), "120.00")
        XCTAssertEqual(Money.mark(""), "")
    }

    func testEveryOtherCurrencyKeepsItsCode() {
        // What stops the one symbol this shop uses becoming an assumption
        // about the rest.
        XCTAssertEqual(Money.mark("USD"), "USD")
        XCTAssertEqual(Money.mark("AED"), "AED")
        XCTAssertEqual(Money.text(1200.5, "USD"), "1,200.50 USD")
    }

    func testTheRiyalIsTheMarkOnlyWhenTheFontHasIt() {
        // The rule, either way round — never an empty box, never a mark the
        // face cannot draw. Which branch runs depends on the OS this test is
        // on, and both are correct answers.
        let mark = Money.mark("sar")
        if Money.drawsTheRiyal {
            XCTAssertEqual(mark, "\u{20C1}")
        } else {
            XCTAssertEqual(mark, "sar", "an unknown glyph must fall back to the code the shop gave")
        }
    }

    func testTheRiyalIsNeverTheOtherCodepoint() {
        // U+20C0 is the one everyone reaches for and it draws tofu on both a
        // Mac and an iPhone. If this ever passes, someone has changed the sign.
        XCTAssertFalse(Money.mark("SAR").unicodeScalars.contains(where: { $0.value == 0x20C0 }))
    }

    func testFiguresAreGrouped() {
        // `String(format: "%.2f")` gave a four-figure quote as one long digit
        // string. A shop reads money in thousands.
        XCTAssertEqual(Money.figure(1234.5), "1,234.50")
        XCTAssertEqual(Money.figure(1234567.89), "1,234,567.89")
        XCTAssertEqual(Money.figure(9.5), "9.50", "no separator where there is nothing to separate")
    }

    func testTheDigitsAreWesternWhateverTheDeviceIsSetTo() {
        /* THE LEAK THIS GUARDS. A `NumberFormatter` left alone takes the
         * system locale, so a shop phone set to العربية (السعودية) renders
         * ١٬٢٣٤٫٥٠ — even with the app's own language in English, because the
         * digits never came from the app's language.
         *
         * Saudi products ship Western figures; the desktop already guards
         * this in test/arabic-numerals.test.js. The formatter's locale is
         * pinned, so setting the process locale must change nothing here. */
        let arabicIndic = CharacterSet(charactersIn: "\u{0660}\u{0661}\u{0662}\u{0663}\u{0664}"
            + "\u{0665}\u{0666}\u{0667}\u{0668}\u{0669}")
        let arabicSeparators = CharacterSet(charactersIn: "\u{066B}\u{066C}")
        for amount in [0, 7, 1000, 18_750, 1_234_567, 0.5] as [Double] {
            let out = Money.text(amount, "SAR")
            XCTAssertNil(out.rangeOfCharacter(from: arabicIndic), "\(amount) rendered as \(out)")
            XCTAssertNil(out.rangeOfCharacter(from: arabicSeparators), "\(amount) rendered as \(out)")
        }
    }

    func testTheFigureRoundsTheWayTheMacApExpects() {
        // NumberFormatter's default is half-even, and the Mac app's Money uses
        // the same default. A shop reading the same job on both must not see
        // two different figures — so this is pinned rather than "fixed" into
        // divergence.
        XCTAssertEqual(Money.figure(1234.5, places: 0), "1,234")
        XCTAssertEqual(Money.figure(1235.5, places: 0), "1,236")
    }

    func testARoughEstimateDropsTheDecimals() {
        // The intake list shows "~120 SAR", not "~120.00 SAR" — it is a guess
        // and should not be dressed up as a price.
        let rough = Money.text(120.4, "USD", places: 0)
        XCTAssertEqual(rough, "120 USD")
    }
}
