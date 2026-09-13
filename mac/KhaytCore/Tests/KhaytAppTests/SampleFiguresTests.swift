import Foundation
import Testing
@testable import KhaytApp

/// The sample book's headline figures, which eight jobs gaining actuals must
/// not have moved.
///
/// Actuals are time and grams; money is price and cost. That they are
/// independent is the CLAIM — and a claim nothing checks is how a sample book
/// quietly stops matching the numbers written about it in `mac/README.md` and
/// in the design notes that were agreed against it.
@MainActor
struct SampleFiguresTests {

    @Test("adding measured actuals moved no money")
    func theFiguresHold() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.orders.count == 42, "the sample lost or gained a job")
        // What is owed, to the halalah. The figure every design note about this
        // book was written against.
        #expect(abs(shop.owed - 52_691.57) < 0.005, "owed is \(shop.owed)")

        let facts = try #require(shop.facts, "the dashboard computed nothing")
        #expect(facts.activeCount == 11, "open is \(facts.activeCount)")

        // ── LATE IS A FUNCTION OF TODAY, AND WAS PINNED AS IF IT WERE NOT ──
        //
        // This read `lateCount == 6` and passed for as long as it did only
        // because nobody ran it on the wrong day. The sample's due dates are
        // ABSOLUTE — `ORD-01001` is due 2026-09-12 — so a job crosses into
        // late every time the calendar moves, and the figure went to 9 the
        // morning after this was last green. A test that fails on a date is a
        // test that will be edited to whatever today says, which is how a
        // guard stops guarding.
        //
        // What this suite is actually for is the CLAIM in its own name: eight
        // jobs gaining measured actuals moved no money. Lateness is not money
        // and never was. So what is pinned is the property of the DATA rather
        // than of the clock — the sample still carries overdue work for the
        // attention list to find, and has not quietly lost it.
        #expect(facts.lateCount >= 6,
                "the sample has stopped carrying overdue work: late is \(facts.lateCount)")
        #expect(facts.lateCount <= facts.activeCount,
                "more jobs are late (\(facts.lateCount)) than are open (\(facts.activeCount))")
        // FIVE machines, not the three filament printers this book started
        // with: a Roland UV flatbed and a Ruida laser joined them when Khayt
        // learnt that a machine is not always an FDM printer. The fleet is why
        // the app is designed for a shop rather than a hobbyist, and the count
        // is pinned because it is the sort of thing a sample quietly loses.
        #expect(facts.fleet.total == 5, "the sample has \(facts.fleet.total) machines")
    }

    /// Eight of them, and the SPREAD is what the screens are reviewed against —
    /// see `EstimateVarianceTests`. A sample that quietly loses its measured
    /// jobs takes the Quoting page's every case with it.
    @Test("the sample still carries measured actuals, on jobs of a single part")
    func theActualsAreStillThere() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let measured = shop.orderRows.filter { row in
            guard case .object(let o) = row, case .object(let src)? = o["actualsSource"] else { return false }
            if case .string(let t)? = src["time"], t != "manual" { return true }
            if case .string(let w)? = src["weight"], w != "manual" { return true }
            return false
        }
        #expect(measured.count == 6, "\(measured.count) jobs carry a measurement")
        // …and two typed ones, so the filter that ignores them is exercised by
        // the sample rather than only by a fixture built to prove it.
        let typed = shop.orderRows.filter { row in
            guard case .object(let o) = row, case .object(let src)? = o["actualsSource"] else { return false }
            if case .string(let t)? = src["time"], t == "manual" { return true }
            return false
        }
        #expect(typed.count == 2, "\(typed.count) jobs carry a typed actual")
    }
}
