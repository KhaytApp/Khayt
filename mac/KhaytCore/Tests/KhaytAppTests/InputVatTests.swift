import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// VAT collected and VAT to remit are not the same number, and the sample book
/// said they were.
///
/// A VAT-registered shop remits what it collected on sales LESS what it paid on
/// its own purchases. `lib/pnl-report.js` has computed that for a long time —
/// `vatReclaimable` off each expense's `vatAmount` — and not one of the nine
/// sample expenses carried the field. So the two columns on the P&L were
/// identical in every row of every screenshot ever taken, the reclaim rule was
/// exercised by nothing, and the "expenses net of reclaimable tax" figure
/// beside them was the gross figure wearing a different label.
///
/// A column where every row agrees is a column nobody has tested, and it looks
/// perfectly fine.
@MainActor
struct InputVatTests {

    static func rows() async throws -> [PnlPeriod] {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        return try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: [:], now: Date(timeIntervalSince1970: 1_788_000_000.0))
    }

    @Test("a quarter with purchases remits less than it collected")
    func theyDiffer() async throws {
        let rows = try await Self.rows()
        let withPurchases = rows.filter { $0.expenses > 0 }
        #expect(!withPurchases.isEmpty, "no quarter has expenses, so this proves nothing")
        #expect(withPurchases.contains { $0.vatDue < $0.vatCollected },
                "every quarter remits exactly what it collected, so the reclaim has never run")
    }

    /// The reclaim only ever reduces what is remitted.
    ///
    /// It may take it BELOW ZERO, and that is not a bug: a quarter in which a
    /// shop bought more than it billed is a quarter in which it paid more tax
    /// than it collected, and ZATCA refunds or carries that forward. The sample
    /// book does exactly this in Q3 — its net income is negative for the same
    /// reason — and an assertion that the figure cannot be negative was written
    /// here first and was simply wrong about how VAT works.
    @Test("the reclaim only ever reduces what is remitted")
    func onlyReduces() async throws {
        for row in try await Self.rows() {
            #expect(row.vatDue <= row.vatCollected + 0.01,
                    "\(row.period) remits MORE than it collected, so the reclaim added tax")
        }
    }

    /// And a quarter that spent more than it billed says so with a negative,
    /// rather than clamping to nought and quietly overstating what is owed.
    @Test("a refund position is reported as one")
    func refundIsNotClamped() async throws {
        let rows = try await Self.rows()
        let refund = rows.filter { $0.vatDue < 0 }
        #expect(!refund.isEmpty,
                "no quarter is in a refund position, so that case is undrawn")
        for row in refund {
            #expect(row.net < 0,
                    "\(row.period) reclaims more tax than it collected while making a profit, which wants explaining")
        }
    }

    /// And the case that must stay reachable: an unregistered supplier or an
    /// import carries no tax to reclaim. Two sample expenses have no
    /// `vatAmount` on purpose, and an old book has none at all.
    @Test("an expense with no tax line reclaims nothing")
    func silenceReclaimsNothing() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let none = shop.expenseRows.filter { row in
            guard case .object(let e) = row else { return false }
            return e["vatAmount"] == nil
        }
        #expect(!none.isEmpty,
                "every sample expense carries a tax line, so the reclaims-nothing path is unreachable")
    }
}
