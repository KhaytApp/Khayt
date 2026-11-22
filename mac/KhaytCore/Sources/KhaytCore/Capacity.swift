import Foundation

/// Can the shop take this job, and when would it start?
///
/// Work that has been agreed and not yet finished, against the hours each
/// machine is actually run for. The answer a shop needs is not a percentage —
/// it is a DATE, and the percentage is how it gets there.
///
/// ── WHAT THE VERSION THIS REPLACED COULD NOT SAY ──────────────────────────
///
/// `pct` was `Math.min(100, …)`. A machine booked three weeks over therefore
/// read as exactly full — identical to one with nothing left and nothing
/// waiting. That is the single most important signal on the screen and it was
/// clamped away: "full" means take no more today, "300%" means the shop is
/// three weeks behind and somebody has to be told.
///
/// It also counted voided orders — a cancelled job kept booking the machine —
/// and dropped every machine with no target set, so a shop that had not filled
/// that field in saw an empty panel while its queue grew.
public enum Capacity {

    /// Agreed and not finished. A quote is not booked — nobody has said yes.
    public static let booked = ["pending", "printing", "post", "qc", "on_hold"]

    /// The key work that names no machine is gathered under.
    public static let noMachine = "__none__"

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let machineId: String
        public let name: String
        public let color: String
        public let hoursPerDay: Double
        public let bookedHours: Double
        public let jobs: Int
        public let availableHours: Double
        /// NOT CLAMPED. 300% is the answer, and it is a different answer from
        /// 100%. Nil for a machine with no target, because there is nothing to
        /// be a percentage of.
        public let loadPct: Double?
        public let daysToClear: Double?
        public let overbooked: Bool
        public var id: String { machineId }
    }

    public struct Totals: Sendable, Equatable {
        public let bookedHours: Double
        public let availableHours: Double
        /// Hours on machines nobody has given a target, or on no machine at
        /// all. Held APART because they cannot be turned into a percentage of
        /// anything — and saying nothing about them is how they stay invisible.
        public let untargeted: Double
        public let jobs: Int
        public let loadPct: Double?
        public let daysToClear: Double?
        public let overbooked: Bool
        /// No machine has a target, so no percentage can be worked out at all —
        /// which is a thing to say, not an empty panel.
        public let noTargets: Bool
    }

    public struct Report: Sendable, Equatable {
        public let rows: [Row]
        public let totals: Totals
    }

    /// `hours` is the caller's, aligned with `orders` — the estimated print
    /// hours for each.
    public static func report(machines: [JSONValue], orders: [JSONValue],
                              hours: [Double], days: Double = 7,
                              unassigned: String = "") -> Report {
        // `Math.max(1, num(i.days) || 7)` — zero and NaN both fall back to
        // seven, and anything under a day is a day.
        let n = num(.number(days))
        let days = Swift.max(1, n == 0 ? 7 : n)

        var order: [String] = []
        var rows: [String: (name: String, color: String, hoursPerDay: Double,
                            bookedHours: Double, jobs: Int)] = [:]
        for machine in machines {
            guard case .object(let m) = machine, let id = m["id"],
                  JSSemantics.truthy(id) else { continue }
            let key = JSSemantics.text(id)
            guard rows[key] == nil else { continue }
            rows[key] = (JSSemantics.truthy(m["name"]) ? JSSemantics.text(m["name"]) : "",
                         JSSemantics.truthy(m["color"]) ? JSSemantics.text(m["color"]) : "#888888",
                         num(m["targetHoursPerDay"]), 0, 0)
            order.append(key)
        }
        // Work that names no machine is still work. Dropping it is how a queue
        // grows behind a panel reading 40%.
        if rows[noMachine] == nil {
            rows[noMachine] = (unassigned, "#888888", 0, 0, 0)
            order.append(noMachine)
        }

        for (i, job) in orders.enumerated() {
            guard JSSemantics.truthy(job), case .object(let o) = job,
                  !JSSemantics.truthy(o["voidedAt"]),
                  booked.contains(JSSemantics.text(o["status"])) else { continue }
            let named = JSSemantics.truthy(o["machineId"]) ? JSSemantics.text(o["machineId"]) : ""
            let key = rows[named] != nil ? named : noMachine
            rows[key]!.bookedHours += i < hours.count && hours[i].isFinite ? hours[i] : 0
            rows[key]!.jobs += 1
        }

        let built: [Row] = order.compactMap { key in
            guard let r = rows[key] else { return nil }
            let hasTarget = r.hoursPerDay > 0
            let available = hasTarget ? r.hoursPerDay * days : 0
            return Row(machineId: key, name: r.name, color: r.color,
                       hoursPerDay: r.hoursPerDay, bookedHours: r.bookedHours, jobs: r.jobs,
                       availableHours: available,
                       loadPct: hasTarget ? (r.bookedHours / available) * 100 : nil,
                       daysToClear: hasTarget ? r.bookedHours / r.hoursPerDay : nil,
                       overbooked: hasTarget && r.bookedHours > available)
        }

        // A machine with nothing booked and no target has nothing to say. One
        // with a target is worth a row even when idle — that IS the answer to
        // "can you take this job".
        let kept = built.enumerated().filter { $0.element.bookedHours > 0
                                               || $0.element.hoursPerDay > 0 }
        let ranked = kept.sorted { lhs, rhs in
            // `(b.loadPct ?? -1) - (a.loadPct ?? -1)` — a row with no target
            // sorts as -1, BELOW an idle machine that has one.
            let a = lhs.element.loadPct ?? -1, b = rhs.element.loadPct ?? -1
            if a != b { return a > b }
            if lhs.element.bookedHours != rhs.element.bookedHours {
                return lhs.element.bookedHours > rhs.element.bookedHours
            }
            return lhs.offset < rhs.offset   // Swift's sort is not stable
        }.map(\.element)

        let withTarget = ranked.filter { $0.hoursPerDay > 0 }
        let bookedHours = ranked.reduce(0) { $0 + $1.bookedHours }
        let availableHours = withTarget.reduce(0) { $0 + $1.availableHours }
        let hoursPerDay = withTarget.reduce(0) { $0 + $1.hoursPerDay }
        let untargeted = ranked.filter { $0.hoursPerDay <= 0 }
            .reduce(0) { $0 + $1.bookedHours }

        return Report(rows: ranked, totals: Totals(
            bookedHours: bookedHours, availableHours: availableHours,
            untargeted: untargeted,
            jobs: ranked.reduce(0) { $0 + $1.jobs },
            loadPct: availableHours > 0
                ? ((bookedHours - untargeted) / availableHours) * 100 : nil,
            daysToClear: hoursPerDay > 0 ? (bookedHours - untargeted) / hoursPerDay : nil,
            overbooked: availableHours > 0 && (bookedHours - untargeted) > availableHours,
            noTargets: withTarget.isEmpty))
    }
}
