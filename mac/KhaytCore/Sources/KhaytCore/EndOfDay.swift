import Foundation

/// The shop's day, closed: what was finished and earned, what is still on the
/// floor, what was thrown away and how many hours were logged.
///
/// The other app's End of Day Report (`renderer/operations-extras.js`), with
/// three of its sums corrected rather than copied:
///
/// - **Time logged** read `durationMins`, a field nothing writes: both apps
///   record a time entry in `hours`, so the desktop's figure was always 0.
///   Both are read here, `hours` first.
/// - **The day** was `completedAt.startsWith(today)`, the UTC day of an
///   instant, so in Riyadh a job finished before 03:00 counted toward
///   yesterday. `dayOf` turns a stamp into the shop's own day
///   (`Calendar.localDay(ofInstant:)`).
/// - **"Filament used"** was the waste log's grams. It is "Filament wasted"
///   here, as on the desktop since #2146.
///
/// What a job earned is NOT worked out here: it is `orderNetRevenueBase`,
/// handed in per order, so this figure is the same net-of-tax number every
/// other report shows. A job marked `nonBusiness` earns nothing in it.
public struct EndOfDay: Sendable, Equatable {
    public struct Job: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let revenue: Double
    }

    /// What the shared rules say about one order, in the same order as the
    /// rows: finished, still open work, and its net revenue in the base
    /// currency.
    public struct Facts: Decodable, Sendable, Equatable {
        public let finished: Bool
        public let open: Bool
        public let revenue: Double
        public init(finished: Bool, open: Bool, revenue: Double) {
            self.finished = finished; self.open = open; self.revenue = revenue
        }
    }

    public let day: String
    /// Finished on `day`, newest first.
    public let finished: [Job]
    public let revenue: Double
    public let inProgress: Int
    /// Due on `day` and still open.
    public let dueNotDone: [Job]
    /// Due before `day` and still open.
    public let overdue: Int
    public let wasteGrams: Double
    public let wasteEntries: Int
    public let hoursLogged: Double

    public static func report(day: String, orders: [JSONValue], facts: [Facts],
                              waste: [JSONValue], time: [JSONValue],
                              dayOf: (String) -> String) -> EndOfDay {
        var finished: [(stamp: String, job: Job)] = []
        var due: [Job] = []
        var inProgress = 0, overdue = 0
        var revenue = 0.0
        for (row, fact) in zip(orders, facts) {
            guard case .object(let o) = row else { continue }
            let id = text(o["id"])
            let title = text(o["project"]).isEmpty ? id : text(o["project"])
            let earned = BusinessScope.countsForBusiness(row) && fact.revenue.isFinite ? fact.revenue : 0
            if fact.finished {
                // `completedAt`, else the job's own `date`: the desktop's rule
                // (#2146), for jobs finished before either app stamped it.
                let stamp = text(o["completedAt"]).isEmpty ? text(o["date"]) : text(o["completedAt"])
                if !stamp.isEmpty, dayOf(stamp) == day {
                    finished.append((stamp, Job(id: id, title: title, revenue: earned)))
                    revenue += earned
                }
            }
            if fact.open {
                inProgress += 1
                let dueDay = String(text(o["dueDate"]).prefix(10))
                if dueDay == day { due.append(Job(id: id, title: title, revenue: earned)) }
                else if !dueDay.isEmpty, dueDay < day { overdue += 1 }
            }
        }
        var grams = 0.0, entries = 0
        for row in waste {
            guard case .object(let w) = row, dayOf(text(w["date"])) == day else { continue }
            entries += 1
            grams += number(w["weight"])
        }
        var hours = 0.0
        for row in time {
            guard case .object(let t) = row else { continue }
            let stamp = text(t["date"]).isEmpty ? text(t["createdAt"]) : text(t["date"])
            guard dayOf(stamp) == day else { continue }
            if let h = t["hours"], number(h) > 0 { hours += number(h) }
            else { hours += number(t["durationMins"]) / 60 }
        }
        return EndOfDay(day: day,
                        finished: finished.sorted { $0.stamp > $1.stamp }.map(\.job),
                        revenue: revenue, inProgress: inProgress,
                        dueNotDone: due, overdue: overdue,
                        wasteGrams: grams, wasteEntries: entries, hoursLogged: hours)
    }

    private static func text(_ v: JSONValue?) -> String {
        if case .string(let s)? = v { return s }
        return ""
    }

    /// A number as the book may hold it: a number, or a string of one.
    private static func number(_ v: JSONValue?) -> Double {
        switch v {
        case .number(let n)? where n.isFinite && n > 0: return n
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        default: return 0
        }
    }
}
