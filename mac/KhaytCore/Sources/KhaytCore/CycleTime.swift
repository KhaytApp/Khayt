import Foundation

/// How long a job takes, from the day it was taken to the day it was finished.
///
/// Two readings of the same interval: the average month by month, and the
/// average, fastest and slowest per product — so a shop can see which of the
/// things it sells is the one that always runs late.
///
/// ── TWO FAULTS THIS CARRIES A FIX FOR ─────────────────────────────────────
///
/// Both readings used to count `status === 'completed'` only. `delivered` is
/// PAST completed in Khayt's pipeline, so a job finished and handed over left
/// both charts. Both take completed or delivered now, and a job's finish is
/// `completedAt`, else `deliveredAt`: a job marked delivered without ever
/// passing through completed still has a day it was done.
///
/// The lead-time table keyed on the job's free-text name, so a product spelled
/// two ways was two products and a job taken from the catalogue did not join
/// its product. It keys on `productId` where there is one.
public enum CycleTime {

    public static let done: Set<String> = ["completed", "delivered"]
    static let day = 86_400_000.0

    /// `o.completedAt || o.deliveredAt || null`.
    static func finishedAt(_ o: [String: JSONValue]) -> JSONValue? {
        if let at = o["completedAt"], JSSemantics.truthy(at) { return at }
        if let at = o["deliveredAt"], JSSemantics.truthy(at) { return at }
        return nil
    }

    /// Days from the day taken to the finish instant, or nil where it cannot be
    /// told.
    ///
    /// A NEGATIVE interval — finished before it was taken, which is a typed
    /// date — is a job that cannot be measured and is left out, as it always
    /// was. Counting it would pull a month's average below zero.
    public static func daysToFinish(_ order: JSONValue) -> Double? {
        guard JSSemantics.truthy(order), case .object(let o) = order,
              case .string(let status)? = o["status"], done.contains(status),
              !JSSemantics.truthy(o["voidedAt"]),
              let date = o["date"], JSSemantics.truthy(date) else { return nil }
        guard let end = JSDate.parse(JSSemantics.text(finishedAt(o))) , end.isFinite
        else { return nil }
        // `date.length === 10 ? date + 'T00:00:00' : date` — a bare day is read
        // as MIDNIGHT LOCAL rather than as UTC, so a shop west of Greenwich
        // does not measure its own jobs as a day longer than they were.
        let raw = JSSemantics.text(date)
        let stamp = raw.utf16.count == 10 ? raw + "T00:00:00" : raw
        guard let start = JSDate.parse(stamp), start.isFinite else { return nil }
        let days = (end - start) / day
        return days < 0 ? nil : days
    }

    /// `${d.getFullYear()}-${pad(d.getMonth() + 1)}` — the LOCAL month an
    /// instant falls in.
    /// `JSDate.localYearMonth` answers a ZERO-BASED month, because `getMonth()`
    /// does — which is why the original writes `getMonth() + 1`. Assumed
    /// one-based here first, and the harness answered with every month one
    /// early.
    static func monthOf(_ ms: Double) -> String {
        let parts = JSDate.localYearMonth(ms: ms)
        let month = parts.month + 1
        return "\(parts.year)-" + (month < 10 ? "0\(month)" : "\(month)")
    }

    /// The `months` months ending at `now`, oldest first, in the local calendar.
    public static func monthKeys(now: Double, months: Int) -> [String] {
        let here = JSDate.localYearMonth(ms: now)
        var out: [String] = []
        for i in stride(from: months - 1, through: 0, by: -1) {
            // `new Date(y, m - i, 1)` — JavaScript rolls a negative month back
            // through the years for you, so this does the same arithmetic
            // rather than clamping.
            let total = here.year * 12 + here.month - i
            let year = Int((Double(total) / 12).rounded(.down))
            let month = total - year * 12 + 1
            out.append("\(year)-" + (month < 10 ? "0\(month)" : "\(month)"))
        }
        return out
    }

    static func round1(_ v: Double) -> Double { JSSemantics.round(v * 10) / 10 }

    // MARK: - Month by month

    public struct Month: Sendable, Equatable, Identifiable {
        public let key: String
        /// Nil for a month with nothing finished in it. NOT zero — no jobs is
        /// not "done in no time", and a chart drawing zero says the shop got
        /// faster.
        public let avgDays: Double?
        public let jobs: Int
        public var id: String { key }
    }

