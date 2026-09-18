import Foundation

/// What the shop threw away, month by month, and why — ported to Swift.
///
/// ── THE THREE NAMED TYPES ARE CHOSEN FROM THE DATA ────────────────────────
///
/// The chart this came from named them by hand: `warping`, `adhesion`,
/// `stringing`, everything else "other". The waste log's own vocabulary has no
/// `adhesion` — it has `bed_adhesion` — so **every failed first layer a shop
/// ever logged landed in "other"**, and a chart whose whole point is "what
/// keeps going wrong" could not say the commonest thing that does.
///
/// So the names come from the window: the heaviest three, and the rest said as
/// "other".
///
/// Grams, not money: what a failed print COST depends on which spool it came
/// off, and the log already carries that per entry. A trend of failure types
/// needs the weight.
public enum WasteTrend {

    public struct Month: Sendable, Equatable {
        public let key: String
        public let total: Double
        public let byType: [String: Double]
        public let entries: Int
    }

    public struct Trend: Sendable, Equatable {
        /// The named types in the order the columns stack — heaviest first —
        /// with `other` last when anything fell outside them.
        public let types: [String]
        public let months: [Month]
        public let total: Double
        public let entries: Int
        public let byType: [String: Double]
    }

    /// The `YYYY-MM` an entry belongs to.
    ///
    /// ── AND A STORED DAY IS SLICED, NOT PARSED ────────────────────────────
    ///
    /// A `YYYY-MM-DD` string is cut at seven characters and never becomes a
    /// date at all. That is deliberate and it matters: parsing it would read
    /// it as UTC midnight, and a shop west of Greenwich would file the 1st of
    /// the month under the previous one. Anything else IS parsed, and read in
    /// local time like every other month bucket.
    public static func month(of day: JSONValue?) -> String? {
        guard JSSemantics.truthy(day) else { return nil }
        let s = JSSemantics.text(day)
        if DateRange.startsWithADay(s) { return String(s.prefix(7)) }
        guard let ms = JSDate.parse(s) else { return nil }
        let parts = JSDate.localYearMonth(ms: ms)
        return DateRange.pad(parts.year, 4) + "-" + DateRange.pad(parts.month + 1, 2)
    }

    /// The window's month keys, oldest first, in LOCAL time.
    public static func monthKeys(now: Double, months: Int) -> [String] {
        let parts = JSDate.localYearMonth(ms: now)
        return (0..<months).reversed().map { back -> String in
            // `new Date(y, m - i, 1)` rolls the year over by itself.
            let (y, m) = DateRange.rolled(year: parts.year, month: parts.month - back)
            return DateRange.pad(y, 4) + "-" + DateRange.pad(m + 1, 2)
        }
    }

    public static func trend(_ wasteLog: [JSONValue], now: Double,
                             months: Int = 6, named: Int = 3) -> Trend {
        let months = months > 0 ? Int(months) : 6
        let named = named >= 0 ? Int(named) : 3
        let keys = monthKeys(now: now, months: months)
        let window = Set(keys)

        // First pass: which types matter in this window. Insertion order is
        // kept because `Object.entries` is ordered and the sort below breaks
        // ties by NAME, not by position — but the order still decides which of
        // two equal names is compared first, so it is not thrown away.
        var order: [String] = []
        var weight: [String: Double] = [:]
        var rows: [(key: String, type: String, grams: Double)] = []
        for entry in wasteLog {
            guard JSSemantics.truthy(entry), case .object(let w) = entry else { continue }
            guard let key = month(of: w["date"]), window.contains(key) else { continue }
            // A type is only a type if it is a NON-EMPTY STRING. A failure type
            // stored as a number is "other", which is the honest bucket for a
            // value the vocabulary does not have.
            var type = "other"
            if case .string(let t)? = w["failureType"], !t.isEmpty { type = t }
            let n = JSSemantics.number(w["weight"])
            let grams = Swift.max(0, n.isFinite ? n : 0)
            if weight[type] == nil { order.append(type) }
            weight[type, default: 0] += grams
            rows.append((key, type, grams))
        }

        // Heaviest first, ties broken by name — so two types that weigh the
        // same stack in the same order on both apps and on every redraw.
        let ranked = order.filter { $0 != "other" }.sorted { lhs, rhs in
            let a = weight[lhs] ?? 0, b = weight[rhs] ?? 0
            if a != b { return b < a }
            return lhs < rhs
        }
        let top = Array(ranked.prefix(named))
        let rest = ranked.dropFirst(named).reduce(0.0) { $0 + (weight[$1] ?? 0) }
            + (weight["other"] ?? 0)
        let types = (rest > 0 || rows.contains { $0.type == "other" }) ? top + ["other"] : top

        func bucket(_ t: String) -> String { top.contains(t) ? t : "other" }
        var byMonth: [String: Month] = [:]
        for key in keys { byMonth[key] = Month(key: key, total: 0, byType: [:], entries: 0) }
        for row in rows {
            guard let had = byMonth[row.key] else { continue }
            let t = bucket(row.type)
            var types = had.byType
            // Rounded at EVERY step, not once at the end — the original does,
            // and rounding a running total is not the same as rounding a sum.
            types[t] = round1((types[t] ?? 0) + row.grams)
            byMonth[row.key] = Month(key: row.key, total: round1(had.total + row.grams),
                                     byType: types, entries: had.entries + 1)
        }
        var byType: [String: Double] = [:]
        for row in rows { byType[bucket(row.type)] = round1((byType[bucket(row.type)] ?? 0) + row.grams) }

        return Trend(types: types, months: keys.compactMap { byMonth[$0] },
                     total: round1(rows.reduce(0.0) { $0 + $1.grams }),
                     entries: rows.count, byType: byType)
    }

    static func round1(_ v: Double) -> Double { JSSemantics.round(v * 10) / 10 }
}
