import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The arithmetic a reader would do, and whether the screen supports it.
///
/// The P&L pane listed Revenue, Expenses AND VAT under one heading, so anybody
/// subtracting the three got a figure thousands short of the net income printed
/// above them. Both numbers were right. Net income is revenue LESS EXPENSES —
/// revenue is already net of the tax, because tax collected on a sale is money
/// held for ZATCA and never income — and the VAT line is what the shop owes,
/// beside the arithmetic rather than inside it.
///
/// A figure printed next to numbers it does not come from is a figure that
/// looks wrong, and the reader who notices trusts nothing else on the page.
@MainActor
struct PnlAddsUpTests {

    static func rows() async throws -> [PnlPeriod] {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        return try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: [:], now: Date(timeIntervalSince1970: 1_788_000_000.0))
    }

    @Test("net income is revenue less expenses, which is what the pane now shows")
    func theSumOnTheScreen() async throws {
        let rows = try await Self.rows()
        #expect(!rows.isEmpty, "no periods in the sample book")

        let revenue = rows.reduce(0) { $0 + $1.revenue }
        let costs = rows.reduce(0) { $0 + $1.expenses + $1.fixed }
        let net = rows.reduce(0) { $0 + $1.net }
        #expect(abs(revenue - costs - net) < 0.01,
                "working reads \(Money.figure(revenue)) minus \(Money.figure(costs)); hero says \(Money.figure(net))")
    }

    /// The trap, pinned. Subtracting the VAT line as well — which is what the
    /// pane invited before that line was ruled off from the other two — does
    /// NOT give net income, and would be thousands out on this book.
    @Test("subtracting the VAT line as well gives the wrong answer, which is why it is ruled off")
    func vatIsNotAThirdSubtraction() async throws {
        let rows = try await Self.rows()
        let revenue = rows.reduce(0) { $0 + $1.revenue }
        let costs = rows.reduce(0) { $0 + $1.expenses + $1.fixed }
        let vat = rows.reduce(0) { $0 + $1.vatCollected }
        let net = rows.reduce(0) { $0 + $1.net }

        #expect(vat > 0, "no VAT in the sample book, so this proves nothing")
        #expect(abs(revenue - costs - vat - net) > 0.01,
                "VAT would have to be a real subtraction for listing it flush with the others to be safe")
    }

    /// And the reason the whole thing is arranged this way: revenue is already
    /// net of tax, so the tax cannot be taken off twice.
    @Test("revenue is stated net of the tax collected on it")
    func revenueIsNet() async throws {
        let rows = try await Self.rows()
        for row in rows where row.vatCollected > 0 {
            #expect(row.revenue > 0)
            // What was charged is revenue plus the tax held for ZATCA, so the
            // tax is a strictly smaller figure than the revenue it sat inside.
            #expect(row.vatCollected < row.revenue,
                    "\(row.period): tax \(row.vatCollected) against revenue \(row.revenue)")
        }
    }
}

/// The calculator only exists filled in.
///
/// Empty it is two fields and a sentence; everything it is FOR — the cost, the
/// breakdown, what to charge — appears only once there is a weight or a time.
/// The snapshot runner had never put one there, so the highest-stakes screen in
/// the app had been photographed exactly once, in the state where it does
/// nothing. The first picture of it working showed two sections stacked under
/// the identical heading "What to charge".
@MainActor
struct CalculatorShowsItsWorkingTests {

    @Test("the four buckets add up to the cost, which is what the screen now says")
    func bucketsSumToCost() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let spool = try #require(shop.spools.first { shop.unit(of: $0)?.unit == "g" })

        // Through the shop, exactly as the screen does it — the arithmetic is
        // `lib/`'s and neither this test nor that screen may re-do it.
        let costed = try #require(await shop.costedPart(
            spoolId: spool.id, grams: 180, hours: 4.5, qty: 1, machineId: nil))
        let p = costed.parts
        let sum = p.material + p.machine + p.labor + p.buffer
        #expect(sum > 0, "nothing was costed, so the sum proves nothing")
        #expect(abs(sum - costed.cost) < 0.02,
                "the line under the buckets reads \(Money.figure(sum)) and the cost says \(Money.figure(costed.cost))")
    }

    /// Two sections cannot wear one heading. This is the guard for the bug the
    /// first photograph found.
    @Test("the pricing controls and the price have different headings")
    func noDuplicateHeading() async throws {
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        let ar = Words()
        await ar.load("ar", engine: try KhaytEngine())
        for w in [words, ar] {
            #expect(w.callIt("mac.calc_rates") != w.callIt("mac.calc_price"),
                    "both sections say '\(w.callIt("mac.calc_price"))'")
            #expect(w.callIt("mac.calc_rates") != "mac.calc_rates")
            #expect(w.callIt("mac.calc_breakdown_sum") != "mac.calc_breakdown_sum")
        }
    }
}
