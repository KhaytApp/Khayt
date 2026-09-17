import Foundation

/// What a shop spends, grouped by what it spent it on — ported to Swift.
///
/// ── THE TAX ON A PURCHASE IS NOT A COST ───────────────────────────────────
///
/// For a registered shop it is reclaimed from the authority, so it belongs
/// against the tax collected on sales and not in what a category cost. The P&L
/// has always known that — it charges `paid - claimable` — and the category
/// chart did not: it summed the gross amount. So the two disagreed by the whole
/// of the reclaimable tax, which at the Saudi rate is 15% of every category
/// with a receipt, and a shop reading its expenses by category and then its P&L
/// saw two different totals for the same money.
///
/// The reclaim rule is the same one in the same words: `vatAmount` is what the
/// supplier's invoice says; an expense without the field reclaims nothing, so
/// nothing about an older book changes; and a shop that is not registered
/// reclaims nothing at all, which is most shops.
public enum ExpenseCategories {

    public struct Row: Sendable, Equatable {
        public var category: String
        public var amount: Double
        public var reclaimed: Double
        public var share: Double
    }

    public struct Spending: Sendable, Equatable {
        public var rows: [Row]
        public var total: Double
        public var reclaimed: Double
        public var biggest: Double
    }

    public static func byCategory(_ expenses: [JSONValue], reclaimsTax: Bool) -> Spending {
        // A dictionary would lose the order categories were first seen in, and
        // that order is load-bearing: the sort below is JavaScript's, which is
        // STABLE, so two categories that came to the same amount come out in
        // the order the book lists them. Swift's `sorted` promises nothing of
        // the kind, so the position is carried explicitly.
        var order: [String] = []
        var totals: [String: Row] = [:]
        var reclaimedAll = 0.0

        for entry in expenses {
            guard case .object(let e) = entry else {
                // `if (!e) continue` — and every object is truthy, so only a
                // falsy entry is skipped. A row that is a string or a number
                // is truthy and contributes an `amount` of NaN → 0 under
                // `other`, which is what the original does.
                if !JSSemantics.truthy(entry) { continue }
                let key = "other"
                if totals[key] == nil {
                    order.append(key)
                    totals[key] = Row(category: key, amount: 0, reclaimed: 0, share: 0)
                }
                continue
            }
            let paid = number(e["amount"])
            // Never more than was paid: a receipt claiming more tax than total
            // is a typo, and a negative category is worse than a wrong one.
            let claimable = reclaimsTax
                ? Swift.min(paid, Swift.max(0, number(e["vatAmount"])))
                : 0
            // `other` is the bucket the editor itself falls back to — and it is
            // `e.category || 'other'`, so an empty string lands there too.
            let key = JSSemantics.truthy(e["category"]) ? JSSemantics.text(e["category"]) : "other"
            if totals[key] == nil {
                order.append(key)
                totals[key] = Row(category: key, amount: 0, reclaimed: 0, share: 0)
            }
            totals[key]?.amount += paid - claimable
            totals[key]?.reclaimed += claimable
            reclaimedAll += claimable
        }

        var rows = order.compactMap { totals[$0] }
        rows = stableSortedDescending(rows)
        let total = rows.reduce(0.0) { $0 + $1.amount }
        // The chart's own denominator: `total || 1`. The `|| 1` is there so a
        // book that nets to nothing divides by one instead of by zero — a shop
        // whose only expense was entirely reclaimable is a real case, not an
        // error. A book that nets NEGATIVE keeps its sign.
        let denominator = (total == 0 || total.isNaN) ? 1 : total
        for i in rows.indices { rows[i].share = rows[i].amount / denominator }
        return Spending(rows: rows, total: total, reclaimed: reclaimedAll,
                        biggest: rows.first?.amount ?? 0)
    }

    /// `rows.sort((a, b) => b.amount - a.amount)`, kept stable.
    ///
    /// Two things the obvious Swift spelling gets wrong. It is not stable, so
    /// equal amounts would come out in an arbitrary order and the chart's rows
    /// would shuffle between two apps looking at one book. And a NaN amount
    /// makes the comparator return NaN, which JavaScript treats as "leave
    /// them"; `sorted(by:)` given an inconsistent predicate can trap outright.
    private static func stableSortedDescending(_ rows: [Row]) -> [Row] {
        rows.enumerated().sorted { lhs, rhs in
            let a = lhs.element.amount, b = rhs.element.amount
            guard a.isFinite, b.isFinite, a != b else { return lhs.offset < rhs.offset }
            return b < a
        }.map(\.element)
    }

    /// The module's own `num`: finite or zero, through JavaScript's coercion.
    private static func number(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }
}
