import Foundation

/// When the queue will actually finish, machine by machine — ported to Swift.
///
/// Per machine, jobs run sequentially in the order given; cumulative print
/// hours convert to calendar days at the shop's own daily rate, giving each job
/// a ready date. Unassigned jobs share one virtual lane.
///
/// This is NOT the "late" the dashboard shows. That one means ALREADY past due,
/// which is news arriving too late to act on. This is a projection, and a shop
/// told on Tuesday that Friday's job will not make it can move it, split it, or
/// ring the customer.
public enum Schedule {

    /// The lane jobs with no machine share.
    public static let unassigned = "__unassigned__"

    public struct Job: Sendable, Equatable {
        public let id: String
        public let project: String
        public let status: String
        public let hours: Double
        public let startDay: Int
        public let etaDate: String
        public let dueDate: String
        public let late: Bool
    }

    public struct Machine: Sendable, Equatable {
        public let machineId: String
        public let unassigned: Bool
        public let jobs: [Job]
        public let totalHours: Double
        public let days: Int
        public let readyDate: String
        public let lateCount: Int
    }

    public struct Timeline: Sendable, Equatable {
        public let machines: [Machine]
        public let generatedAt: String
        public let dailyHours: Double
    }

    /// A stored day, moved on.
    ///
    /// Parsed and advanced in UTC so the result is timezone-independent — the
    /// module's own note says a local-time date round-tripped through
    /// `toISOString()` can slip a day at positive offsets. An unparseable date
    /// comes back UNCHANGED rather than as a guess.
    public static func addDays(_ iso: String, _ days: Int) -> String {
        // `new Date(iso + 'T00:00:00Z')` — and the engine is LENIENT about what
        // it will take: `2026` is the 1st of January and `2026-09` the 1st of
        // September, exactly as in `LanCalendar`. Requiring ten characters
        // here returned those unchanged instead, so a queue started from a
        // year-only date had every ETA read back as that year.
        guard let parts = LanCalendar.dateParts(iso) else { return iso }
        // `&+` would wrap and `+` TRAPS: a saturated day count from an
        // infinite job overflowed the addition and took the app down. The
        // original throws a RangeError from `toISOString()` at the same point,
        // so neither side produces a date — this produces the input back,
        // which is what `addDays` already does for anything it cannot parse.
        let (sum, overflowed) = LanCalendar.days(fromCivil: parts.0, parts.1, parts.2)
            .addingReportingOverflow(days)
        guard !overflowed, abs(sum) < 100_000_000 else { return iso }
        let moved = LanCalendar.civil(fromDays: sum)
        // `toISOString().slice(0, 10)` — four digits for an ordinary year. The
        // engine writes an expanded ±YYYYYY form outside 0000–9999, which that
        // slice would cut wrongly; a queue does not reach those years, and the
        // parity corpus asks anyway.
        return DateRange.pad(moved.0, 4) + "-" + DateRange.pad(moved.1, 2)
            + "-" + DateRange.pad(moved.2, 2)
    }

    /// A day count as an `Int`, without trapping.
    ///
    /// ── AND THIS IS WHY IT EXISTS ─────────────────────────────────────────
    ///
    /// A job whose `hours` is `Infinity` — which the book can hold, because
    /// `+j.hours || 0` keeps a truthy infinity — makes every day count
    /// infinite. JavaScript carries that and JSON then writes `null`, so the
    /// engine's `Int` field fails to decode and the board is lost.
    ///
    /// `Int(Double.infinity)` does not fail politely: it TRAPS, and the app
    /// stops. A crash is worse than a wrong number, so this saturates. Found
    /// by the harness, which put `"Infinity"` in the hours.
    static func days(_ value: Double) -> Int {
        guard value.isFinite else { return value > 0 ? Int.max : Int.min }
        return Int(Swift.min(Swift.max(value, -9_007_199_254_740_991), 9_007_199_254_740_991))
    }

    public static func compute(jobs: [JSONValue], dailyHours: Double,
                               startDate: String) -> Timeline {
        // `Math.max(1, +dailyHours || 8)` — `||` falls back on a FALSY number,
        // so 0 and NaN become 8, and a negative is then clamped to 1 rather
        // than to 8. A shop cannot print fewer than an hour a day, and one
        // that says zero means "I have not said".
        let daily = Swift.max(1, (dailyHours == 0 || dailyHours.isNaN) ? 8 : dailyHours)
        let start = startDate.isEmpty ? "1970-01-01" : startDate

        // Insertion order, because the sort below is stable and two machines
        // with the same hours would otherwise swap lanes between redraws.
        var order: [String] = []
        var byMachine: [String: [JSONValue]] = [:]
        for row in jobs {
            guard case .object(let j) = row else { continue }
            let mid = JSSemantics.truthy(j["machineId"]) ? JSSemantics.text(j["machineId"]) : unassigned
            if byMachine[mid] == nil { order.append(mid) }
            byMachine[mid, default: []].append(row)
        }

        var machines: [Machine] = []
        for machineId in order {
            var cumHours = 0.0
            var lateCount = 0
            var out: [Job] = []
            for row in byMachine[machineId] ?? [] {
                guard case .object(let j) = row else { continue }
                let asked = JSSemantics.number(j["hours"])
                let hours = Swift.max(0, (asked.isNaN || asked == 0) ? 0 : asked)
                let startDay = days((cumHours / daily).rounded(.down))
                cumHours += hours
                // A job with any hours at all always lands on day 1 or later:
                // something that takes twenty minutes is still not ready today.
                let ceil = (cumHours / daily).rounded(.up)
                let endDay = hours > 0 ? Swift.max(1, days(ceil)) : days(ceil)
                let eta = addDays(start, endDay)
                let due = JSSemantics.truthy(j["dueDate"]) ? JSSemantics.text(j["dueDate"]) : ""
                let late = !due.isEmpty && eta > due
                if late { lateCount += 1 }
                out.append(Job(id: JSSemantics.text(j["id"]),
                               project: JSSemantics.truthy(j["project"])
                                   ? JSSemantics.text(j["project"]) : "",
                               status: JSSemantics.truthy(j["status"])
                                   ? JSSemantics.text(j["status"]) : "",
                               hours: hours, startDay: startDay, etaDate: eta,
                               dueDate: due, late: late))
            }
            machines.append(Machine(
                machineId: machineId, unassigned: machineId == unassigned, jobs: out,
                totalHours: JSSemantics.round(cumHours * 10) / 10,
                days: days((cumHours / daily).rounded(.up)),
                readyDate: out.last?.etaDate ?? start, lateCount: lateCount))
        }

        // Busiest first, unassigned last. `(a.unassigned - b.unassigned)` is
        // BOOLEAN ARITHMETIC in the original — false is 0 and true is 1 — and
        // the sort is stable, so equal hours keep the order the queue arrived
        // in.
        machines = machines.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            if a.unassigned != b.unassigned { return !a.unassigned }
            if a.totalHours != b.totalHours { return a.totalHours > b.totalHours }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return Timeline(machines: machines, generatedAt: start, dailyHours: daily)
    }
}