    public struct Report: Sendable, Equatable {
        public let months: [Month]
        public let avgDays: Double?
        public let jobs: Int
    }

    public static func report(orders: [JSONValue], now: Double, months: Int = 6,
                              countsForBusiness: (JSONValue) -> Bool = { _ in true })
        -> Report {
        let months = months > 0 ? months : 6
        let keys = monthKeys(now: now, months: months)
        var total: [String: Double] = [:], jobs: [String: Int] = [:]
        for key in keys { total[key] = 0; jobs[key] = 0 }
        var allTotal = 0.0, allJobs = 0

        for order in orders {
            guard JSSemantics.truthy(order), countsForBusiness(order),
                  let days = daysToFinish(order),
                  case .object(let o) = order,
                  let at = JSDate.parse(JSSemantics.text(finishedAt(o))), at.isFinite
            else { continue }
            let key = monthOf(at)
            guard jobs[key] != nil else { continue }   // outside the window
            total[key]! += days
            jobs[key]! += 1
            allTotal += days
            allJobs += 1
        }

        return Report(
            months: keys.map { key in
                Month(key: key,
                      avgDays: (jobs[key] ?? 0) > 0
                          ? round1((total[key] ?? 0) / Double(jobs[key]!)) : nil,
                      jobs: jobs[key] ?? 0)
            },
            avgDays: allJobs > 0 ? round1(allTotal / Double(allJobs)) : nil,
            jobs: allJobs)
    }

    // MARK: - Per product

    public struct ProductRow: Sendable, Equatable, Identifiable {
        public let key: String
        public let productId: String?
        public let name: String
        public let avgDays: Double
        public let fastest: Double
        public let slowest: Double
        public let jobs: Int
        public var id: String { key }
    }

    public struct ProductReport: Sendable, Equatable {
        /// Slowest average first. `jobs` is every job measured, so a caller can
        /// decide whether there is enough here to show at all.
        public let rows: [ProductRow]
        public let jobs: Int
    }

    public static func byProduct(orders: [JSONValue], top: Int = 10,
                                 countsForBusiness: (JSONValue) -> Bool = { _ in true })
        -> ProductReport {
        let top = top > 0 ? top : 10
        // Insertion-ordered, because the sort below is STABLE in the original
        // and two products on the same average must not shuffle between
        // readings.
        var order: [String] = []
        var rows: [String: (productId: String?, name: String, total: Double,
                            jobs: Int, fastest: Double, slowest: Double)] = [:]
        var measured = 0

        for job in orders {
            guard JSSemantics.truthy(job), countsForBusiness(job),
                  let days = daysToFinish(job), case .object(let o) = job else { continue }
            var productId: String?
            if let id = o["productId"], JSSemantics.truthy(id) { productId = JSSemantics.text(id) }
            var name = ""
            if let p = o["project"], JSSemantics.truthy(p) { name = JSSemantics.text(p) }
            else if let n = o["name"], JSSemantics.truthy(n) { name = JSSemantics.text(n) }
            let key = productId.map { "product:\($0)" }
                ?? ("name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())

            if rows[key] == nil {
                rows[key] = (productId, "", 0, 0, .infinity, -.infinity)
                order.append(key)
            }
            rows[key]!.total += days
            rows[key]!.jobs += 1
            rows[key]!.fastest = Swift.min(rows[key]!.fastest, days)
            rows[key]!.slowest = Swift.max(rows[key]!.slowest, days)
            // `if (!row.name && name)` — the FIRST job that carries a name
            // names the row, so a product whose first job had none is still
            // named by the next one.
            if rows[key]!.name.isEmpty && !name.isEmpty { rows[key]!.name = name }
            measured += 1
        }

        let built = order.compactMap { key -> ProductRow? in
            guard let r = rows[key] else { return nil }
            return ProductRow(key: key, productId: r.productId,
                              name: r.name.isEmpty ? "Unknown" : r.name,
                              avgDays: round1(r.total / Double(r.jobs)),
                              fastest: round1(r.fastest), slowest: round1(r.slowest),
                              jobs: r.jobs)
        }
        let sorted = built.enumerated().sorted { lhs, rhs in
            if lhs.element.avgDays != rhs.element.avgDays {
                return lhs.element.avgDays > rhs.element.avgDays
            }
            return lhs.offset < rhs.offset   // Swift's sort is not stable
        }.map(\.element)

        return ProductReport(rows: Array(sorted.prefix(top)), jobs: measured)
    }
}
