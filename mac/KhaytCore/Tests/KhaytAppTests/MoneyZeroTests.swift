import Foundation
import Testing
@testable import KhaytApp

/// The P&L chart labelled an empty expenses bar "−0.00": `-row.expenses` on a
/// quarter that spent nothing is −0.0, and a number formatter keeps its sign.
struct MoneyZeroTests {
    @Test("nothing prints as a signed zero")
    func noSignedZero() {
        #expect(Money.figure(-0.0) == "0.00")
        #expect(Money.figure(-0.001) == "0.00")
        #expect(Money.text(-0.0, "SAR").hasPrefix("0.00"))
        #expect(Money.quantity(-0.0) == "0")
        #expect(Money.quantity(-0.04, decimals: 1) == "0.0")
        // A real negative keeps its sign.
        #expect(Money.figure(-12.5) == "-12.50")
    }
}
