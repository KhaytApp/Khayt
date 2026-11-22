import Foundation

/// How many quotes turn into work, and how much of the money does.
///
/// A shop quoting all day and winning a third of it has a different problem
/// from one winning nearly all of it and not quoting enough. No other screen
/// answers that — and the count alone does not either: ten small quotes won and
/// one large one lost is a very different month from the reverse.
///
/// ── WHAT THE VERSION THIS REPLACED GOT WRONG ──────────────────────────────
///
/// Its last step counted `completed` only. `delivered` is PAST completed in
/// Khayt's pipeline — it is where finished work ends up — so every job that
/// reached a customer fell out of the funnel's final step, and the conversion
/// rate it printed was systematically too low for every shop that marks work
/// delivered. It also counted a CANCELLED order as converted, and ignored the
/// business scope every other figure applies.
public enum QuoteFunnel {

    public static let finished = ["completed", "delivered"]
    public static let dead = ["cancelled"]

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    /// A stamp in milliseconds, or nil.
    ///
    /// A bare day is read as midnight **UTC** here — `s + 'T00:00:00Z'` — and
    /// that is deliberate rather than an oversight: this module measures
    /// DURATIONS between two stamps, and reading both ends in one fixed zone
    /// keeps a quote's age the same number wherever it is read. `cycle-time`
    /// reads its bare days LOCAL for the opposite reason: it buckets by month.
    static func timeOf(_ value: JSONValue?) -> Double? {
        let s = JSSemantics.text(value)
        guard !s.isEmpty else { return nil }
        let stamp = s.utf16.count == 10 ? s + "T00:00:00Z" : s
        guard let t = JSDate.parse(stamp), t.isFinite else { return nil }
        return t
    }

    /// The middle value, which a long tail of stale quotes cannot drag.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    public struct Step: Sendable, Equatable, Identifiable {
        /// `created`, `sent`, `accepted`, `converted`, `finished`.
        public let key: String
        public let count: Int
        public let value: Double
        public var id: String { key }
    }

    public struct Totals: Sendable, Equatable {
        /// BOTH RATES. Ten small quotes won and one large one lost is a very
        /// different month from the reverse, and a count cannot tell them apart.
        public let winRateByCount: Double?
        public let winRateByValue: Double?
        public let medianDaysToDecide: Double?
        public let openCount: Int
        public let openValue: Double
        public let oldestOpenDays: Int?
    }

    public struct Report: Sendable, Equatable {
        public let steps: [Step]
        public let totals: Totals
    }

    /// `prices` is the caller's, aligned with `orders` — what each is worth in
    /// the shop's base currency.
    public static func report(orders: [JSONValue], prices: [Double], now: Double,
                              countsForBusiness: (JSONValue) -> Bool = { _ in true })
        -> Report {
        func fields(_ i: Int) -> [String: JSONValue] {
            guard case .object(let o) = orders[i] else { return [:] }
            return o
        }
        func price(_ i: Int) -> Double {
            i < prices.count && prices[i].isFinite ? prices[i] : 0
        }
        func status(_ i: Int) -> String { JSSemantics.text(fields(i)["status"]) }

        let quoted = orders.indices.filter { i in
            let o = fields(i)
            guard JSSemantics.truthy(orders[i]), !JSSemantics.truthy(o["voidedAt"]),
                  countsForBusiness(orders[i]) else { return false }
            return status(i) == "quote" || JSSemantics.truthy(o["quoteSentAt"])
                || JSSemantics.truthy(o["quoteAcceptedAt"])
        }
        let sent = quoted.filter { JSSemantics.truthy(fields($0)["quoteSentAt"]) }
        let accepted = quoted.filter { JSSemantics.truthy(fields($0)["quoteAcceptedAt"]) }
        // Agreed and under way. A CANCELLED order is not converted — the
        // version this replaced counted it, because it only asked whether the
        // status had moved on from `quote`.
        let converted = accepted.filter { status($0) != "quote" && !dead.contains(status($0)) }
        // `delivered` as well as `completed`. Leaving it out is what made every
        // win rate too low.
        let done = converted.filter { finished.contains(status($0)) }

        func step(_ key: String, _ rows: [Int]) -> Step {
            Step(key: key, count: rows.count, value: rows.reduce(0) { $0 + price($1) })
        }
        let steps = [step("created", quoted), step("sent", sent),
                     step("accepted", accepted), step("converted", converted),
                     step("finished", done)]

        // How long a quote sat before the customer decided. The MEDIAN, because
        // a handful of quotes nobody ever answered would drag a mean into
        // uselessness.
        let decided: [Double] = accepted.compactMap { i in
            let o = fields(i)
            let from = timeOf(o["quoteSentAt"]) ?? timeOf(o["date"])
            guard let from, let to = timeOf(o["quoteAcceptedAt"]), to >= from else { return nil }
            return (to - from) / 86_400_000
        }

        // Quotes still waiting. This is the part a shop can act on today — a
        // funnel is a report, an open quote is a phone call.
        let open = quoted.filter {
            status($0) == "quote" && !JSSemantics.truthy(fields($0)["quoteAcceptedAt"])
        }
        let waiting: [Int] = open.compactMap { i in
            let o = fields(i)
            guard let at = timeOf(o["quoteSentAt"]) ?? timeOf(o["date"]) else { return nil }
            let days = ((now - at) / 86_400_000).rounded(.down)
            return Swift.max(0, days.isFinite ? Int(days) : 0)
        }

        let created = steps[0]
        return Report(steps: steps, totals: Totals(
            winRateByCount: created.count > 0
                ? Double(done.count) / Double(created.count) : nil,
            winRateByValue: created.value > 0
                ? done.reduce(0) { $0 + price($1) } / created.value : nil,
            medianDaysToDecide: median(decided),
            openCount: open.count,
            openValue: open.reduce(0) { $0 + price($1) },
            oldestOpenDays: waiting.max()))
    }
}
