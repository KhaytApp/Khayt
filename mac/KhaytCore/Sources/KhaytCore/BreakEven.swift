import Foundation

/// What a shop has to bill in a month to cover the costs it pays anyway.
///
/// Rent, a subscription, the accountant — money that goes out whether or not a
/// single print is sold. Break-even revenue is that total divided by the share
/// of each riyal billed that is left after the work itself is paid for.
///
/// ── THE CORRECTION THIS CARRIES ───────────────────────────────────────────
///
/// The version this replaced, inline in the other app's analytics screen,
/// costed a job by looking up each part's spool and pricing its grams — and
/// SKIPPED any part with no spool linked. A part not linked to one therefore
/// cost nothing, so the margin came out too high and the break-even target too
/// LOW. A shop was told it needed to bill less than it does, which is the wrong
/// direction for a figure whose whole job is to be a floor.
public enum BreakEven {

    public struct Cost: Sendable, Equatable, Identifiable, Hashable {
        public let name: String
        public let amount: Double
        public var id: String { name }
    }

    public struct Report: Sendable, Equatable {
        public let totalFixed: Double
        /// Nil when there is nothing to work it out from — which is NOT zero.
        /// Zero would render as "you can never break even", a statement about
        /// the shop rather than about the absence of data.
        public let breakEvenRevenue: Double?
        public let marginPct: Double?
        public let avgRevenuePerJob: Double?
        public let jobsCounted: Int
        public let billedThisMonth: Double
        public let surplus: Double?
        public let progressPct: Double?
        public let costs: [Cost]
    }

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    /// A `YYYY-MM-DD` day, from whatever was stored — the first ten UTF-16
    /// units of it, with no parsing and no clock.
    static func day(_ value: JSONValue?) -> String {
        String(decoding: Array(JSSemantics.text(value).utf16.prefix(10)), as: UTF16.self)
    }

    /// `revenues` and `partCosts` are the caller's, in order: `order-money` and
    /// `calculator-cost` still live in JavaScript, and the two functions the
    /// original takes cannot cross the bridge. `partCosts[i]` is the cost of
    /// every part on `completed[i]` added up.
    public static func report(fixedCosts: [JSONValue], completed: [JSONValue],
                              revenues: [Double], partCosts: [Double],
                              since: String, month: String) -> Report {
        let costs: [Cost] = fixedCosts.compactMap { row in
            guard case .object(let c) = row else { return nil }
            // `c && (c.name || c.amount)` — a row with neither is not a cost,
            // but a row named with no amount is (it is one the shop has not
            // filled in yet, and hiding it would hide the gap).
            guard JSSemantics.truthy(c["name"]) || JSSemantics.truthy(c["amount"])
            else { return nil }
            return Cost(name: JSSemantics.truthy(c["name"]) ? JSSemantics.text(c["name"]) : "",
                        amount: num(c["amount"]))
        }
        let totalFixed = costs.reduce(0) { $0 + $1.amount }

        let since = day(.string(since))
        let month = String(decoding: Array(month.utf16.prefix(7)), as: UTF16.self)

        // THE CALLER'S FIGURES GO THROUGH `num` TOO. The original wraps every
        // `revenueOf(o)` and `partCostOf(p)` in it, so a job whose price is
        // missing contributes ZERO rather than making the whole panel NaN.
        // Taking the numbers pre-computed does not move that guard to the
        // caller — the harness caught this one adding NaN into the revenue and
        // answering "no target" for a shop that had one.
        func figure(_ list: [Double], _ i: Int) -> Double {
            guard i < list.count, list[i].isFinite else { return 0 }
            return list[i]
        }

        var billedThisMonth = 0.0
        if !month.isEmpty {
            for (i, order) in completed.enumerated() where day(orderDate(order)).hasPrefix(month) {
                billedThisMonth += figure(revenues, i)
            }
        }

        // `day(o.date) >= since` — a string comparison, like the original.
        let recent: [Int] = since.isEmpty
            ? Array(completed.indices)
            : completed.indices.filter { !less(day(orderDate(completed[$0])), since) }

        guard !recent.isEmpty else {
            return Report(totalFixed: totalFixed, breakEvenRevenue: nil, marginPct: nil,
                          avgRevenuePerJob: nil, jobsCounted: 0,
                          billedThisMonth: billedThisMonth, surplus: nil,
                          progressPct: nil, costs: costs)
        }

        var revenue = 0.0, cost = 0.0
        for i in recent {
            revenue += figure(revenues, i)
            cost += figure(partCosts, i)
        }

        let avgRevenuePerJob = revenue / Double(recent.count)
        // Clamped at zero: a window where the work cost more than it earned has
        // no break-even point, and a negative margin would produce a negative
        // target — a number that reads as "bill less to break even".
        let marginPct = revenue > 0 ? Swift.max(0, (revenue - cost) / revenue) : 0
        let breakEvenRevenue: Double? = (marginPct > 0 && totalFixed > 0)
            ? totalFixed / marginPct : nil

        let surplus = breakEvenRevenue.map { billedThisMonth - $0 }
        let progressPct: Double? = {
            guard let target = breakEvenRevenue, target > 0 else { return nil }
            return Swift.max(0, Swift.min(100, (billedThisMonth / target) * 100))
        }()

        return Report(totalFixed: totalFixed, breakEvenRevenue: breakEvenRevenue,
                      marginPct: marginPct, avgRevenuePerJob: avgRevenuePerJob,
                      jobsCounted: recent.count, billedThisMonth: billedThisMonth,
                      surplus: surplus, progressPct: progressPct, costs: costs)
    }

    /// `o && o.date` — a row that is not an object has no date and sorts as the
    /// empty string, which is before every real one.
    private static func orderDate(_ order: JSONValue) -> JSONValue? {
        guard case .object(let o) = order else { return nil }
        return o["date"]
    }

    /// `a < b` on two JavaScript strings: UTF-16 code units, not Swift's
    /// canonical ordering. A date is ASCII and the two agree, but the rule is
    /// what it is.
    static func less(_ a: String, _ b: String) -> Bool {
        var l = a.utf16.makeIterator(), r = b.utf16.makeIterator()
        while true {
            switch (l.next(), r.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?): if x != y { return x < y }
            }
        }
    }
}
