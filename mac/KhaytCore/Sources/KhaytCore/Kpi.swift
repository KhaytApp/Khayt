import Foundation

/// The headline figures an owner wants at a glance.
///
/// A period's orders collapsed into revenue, margin, on-time delivery, cash
/// outstanding, average order value and the top clients and products. Nothing
/// is looked up here: the caller scopes the orders to a range, converts to the
/// shop's base currency and works out each order's cost and on-time answer, and
/// hands plain rows in.
public enum Kpi {

    /// One order, already in the shop's own currency.
    public struct Row: Sendable, Equatable {
        public let revenue: Double
        public let cost: Double
        public let completed: Bool
        /// Three-valued on purpose: nil is a job with no promise to keep, which
        /// is not the same as one that missed.
        public let onTime: Bool?
        public let outstanding: Double
        public let clientName: String
        public let productName: String

        public init(revenue: Double, cost: Double, completed: Bool, onTime: Bool?,
                    outstanding: Double, clientName: String, productName: String) {
            self.revenue = revenue
            self.cost = cost
            self.completed = completed
            self.onTime = onTime
            self.outstanding = outstanding
            self.clientName = clientName
            self.productName = productName
        }
    }

    public struct Top: Sendable, Equatable, Identifiable, Hashable {
        public let name: String
        public let revenue: Double
        public let count: Int
        public var id: String { name }
    }

    public struct Summary: Sendable, Equatable {
        public let orderCount: Int
        public let completedCount: Int
        public let revenue: Double
        public let cost: Double
        public let grossProfit: Double
        /// A percentage to one decimal place, and zero when there is no
        /// revenue to take a share of.
        public let grossMargin: Double
        public let avgOrderValue: Double
        /// Nil when nothing in the period had a due date — a shop with no
        /// promises kept none and broke none, and 0% would say it broke them.
        public let onTimePct: Double?
        public let onTimeTotal: Int
        public let outstanding: Double
        public let topClients: [Top]
        public let topProducts: [Top]
    }

    static func round2(_ n: Double) -> Double {
        JSSemantics.round((n.isNaN ? 0 : n) * 100) / 100
    }

    public static func compute(_ rows: [Row]) -> Summary {
        var revenue = 0.0, cost = 0.0, outstanding = 0.0
        var completedCount = 0, onTimeHit = 0, onTimeTotal = 0
        // Insertion-ordered: the original rolls up into a plain object, whose
        // string keys iterate in insertion order, and sorts that with a STABLE
        // sort. So two clients on the same revenue come out in the order the
        // book first mentioned them, and the list does not shuffle between
        // readings.
        var clientOrder: [String] = [], productOrder: [String] = []
        var byClient: [String: (revenue: Double, count: Int)] = [:]
        var byProduct: [String: (revenue: Double, count: Int)] = [:]

        for r in rows {
            let rev = r.revenue.isNaN ? 0 : r.revenue
            outstanding += r.outstanding.isNaN ? 0 : r.outstanding
            guard r.completed else { continue }
            completedCount += 1
            revenue += rev
            cost += r.cost.isNaN ? 0 : r.cost
            if let onTime = r.onTime {
                onTimeTotal += 1
                if onTime { onTimeHit += 1 }
            }
            if !r.clientName.isEmpty {
                if byClient[r.clientName] == nil {
                    byClient[r.clientName] = (0, 0); clientOrder.append(r.clientName)
                }
                byClient[r.clientName]!.revenue += rev
                byClient[r.clientName]!.count += 1
            }
            if !r.productName.isEmpty {
                if byProduct[r.productName] == nil {
                    byProduct[r.productName] = (0, 0); productOrder.append(r.productName)
                }
                byProduct[r.productName]!.revenue += rev
                byProduct[r.productName]!.count += 1
            }
        }

        func topFive(_ order: [String], _ map: [String: (revenue: Double, count: Int)]) -> [Top] {
            order.enumerated()
                .sorted { lhs, rhs in
                    let a = map[lhs.element]?.revenue ?? 0, b = map[rhs.element]?.revenue ?? 0
                    if a != b { return a > b }
                    return lhs.offset < rhs.offset   // Swift's sort is not stable
                }
                .prefix(5)
                .map { Top(name: $0.element, revenue: round2(map[$0.element]?.revenue ?? 0),
                           count: map[$0.element]?.count ?? 0) }
        }

        let grossProfit = revenue - cost
        return Summary(
            orderCount: rows.count,
            completedCount: completedCount,
            revenue: round2(revenue),
            cost: round2(cost),
            grossProfit: round2(grossProfit),
            grossMargin: revenue > 0 ? JSSemantics.round((grossProfit / revenue) * 1000) / 10 : 0,
            avgOrderValue: completedCount > 0 ? round2(revenue / Double(completedCount)) : 0,
            onTimePct: onTimeTotal > 0
                ? JSSemantics.round((Double(onTimeHit) / Double(onTimeTotal)) * 1000) / 10 : nil,
            onTimeTotal: onTimeTotal,
            outstanding: round2(outstanding),
            topClients: topFive(clientOrder, byClient),
            topProducts: topFive(productOrder, byProduct))
    }

    /// The rows as `kpi-rows` hands them over — still a JavaScript module, so
    /// this reads what it produces rather than assuming a shape.
    public static func rows(_ raw: [JSONValue]) -> [Row] {
        raw.map { row in
            var r: [String: JSONValue] = [:]
            if case .object(let fields) = row { r = fields }
            // `r.onTime === true || r.onTime === false` is STRICT: only a real
            // boolean counts. A job whose on-time answer is null or missing has
            // no promise to keep and must not be counted as one kept or broken.
            var onTime: Bool?
            if case .bool(let b)? = r["onTime"] { onTime = b }
            return Row(revenue: JSSemantics.number(r["revenue"]),
                       cost: JSSemantics.number(r["cost"]),
                       completed: JSSemantics.truthy(r["completed"]),
                       onTime: onTime,
                       outstanding: JSSemantics.number(r["outstanding"]),
                       // `if (r.clientName)` is a truthiness test, so an empty
                       // name is no name — but a number is a name, spelled the
                       // way an object key would spell it.
                       clientName: JSSemantics.truthy(r["clientName"])
                           ? JSSemantics.text(r["clientName"]) : "",
                       productName: JSSemantics.truthy(r["productName"])
                           ? JSSemantics.text(r["productName"]) : "")
        }
    }
}
