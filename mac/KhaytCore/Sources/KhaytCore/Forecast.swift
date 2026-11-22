import Foundation

/// What the shop is likely to bill next month — ported to Swift.
///
/// A least-squares line through the last whole months of completed revenue,
/// projected forward. The current, partial month is excluded from the history
/// on purpose: a forecast fitted through three days of September reads the
/// month as a collapse.
///
/// ── THE REVENUE COMES IN, RATHER THAN BEING WORKED OUT HERE ───────────────
///
/// The JavaScript takes a `revenueOf` callback, and the engine passes
/// `KhaytOrderMoney.orderNetRevenueBase` — the money chokepoint, which is
/// still shared. So this takes the figures already resolved, one per order, in
/// the same order. Deciding what an order earned is not this module's job in
/// either language; it is one rule, and a second opinion about it is exactly
/// what the shared modules exist to prevent.
public enum Forecast {

    public struct Month: Sendable, Equatable {
        public let key: Int
        public let label: String
        public let revenue: Double
    }

    public struct Projected: Sendable, Equatable {
        public let key: Int
        public let label: String
        public let projected: Double
    }

    public struct Outlook: Sendable, Equatable {
        public let history: [Month]
        public let projection: [Projected]
        public let nextMonth: Double
        /// Nil when the last actual month billed nothing — a percentage change
        /// from zero is not a number anybody should be shown.
        public let trendPct: Double?
        /// `trend`, `average` or `none`.
        public let method: String
    }

    /// The month a millisecond falls in, as one number.
    ///
    /// LOCAL, and the module's own comment says why: reading it in UTC put a
    /// UTC+3 shop's orders completed between midnight and 03:00 on the 1st
    /// into the previous month — and because "now" is keyed the same way, slid
    /// the entire window back a month when the app happened to be opened in
    /// those hours.
    public static func monthKey(ms: Double) -> Int {
        let parts = JSDate.localYearMonth(ms: ms)
        return parts.year * 12 + parts.month
    }

    /// `2026-09`. Negative keys are printed the way the original prints them —
    /// `Math.floor` for the year and a TRUNCATED `%` for the month, which are
    /// not the same rounding and disagree before 1970.
    public static func label(_ key: Int) -> String {
        let year = Int(floor(Double(key) / 12))
        let month = key % 12                       // JavaScript's `%`: sign of the dividend
        return String(year) + "-" + DateRange.pad(month + 1, 2)
    }

    /// The stamp an order is dated by, in the order the original tries them.
    public static func orderMs(_ order: JSONValue) -> Double? {
        guard case .object(let o) = order else { return nil }
        for key in ["completedAt", "deliveredAt", "date"] where JSSemantics.truthy(o[key]) {
            return JSDate.parse(JSSemantics.text(o[key]))
        }
        return nil
    }

    /// Completed revenue per whole month, oldest first, empty months included
    /// as zero.
    ///
    /// `revenues` is one figure per order, already resolved, in the same order
    /// as `orders`.
    public static func series(orders: [JSONValue], revenues: [Double],
                              now: Double, months: Int) -> [Month] {
        let months = months > 0 ? months : 6
        let current = monthKey(ms: now)
        let start = current - months
        var buckets: [Int: Double] = [:]
        for k in start..<current { buckets[k] = 0 }
        for (i, order) in orders.enumerated() {
            guard case .object(let o) = order,
                  case .string(let status)? = o["status"],
                  status == "completed" || status == "delivered",
                  let ms = orderMs(order) else { continue }
            let k = monthKey(ms: ms)
            guard k >= start, k < current else { continue }
            // `buckets[k] += +revenueOf(o) || 0` — and `||` falls back only on
            // a FALSY number, which is `0` and `NaN`. Infinity is truthy and
            // survives. Reading this as "finite or zero" silently dropped a
            // month's takings for a price stored as the string "Infinity";
            // the harness found it.
            let value = i < revenues.count ? revenues[i] : 0
            buckets[k, default: 0] += value.isNaN ? 0 : value
        }
        return (start..<current).map {
            Month(key: $0, label: label($0),
                  revenue: JSSemantics.round((buckets[$0] ?? 0) * 100) / 100)
        }
    }

    /// Least squares over y, with x = 0…n−1.
    public static func linreg(_ values: [Double]) -> (slope: Double, intercept: Double) {
        let n = values.count
        if n == 0 { return (0, 0) }
        if n == 1 { return (0, values[0]) }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for i in 0..<n {
            let x = Double(i)
            sx += x; sy += values[i]; sxx += x * x; sxy += x * values[i]
        }
        let denom = Double(n) * sxx - sx * sx
        if denom == 0 { return (0, sy / Double(n)) }
        let slope = (Double(n) * sxy - sx * sy) / denom
        return (slope, (sy - slope * sx) / Double(n))
    }

    public static func forecast(orders: [JSONValue], revenues: [Double], now: Double,
                                months: Int = 6, periods: Int = 3) -> Outlook {
        let periods = periods > 0 ? periods : 3
        let history = series(orders: orders, revenues: revenues, now: now, months: months)
        let values = history.map(\.revenue)
        let nonZero = values.count { $0 > 0 }
        let lastKey = history.last?.key ?? (monthKey(ms: now) - 1)

        // THREE non-zero months before a trend is drawn. Two points make a
        // line through anything, and a line through two months of a new shop
        // projects a business that does not exist yet.
        let project: (Int) -> Double
        let method: String
        if nonZero >= 3 {
            let fit = linreg(values)
            project = { Swift.max(0, fit.intercept + fit.slope * Double($0)) }
            method = "trend"
        } else {
            let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            project = { _ in Swift.max(0, mean) }
            method = nonZero > 0 ? "average" : "none"
        }

        let projection = (1...periods).map { p in
            Projected(key: lastKey + p, label: label(lastKey + p),
                      projected: JSSemantics.round(project(values.count - 1 + p) * 100) / 100)
        }
        let nextMonth = projection.first?.projected ?? 0
        let lastActual = values.last ?? 0
        let trendPct = lastActual > 0
            ? JSSemantics.round(((nextMonth - lastActual) / lastActual) * 1000) / 10
            : nil
        return Outlook(history: history, projection: projection, nextMonth: nextMonth,
                       trendPct: trendPct, method: method)
    }
}
