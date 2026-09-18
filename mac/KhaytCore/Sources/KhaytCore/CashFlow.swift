import Foundation

/// What actually came in, and what actually went out, month by month.
///
/// NOT the same question as the P&L. A quarter's net says what the shop EARNED;
/// this says what reached and left the bank. A shop can be profitable and
/// unable to pay the rent, and that gap is the whole reason this exists — so it
/// is counted on the day money MOVED, never on the day a job finished.
///
/// ── THREE THINGS THE VERSION THIS REPLACED GOT WRONG ──────────────────────
///
/// 1. It counted a job's whole revenue on the day of its FIRST payment.
///    `paidAt` is set on any payment, a deposit included, so a 10% deposit in
///    June on a 20,000 job put 20,000 of "cash in" into June — money the shop
///    had not received, on the one chart whose entire subject is money it has.
/// 2. It counted voided orders, on a screen where every neighbouring figure
///    excludes them.
/// 3. It ignored the business scope, so a job marked as not the shop's trade
///    still moved the line.
public enum CashFlow {

    public struct Month: Sendable, Equatable, Identifiable {
        /// `YYYY-MM`.
        public let month: String
        public let collected: Double
        public let paidOut: Double
        public let net: Double
        public var id: String { month }
    }

    public struct Totals: Sendable, Equatable {
        public let collected: Double
        public let paidOut: Double
        public let net: Double
        /// Whether there is anything to draw at all. A chart of six empty
        /// months is not a chart, and a caller needs to tell that apart from
        /// six months that genuinely netted nothing.
        public let anyMovement: Bool
        /// Collected money that carries no payment date, so no month can hold
        /// it. NOT part of `collected` or `net` — those are what the timeline
        /// shows, and adding an unplaceable figure to them would make the
        /// columns disagree with the total printed under them.
        public let undated: Double
    }

    public struct Report: Sendable, Equatable {
        public let rows: [Month]
        public let totals: Totals
    }

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    /// The `YYYY-MM` a stored date falls in — the first seven UTF-16 units of
    /// it, and nothing at all if it is shorter than that. No clock and no
    /// parsing, so a timezone cannot move a month.
    public static func monthOf(_ value: JSONValue?) -> String {
        let units = Array(JSSemantics.text(value).utf16)
        guard units.count >= 7 else { return "" }
        return String(decoding: units.prefix(7), as: UTF16.self)
    }

    /// The `count` months ending at `endMonth`, oldest first.
    public static func monthsEnding(_ endMonth: String, count: Double) -> [String] {
        guard endMonth.range(of: "^[0-9]{4}-[0-9]{2}$", options: .regularExpression) != nil
        else { return [] }
        var year = Int(endMonth.prefix(4)) ?? 0
        var month = Int(endMonth.suffix(2)) ?? 0
        var out: [String] = []
        // `i < Math.max(0, count)` — a count that is not a number runs zero
        // times, because every comparison with NaN is false.
        guard count.isFinite else { return [] }
        var i = 0.0
        while i < Swift.max(0, count) {
            out.insert("\(year)-" + (month < 10 ? "0\(month)" : "\(month)"), at: 0)
            month -= 1
            if month == 0 { month = 12; year -= 1 }
            i += 1
        }
        return out
    }

    /// `revenueOf` is per order and comes from `order-money`, which still lives
    /// in JavaScript; the caller works it out once and hands it in, aligned
    /// with `orders`.
    public static func report(orders: [JSONValue], revenues: [Double],
                              expenses: [JSONValue], endMonth: String,
                              months: Double = 6,
                              countsForBusiness: (JSONValue) -> Bool = {
                                  BusinessScope.countsForBusiness($0)
                              }) -> Report {
        let wanted = monthsEnding(endMonth, count: months)
        var collected: [String: Double] = [:], paidOut: [String: Double] = [:]
        for month in wanted { collected[month] = 0; paidOut[month] = 0 }

        // MONEY THAT WAS PAID ON A DAY NOBODY RECORDED. `paidAt` was added
        // after Khayt had been in use, so older orders carry a `paidAmount` and
        // no date and a timeline cannot place them. Leaving them out SILENTLY
        // is the one thing that must not happen: a shop paid thirty times would
        // read "collected nothing" and believe it.
        var undated = 0.0

        for (index, order) in orders.enumerated() {
            guard JSSemantics.truthy(order), case .object(let o) = order,
                  !JSSemantics.truthy(o["voidedAt"]),
                  countsForBusiness(order) else { continue }

            // THE SHARE ACTUALLY PAID, not the whole job. `revenueOf` owns the
            // tax and the currency; scaling its answer keeps both rules where
            // they are rather than re-deriving either here.
            let price = num(o["price"])
            let paid = Swift.min(num(o["paidAmount"]), price)
            guard paid > 0 else { continue }
            let share = price > 0 ? paid / price : 0
            let amount = (index < revenues.count ? revenues[index] : 0) * share

            guard JSSemantics.truthy(o["paidAt"]) else { undated += amount; continue }
            let month = monthOf(o["paidAt"])
            guard collected[month] != nil else { continue }
            collected[month]! += amount
        }

        for expense in expenses {
            guard JSSemantics.truthy(expense), case .object(let e) = expense else { continue }
            let month = monthOf(e["date"])
            guard paidOut[month] != nil else { continue }
            paidOut[month]! += num(e["amount"])
        }

        let rows = wanted.map { month in
            Month(month: month, collected: collected[month] ?? 0, paidOut: paidOut[month] ?? 0,
                  net: (collected[month] ?? 0) - (paidOut[month] ?? 0))
        }
        return Report(rows: rows, totals: Totals(
            collected: rows.reduce(0) { $0 + $1.collected },
            paidOut: rows.reduce(0) { $0 + $1.paidOut },
            net: rows.reduce(0) { $0 + $1.net },
            anyMovement: rows.contains { $0.collected != 0 || $0.paidOut != 0 },
            undated: undated))
    }
}
