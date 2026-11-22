import Foundation

/// Is the shop growing, or serving the same people?
///
/// Revenue split between customers buying for the FIRST time and customers
/// coming back. A shop living on returning customers is stable and not growing;
/// one living on new ones is growing and keeping nobody. Both are worth
/// knowing, and the split says which.
///
/// ── FOUR THINGS THE VERSION THIS REPLACED GOT WRONG ───────────────────────
///
/// 1. It compared DATES AS STRINGS to decide who was new, so a customer whose
///    first two jobs landed on one day counted as new twice. Identity is the
///    ORDER, not the day.
/// 2. It counted voided orders.
/// 3. It ignored the business scope every other figure applies.
/// 4. It counted `completed` only, so a job that reached the customer —
///    `delivered` — was in neither half.
///
/// And it counted ORDERS rather than customers, so "12 from new clients" could
/// be twelve people or one person ordering twelve times. Both are reported.
public enum CustomerMix {

    public static let finished = ["completed", "delivered"]

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    /// `String(v ?? '').slice(0, 10)`, in UTF-16 code units.
    static func day(_ value: JSONValue?) -> String {
        String(decoding: Array(JSSemantics.text(value).utf16.prefix(10)), as: UTF16.self)
    }

    /// `a < b` on two JavaScript strings — UTF-16 code units.
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

    public struct Side: Sendable, Equatable {
        public let revenue: Double
        public let jobs: Int
        public let clients: Int
        /// Nil rather than zero when there is nothing at all: 0% of nothing
        /// reads as "none of your money came from new customers", which is a
        /// claim rather than an absence.
        public let shareOfRevenue: Double?
    }

    public struct Totals: Sendable, Equatable {
        public let revenue: Double
        public let jobs: Int
        /// DISTINCT, not the two halves added. A customer whose first sale AND
        /// a repeat both fall inside the window is in both sets — it was new
        /// and then it came back, which is the best thing that can happen and
        /// must not be counted as two people.
        public let clients: Int
        /// The average new customer's first order — what a shop is buying when
        /// it spends on getting found.
        public let firstOrderValue: Double?
    }

    public struct Report: Sendable, Equatable {
        public let fresh: Side
        public let returning: Side
        public let totals: Totals
    }

    /// `revenues` is the caller's, aligned with `orders`: `order-money` still
    /// lives in JavaScript and the function the rule takes cannot cross the
    /// bridge.
    ///
    /// `inWindow` OVERRIDES `from`/`to` when given. The other app's range
    /// picker offers named periods — "this quarter" — and owns a predicate for
    /// them; re-deriving the bounds here would be a second answer to a question
    /// `date-range` already answers.
    public static func report(orders: [JSONValue], revenues: [Double],
                              from: String = "", to: String = "",
                              countsForBusiness: (JSONValue) -> Bool = { _ in true },
                              inWindow: ((JSONValue) -> Bool)? = nil) -> Report {
        let from = day(.string(from)), to = day(.string(to))

        var counted: [Int] = []
        for (i, order) in orders.enumerated() {
            guard JSSemantics.truthy(order), case .object(let o) = order,
                  !JSSemantics.truthy(o["voidedAt"]),
                  JSSemantics.truthy(o["clientId"]),
                  !day(o["date"]).isEmpty,
                  finished.contains(JSSemantics.text(o["status"])),
                  countsForBusiness(order) else { continue }
            counted.append(i)
        }

        func field(_ i: Int, _ key: String) -> JSONValue? {
            guard case .object(let o) = orders[i] else { return nil }
            return o[key]
        }

        // WHICH ORDER WAS EACH CUSTOMER'S FIRST — by identity, not by date.
        // Sorted by day and then by id so the choice is stable when two land on
        // one day, and the SECOND of them is then correctly a returning sale.
        // `localeCompare` on both keys, and the index last because the
        // original's sort is stable and Swift's is not.
        let ordered = counted.enumerated().sorted { lhs, rhs in
            let byDay = day(field(lhs.element, "date"))
                .localizedCompare(day(field(rhs.element, "date")))
            if byDay != .orderedSame { return byDay == .orderedAscending }
            let byId = JSSemantics.text(field(lhs.element, "id"))
                .localizedCompare(JSSemantics.text(field(rhs.element, "id")))
            if byId != .orderedSame { return byId == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var firstOrderId: [String: String] = [:]
        for i in ordered {
            let client = JSSemantics.text(field(i, "clientId"))
            if firstOrderId[client] == nil {
                firstOrderId[client] = JSSemantics.text(field(i, "id"))
            }
        }

        var freshRevenue = 0.0, returningRevenue = 0.0
        var freshJobs = 0, returningJobs = 0
        var freshClients: Set<String> = [], returningClients: Set<String> = []

        for i in counted {
            let order = orders[i]
            if let inWindow {
                guard inWindow(order) else { continue }
            } else {
                let at = day(field(i, "date"))
                if !from.isEmpty && less(at, from) { continue }
                if !to.isEmpty && less(to, at) { continue }
            }
            let client = JSSemantics.text(field(i, "clientId"))
            let isFirst = firstOrderId[client] == JSSemantics.text(field(i, "id"))
            let amount = i < revenues.count && revenues[i].isFinite ? revenues[i] : 0
            if isFirst {
                freshRevenue += amount; freshJobs += 1; freshClients.insert(client)
            } else {
                returningRevenue += amount; returningJobs += 1; returningClients.insert(client)
            }
        }

        let revenue = freshRevenue + returningRevenue
        func shape(_ r: Double, _ jobs: Int, _ clients: Set<String>) -> Side {
            Side(revenue: r, jobs: jobs, clients: clients.count,
                 shareOfRevenue: revenue > 0 ? r / revenue : nil)
        }

        return Report(
            fresh: shape(freshRevenue, freshJobs, freshClients),
            returning: shape(returningRevenue, returningJobs, returningClients),
            totals: Totals(revenue: revenue, jobs: freshJobs + returningJobs,
                           clients: freshClients.union(returningClients).count,
                           firstOrderValue: freshJobs > 0
                               ? freshRevenue / Double(freshJobs) : nil))
    }
}
