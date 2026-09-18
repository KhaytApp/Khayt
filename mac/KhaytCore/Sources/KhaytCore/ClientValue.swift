import Foundation

/// Which customers are actually worth keeping.
///
/// What each one has been worth over its whole life with the shop, how often it
/// comes back, what a typical job is worth, and when it was last seen. A shop
/// uses this to decide who to chase and who to look after — and, the part the
/// table this replaced could not answer, how badly it would hurt to lose the
/// top one.
///
/// ── WHAT THE VERSION THIS REPLACED COUNTED ────────────────────────────────
///
/// Every order with the client's id on it. No status check, no `voidedAt`, no
/// business scope. So a QUOTE counted: a customer who asked for ten quotes and
/// bought nothing sat at the top of "lifetime value", which is the one place on
/// the screen that must not reward asking. Voided orders counted too, as did
/// work marked outside the shop's trade.
public enum ClientValue {

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    /// Milliseconds for a stored day or timestamp, or nil. A bare day is
    /// midnight UTC — this measures a DURATION since the last job, and both
    /// ends in one zone keeps that number the same wherever it is read.
    static func timeOf(_ value: JSONValue?) -> Double? {
        let s = JSSemantics.text(value)
        guard !s.isEmpty else { return nil }
        let stamp = s.utf16.count == 10 ? s + "T00:00:00Z" : s
        guard let t = JSDate.parse(stamp), t.isFinite else { return nil }
        return t
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let clientId: String
        public let name: String
        /// Revenue EARNED — finished, unvoided, in scope. The same set the P&L
        /// counts, so a customer's total cannot disagree with the quarter it
        /// sits beside.
        public let value: Double
        public let jobs: Int
        public let averageJob: Double
        public let lastSeen: Double?
        public let daysSince: Int?
        public let quiet: Bool
        public let shareOfRevenue: Double
        /// Agreed work not finished yet. NOT part of `value` — lifetime value
        /// that rewards asking for a price is the one thing this table must not
        /// do — but carried, because a customer with 40,000 in flight is
        /// exactly who a shop should not ignore.
        public let inFlight: Double
        public var id: String { clientId }
    }

    public struct Totals: Sendable, Equatable {
        public let earned: Double
        public let clients: Int
        /// HOW BADLY IT WOULD HURT TO LOSE THE BIGGEST ONE. A shop with 60% of
        /// its revenue in one customer has a different business from one with
        /// 6%, and the table this replaced could not say which it was.
        public let topShare: Double
        public let quiet: Int
    }

    public struct Report: Sendable, Equatable {
        public let rows: [Row]
        public let totals: Totals
    }

    /// `revenues` is the caller's, aligned with `orders`.
    public static func report(clients: [JSONValue], orders: [JSONValue],
                              revenues: [Double], now: Double,
                              quietDays: Double = 90, limit: Int = 10,
                              countsForBusiness: (JSONValue) -> Bool = { _ in true },
                              isFinished: ((JSONValue) -> Bool)? = nil,
                              nameOf: ((JSONValue) -> String)? = nil) -> Report {
        let quietMs = Swift.max(0, quietDays.isFinite ? quietDays : 0) * 86_400_000
        let finished = isFinished ?? { order in
            guard case .object(let o) = order, case .string(let s)? = o["status"] else {
                return false
            }
            return s == "completed" || s == "delivered"
        }
        let name = nameOf ?? { client in
            guard case .object(let c) = client else { return "" }
            if let n = c["name"], JSSemantics.truthy(n) { return JSSemantics.text(n) }
            if let n = c["company"], JSSemantics.truthy(n) { return JSSemantics.text(n) }
            return ""
        }

        // Insertion-ordered, because the sort below is stable in the original
        // and two customers on the same figures must not shuffle.
        var order: [String] = []
        var rows: [String: (name: String, value: Double, jobs: Int,
                            lastSeen: Double?, inFlight: Double)] = [:]
        for client in clients {
            guard case .object(let c) = client, let id = c["id"],
                  JSSemantics.truthy(id) else { continue }
            let key = JSSemantics.text(id)
            guard rows[key] == nil else { continue }
            rows[key] = (name(client), 0, 0, nil, 0)
            order.append(key)
        }

        for (i, job) in orders.enumerated() {
            guard JSSemantics.truthy(job), case .object(let o) = job,
                  !JSSemantics.truthy(o["voidedAt"]) else { continue }
            let key = JSSemantics.truthy(o["clientId"]) ? JSSemantics.text(o["clientId"]) : ""
            guard rows[key] != nil, countsForBusiness(job) else { continue }
            let amount = i < revenues.count && revenues[i].isFinite ? revenues[i] : 0

            guard finished(job) else {
                // A quote is not in flight either — nobody has agreed to it.
                let status = JSSemantics.text(o["status"])
                if status != "quote" && status != "cancelled" { rows[key]!.inFlight += amount }
                continue
            }
            rows[key]!.value += amount
            rows[key]!.jobs += 1
            let seen = timeOf(JSSemantics.truthy(o["completedAt"]) ? o["completedAt"] : o["date"])
            if let seen, rows[key]!.lastSeen == nil || seen > rows[key]!.lastSeen! {
                rows[key]!.lastSeen = seen
            }
        }

        let earned = order.reduce(0.0) { $0 + (rows[$1]?.value ?? 0) }

        let built: [Row] = order.compactMap { key in
            guard let r = rows[key] else { return nil }
            let days: Int? = r.lastSeen.map {
                let d = ((now - $0) / 86_400_000).rounded(.down)
                return Swift.max(0, d.isFinite ? Int(d) : 0)
            }
            return Row(clientId: key, name: r.name,
                       value: r.value, jobs: r.jobs,
                       averageJob: r.jobs > 0 ? r.value / Double(r.jobs) : 0,
                       lastSeen: r.lastSeen, daysSince: days,
                       // A customer who has never bought anything is not
                       // "quiet" — it has not gone anywhere. Calling it churn
                       // risk would put every new name on a list the shop is
                       // meant to act on.
                       quiet: r.jobs > 0 && r.lastSeen != nil && (now - r.lastSeen!) > quietMs,
                       shareOfRevenue: earned > 0 ? r.value / earned : 0,
                       inFlight: r.inFlight)
        }

        let ranked = built.enumerated()
            .filter { $0.element.value > 0 || $0.element.inFlight > 0 }
            .sorted { lhs, rhs in
                if lhs.element.value != rhs.element.value {
                    return lhs.element.value > rhs.element.value
                }
                if lhs.element.inFlight != rhs.element.inFlight {
                    return lhs.element.inFlight > rhs.element.inFlight
                }
                let byName = lhs.element.name.localizedCompare(rhs.element.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.offset < rhs.offset   // Swift's sort is not stable
            }.map(\.element)

        let limit = Swift.max(0, limit)
        return Report(
            rows: limit > 0 ? Array(ranked.prefix(limit)) : ranked,
            totals: Totals(earned: earned, clients: ranked.count,
                           topShare: ranked.first?.shareOfRevenue ?? 0,
                           quiet: built.filter(\.quiet).count))
    }
}
