import Foundation

/// Two figures a month, twelve months back: what an hour of printing earned,
/// and what a gram of material cost.
///
/// ── BOTH WERE WRONG IN THE SCREEN THIS REPLACES ───────────────────────────
///
/// Revenue per print-hour counted `completed` only. In Khayt's pipeline
/// `delivered` is PAST completed — a job that was finished AND handed over left
/// the chart, so a shop that delivers promptly saw its best months as its
/// emptiest. The same fault has now been found in five charts.
///
/// "Average material cost per gram" divided a spool's cost by its REMAINING
/// weight, so a spool got dearer per gram as it was used up and a nearly
/// finished one cost a fortune. And it was computed from today's shelf for
/// every one of the twelve months, so the "trend" was one number twelve times.
/// A gram costs what the spool cost divided by what it weighed NEW, and the
/// month it belongs to is the month the spool was OPENED.
public enum CostTrends {

    public static let done: Set<String> = ["completed", "delivered"]

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    static func round2(_ v: Double) -> Double { JSSemantics.round(v * 100) / 100 }
    static func round4(_ v: Double) -> Double { JSSemantics.round(v * 10000) / 10000 }

    /// `YYYY-MM` of an ISO instant or day, in the shop's own calendar.
    ///
    /// A DAY STRING is already local and is sliced; an INSTANT is turned into
    /// the local day first. Parsing the day instead would put it at midnight
    /// UTC and move it a month for half the world at a month boundary.
    public static func monthOf(_ value: JSONValue?) -> String? {
        guard JSSemantics.truthy(value) else { return nil }
        let s = JSSemantics.text(value)
        if s.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil {
            return String(decoding: Array(s.utf16.prefix(7)), as: UTF16.self)
        }
        guard let ms = JSDate.parse(s), ms.isFinite else { return nil }
        let parts = JSDate.localYearMonth(ms: ms)
        // `getMonth()` is zero-based, which is why the original adds one.
        let month = parts.month + 1
        return "\(parts.year)-" + (month < 10 ? "0\(month)" : "\(month)")
    }

    /// The month a job counts in: when it was finished, else when it was taken.
    public static func monthDone(_ order: JSONValue) -> String? {
        guard case .object(let o) = order else { return nil }
        return monthOf(o["completedAt"]) ?? monthOf(o["deliveredAt"]) ?? monthOf(o["date"])
    }

    public struct Month: Sendable, Equatable, Identifiable {
        public let key: String
        public let revenue: Double
        public let hours: Double
        /// Nil, never 0. No hours printed is not "earned nothing per hour".
        public let perHour: Double?
        /// Weighted by grams: two spools opened in a month cost what they cost
        /// per gram BETWEEN them, not the average of two per-gram figures.
        public let costPerGram: Double?
        public let spoolsOpened: Int
        public var id: String { key }
    }

    public struct Report: Sendable, Equatable {
        public let months: [Month]
        /// The whole window's revenue per hour.
        public let perHour: Double?
        /// EVERY spool's cost per gram, not just the ones opened in the window.
        /// Deliberately asymmetric with `perHour` above, and the original's:
        /// the shelf is what it is, and a window that happens to contain no
        /// purchases has not made material free.
        public let costPerGram: Double?
    }

    /// `revenues` is the caller's, aligned with `orders`.
    public static func report(orders: [JSONValue], spools: [JSONValue],
                              revenues: [Double], now: Double, months: Int = 12,
                              countsForBusiness: (JSONValue) -> Bool = { _ in true })
        -> Report {
        let months = months > 0 ? months : 12
        // The same month arithmetic `cycle-time` does, from the one place that
        // does it — `new Date(y, m - i, 1)` rolling back through the years.
        let keys = CycleTime.monthKeys(now: now, months: months)

        var revenue: [String: Double] = [:], hours: [String: Double] = [:]
        var costSum: [String: Double] = [:], gramSum: [String: Double] = [:]
        var opened: [String: Int] = [:]
        for key in keys {
            revenue[key] = 0; hours[key] = 0
            costSum[key] = 0; gramSum[key] = 0; opened[key] = 0
        }

        for (i, job) in orders.enumerated() {
            guard JSSemantics.truthy(job), case .object(let o) = job,
                  done.contains(JSSemantics.text(o["status"])),
                  !JSSemantics.truthy(o["voidedAt"]),
                  countsForBusiness(job),
                  let key = monthDone(job), revenue[key] != nil else { continue }
            revenue[key]! += i < revenues.count && revenues[i].isFinite ? revenues[i] : 0
            hours[key]! += num(o["printTime"])
        }

        var allCost = 0.0, allGrams = 0.0
        for spool in spools {
            guard JSSemantics.truthy(spool), case .object(let s) = spool else { continue }
            let cost = num(s["cost"]), grams = num(s["spoolWeight"])
            guard cost > 0, grams > 0 else { continue }
            // Counted into the whole-shelf figure BEFORE the window check, so
            // a spool opened outside the twelve months still prices material.
            allCost += cost; allGrams += grams
            guard let key = monthOf(s["openedAt"]), costSum[key] != nil else { continue }
            costSum[key]! += cost
            gramSum[key]! += grams
            opened[key]! += 1
        }

        var totalRevenue = 0.0, totalHours = 0.0
        let rows = keys.map { key -> Month in
            let r = revenue[key] ?? 0, h = hours[key] ?? 0
            totalRevenue += r; totalHours += h
            return Month(key: key, revenue: round2(r), hours: round2(h),
                         perHour: h > 0 ? round2(r / h) : nil,
                         costPerGram: (gramSum[key] ?? 0) > 0
                             ? round4((costSum[key] ?? 0) / gramSum[key]!) : nil,
                         spoolsOpened: opened[key] ?? 0)
        }

        return Report(months: rows,
                      perHour: totalHours > 0 ? round2(totalRevenue / totalHours) : nil,
                      costPerGram: allGrams > 0 ? round4(allCost / allGrams) : nil)
    }
}
