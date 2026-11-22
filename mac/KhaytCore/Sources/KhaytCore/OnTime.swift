import Foundation

/// Whether the shop keeps its promises — ported to Swift.
///
/// `rate` is nil when nothing was promised: "kept 0% of no promises" is not a
/// record, it is the absence of one.
public enum OnTime {

    public struct LateJob: Sendable, Equatable {
        public let id: String
        public let project: String
        public let dueDate: String
        public let finishedDay: String
        public let delayDays: Int
    }

    public struct Record: Sendable, Equatable {
        public let promised: Int
        public let onTime: Int
        public let late: Int
        public let rate: Double?
        public let avgDelayDays: Double?
        public let worstDelayDays: Int?
        public let lateJobs: [LateJob]
    }

    static let done: Set<String> = ["completed", "delivered"]

    /// The local day a value names, as `YYYY-MM-DD`.
    ///
    /// ── AND THE ANCHORING IS NOT THE SAME AS `waste-trend`'S ──────────────
    ///
    /// The test here is `^\d{4}-\d{2}-\d{2}$` — anchored at BOTH ends — so a
    /// stored day is taken as written and a full timestamp is PARSED and read
    /// in local time. `lib/waste-trend.js` anchors only the start and slices,
    /// so the same string is handled differently by the two modules. That
    /// looks like an inconsistency and is not one to fix inside a port: a
    /// timestamp read in local time can legitimately be a different day from
    /// its own first ten characters, and which of those a rule wants is the
    /// rule's business.
    public static func localDay(_ value: JSONValue?) -> String? {
        guard JSSemantics.truthy(value) else { return nil }
        let s = JSSemantics.text(value)
        if isPlainDay(s) { return s }
        guard let ms = JSDate.parse(s) else { return nil }
        return dayString(ms: ms)
    }

    /// Exactly ten characters of `YYYY-MM-DD`, and nothing after them.
    static func isPlainDay(_ s: String) -> Bool {
        s.count == 10 && DateRange.startsWithADay(s)
    }

    static func dayString(ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let shifted = ms / 1000 + Double(TimeZone.current.secondsFromGMT(for: date))
        let civil = LanCalendar.civil(fromDays: Int(floor(shifted / 86_400)))
        return DateRange.pad(civil.0, 4) + "-" + DateRange.pad(civil.1, 2)
            + "-" + DateRange.pad(civil.2, 2)
    }

    /// The day a job was finished: completion, else delivery, else the day taken.
    public static func finishedDay(_ order: JSONValue) -> String? {
        guard case .object(let o) = order else { return nil }
        return localDay(o["completedAt"]) ?? localDay(o["deliveredAt"]) ?? localDay(o["date"])
    }

    /// Whole days between two stored days.
    ///
    /// Both are parsed as LOCAL midnight, which is why the difference is
    /// ROUNDED rather than divided: across a daylight-saving boundary two
    /// midnights are 23 or 25 hours apart, and an integer division would call
    /// that nought days or two.
    public static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = JSDate.parse(from + "T00:00:00"),
              let b = JSDate.parse(to + "T00:00:00") else { return nil }
        return Int(JSSemantics.round((b - a) / 86_400_000))
    }

    /// `since` is a job's own `date` on or after that day.
    public static func record(_ orders: [JSONValue], since: String? = nil,
                              counts: (JSONValue) -> Bool = BusinessScope.countsForBusiness)
    -> Record {
        var promised = 0, kept = 0
        var lateJobs: [LateJob] = []
        for row in orders {
            guard case .object(let job) = row,
                  case .string(let status)? = job["status"], done.contains(status),
                  !JSSemantics.truthy(job["voidedAt"]), counts(row) else { continue }
            guard let due = localDay(job["dueDate"]) else { continue }
            // `if (o.since && …)` — an EMPTY `since` is falsy and applies no
            // filter at all. Treating it as a real cutoff excluded every job
            // with no date of its own, which is the opposite of "no filter".
            if let since, !since.isEmpty {
                // A job with NO date is excluded by a `since`, not included:
                // `!job.date || String(job.date) < since`.
                guard JSSemantics.truthy(job["date"]),
                      JSSemantics.text(job["date"]) >= since else { continue }
            }
            guard let done = finishedDay(row) else { continue }
            promised += 1
            // On the day counts as kept. A job due Thursday and finished
            // Thursday is not late.
            if done <= due { kept += 1; continue }
            lateJobs.append(LateJob(id: JSSemantics.text(job["id"]),
                                    project: JSSemantics.truthy(job["project"])
                                        ? JSSemantics.text(job["project"]) : "",
                                    dueDate: due, finishedDay: done,
                                    delayDays: daysBetween(due, done) ?? 0))
        }
        // Worst first. JavaScript's sort is stable, so equal delays keep the
        // order the book lists them in.
        lateJobs = lateJobs.enumerated().sorted {
            $0.element.delayDays != $1.element.delayDays
                ? $0.element.delayDays > $1.element.delayDays
                : $0.offset < $1.offset
        }.map(\.element)

        let late = lateJobs.count
        let totalDelay = lateJobs.reduce(0) { $0 + $1.delayDays }
        return Record(
            promised: promised, onTime: kept, late: late,
            rate: promised > 0
                ? JSSemantics.round((Double(kept) / Double(promised)) * 1000) / 10 : nil,
            avgDelayDays: late > 0
                ? JSSemantics.round((Double(totalDelay) / Double(late)) * 10) / 10 : nil,
            worstDelayDays: late > 0 ? lateJobs[0].delayDays : nil,
            lateJobs: lateJobs)
    }
}
