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
        // What is owed, to the halalah.
        //
        // It was 52,691.57 for as long as no sample job had a payment plan.
        // ORD-01011 has one now — three payments covering its balance, the
        // first of them collected — so the book holds 2,269.18 more cash and
        // owes exactly that much less. The plan is there so the payment-plan
        // sheet can be looked at with rows on it; see `SampleShopTests`.
        //
        // The figure still belongs here: what this suite guards is that
        // MEASURED ACTUALS move no money, and a deliberate change to the book
        // is not that. It moves when somebody means it to and says so.
        #expect(abs(shop.owed - 50_422.39) < 0.005, "owed is \(shop.owed)")

        let facts = try #require(shop.facts, "the dashboard computed nothing")
        #expect(facts.activeCount == 11, "open is \(facts.activeCount)")

        // ── LATE IS A FUNCTION OF TODAY, AND IS PINNED AGAIN ──────────────
        //
        // This read `lateCount == 6` and passed for as long as it did only
        // because nobody ran it on the wrong day: the sample's due dates were
        // ABSOLUTE, so a job crossed into late every time the calendar moved
        // and the figure went to 9 the morning after this was last green. It
        // was loosened to `>= 6` then, because a test that fails on a date is
        // a test that will be edited to whatever today says.
        //
        // `SampleBook` moves the whole book with the calendar now, so six is
        // six on any day the app is opened — see `SampleBookAgesTests`, which
        // proves it a thousand days out. The figure goes back to being pinned,
        // which is what it was always for: the attention panel is sized for
        // six, and a sample that quietly gains a seventh or loses one changes
        // a screen nobody would think to look at.
        #expect(facts.lateCount == 6, Comment(rawValue:
            "the sample carries \(facts.lateCount) overdue jobs, not the six the "
            + "attention panel is drawn for"))
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
