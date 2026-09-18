import XCTest
import KhaytCore

/**
 * The shop's arithmetic, running on the phone.
 *
 * This is the test that the whole shared-core arrangement rests on, and it is
 * deliberately not a mock: it starts the real `KhaytEngine`, which loads the
 * real `lib/tax.js` into JavaScriptCore, and asks it the same question the Mac
 * asks. The number it must come back with is Node's, copied from
 * `KhaytTax.computeTax(1000, KhaytTax.profileFromSettings({enableVat:true,
 * vatRate:15}))` — 869.57 and 130.43.
 *
 * Why it is worth a test of its own. The companion has never computed anything.
 * Every figure on its screens came down the wire from the desktop, so "the
 * phone's tax" did not exist to be wrong. The moment the phone is expected to
 * work without the desktop, that changes, and there are exactly two ways to go:
 * run the shop's own engine, or write a second one in Swift. A second one would
 * earn the right to be wrong in a second, different way — and to be fixed twice
 * forever after. This proves the first way works on iOS, so nobody has to be
 * tempted by the second.
 *
 * If this ever fails to LOAD rather than to match, suspect the resource bundle:
 * the JS is a SwiftPM resource, and it has to be copied into whichever bundle
 * is running — not the Mac app's.
 */
final class EngineOnThePhoneTests: XCTestCase {

    func testTheShopsOwnTaxEngineRunsOnThisDevice() async throws {
        let engine = try KhaytEngine()

        // A Saudi shop registered for VAT, which is the common case and the one
        // whose rounding is easiest to get wrong by hand: 15% INCLUSIVE means
        // the 1000 is what the customer pays, not what the shop keeps.
        let profile = try await engine.taxProfile(settings: [
            "enableVat": .bool(true),
            "vatRate": .number(15),
        ])
        XCTAssertEqual(profile.mode, .inclusive)
        XCTAssertEqual(profile.totalPercent, 15)

        let split = try await engine.computeTax(1000, profile: profile)

        // Node's answers, to the halala. Not recomputed here — copied, because
        // a second computation in the test is a second implementation with the
        // same right to be wrong.
        XCTAssertEqual(split.subtotal, 869.57, accuracy: 0.0001,
                       "the phone and Node disagree about what the shop keeps")
        XCTAssertEqual(split.taxTotal, 130.43, accuracy: 0.0001,
                       "the phone and Node disagree about what the taxman gets")

        // And the property that makes it money rather than two numbers.
        XCTAssertEqual(split.subtotal + split.taxTotal, 1000, accuracy: 0.0001,
                       "inclusive tax must add back up to the price on the label")
    }
}
