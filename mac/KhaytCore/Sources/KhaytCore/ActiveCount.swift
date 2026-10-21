import Foundation

/// The anonymous active-install count: the rules every sender keeps.
///
/// ── WHAT THIS IS ──────────────────────────────────────────────────────────
///
/// Once a UTC day, an install says "I'm running" to `POST /v1/active`
/// (khayt-cloud #123, `docs/api-contract.md` "Active-install count"). The body
/// is exactly six fields — platform, channel, version and three flags — and
/// the cloud keeps only counters, so daily, weekly and monthly actives and new
/// installs are sums of flags, with no install id anywhere. ON by default with
/// an off switch (decided 21 October 2026), described at khaytapp.com/privacy
/// `#active-count`.
///
/// Here, in `KhaytCore`, so the Mac and the iPhone send by one rule: the day,
/// the flags, the body, and what an answer means. Each app keeps its own
/// switch, storage and transport.
public enum ActiveCount {

    public static let endpoint = URL(string: "https://cloud.khaytapp.com/v1/active")!

    /// The three flags, from the UTC day of the last COUNTED ping (a 200).
    public struct Flags: Equatable, Sendable {
        public var firstThisWeek: Bool
        public var firstThisMonth: Bool
        public var firstEver: Bool
        public init(firstThisWeek: Bool, firstThisMonth: Bool, firstEver: Bool) {
            self.firstThisWeek = firstThisWeek; self.firstThisMonth = firstThisMonth; self.firstEver = firstEver
        }
    }

    /// What an answer means for the stored dates.
    public enum Outcome: Equatable, Sendable {
        /// 200, counted or over the cap: today is done AND is the last counted day.
        case counted
        /// 422: the sender is wrong. Today is done; the counted day stays.
        case refused
        /// 404, 5xx, offline: nothing counted. Try again later with the same flags.
        case retry
    }

    private static let utc = TimeZone(identifier: "UTC")!

    private static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = utc; return c
    }

    private static var iso: Calendar {
        var c = Calendar(identifier: .iso8601); c.timeZone = utc; return c
    }

    /// `yyyy-MM-dd` in UTC, Gregorian, Western digits — whatever the device's
    /// calendar and language.
    public static func day(_ d: Date) -> String {
        let p = gregorian.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", locale: Locale(identifier: "en_US_POSIX"),
                      p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    static func date(ofDay s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// The flags for a ping sent `now`. A stored day that does not parse
    /// counts as none — a new install, the safe over-count of one.
    public static func flags(lastCounted: String?, now: Date) -> Flags {
        guard let s = lastCounted, let last = date(ofDay: s) else {
            return Flags(firstThisWeek: true, firstThisMonth: true, firstEver: true)
        }
        // Counted on a day after today: the clock went back. Nothing here is
        // first, or the week would count twice once the clock is right again.
        if s > day(now) { return Flags(firstThisWeek: false, firstThisMonth: false, firstEver: false) }
        let week: (Date) -> [Int?] = { d in
            let p = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
            return [p.yearForWeekOfYear, p.weekOfYear]
        }
        let month: (Date) -> [Int?] = { d in
            let p = gregorian.dateComponents([.year, .month], from: d)
            return [p.year, p.month]
        }
        return Flags(firstThisWeek: week(last) != week(now), firstThisMonth: month(last) != month(now),
                     firstEver: false)
    }

    /// Whether `version` is one the cloud takes; anything else is a 422, so
    /// it is not sent at all.
    public static func accepts(version: String) -> Bool {
        version.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,6}(-[a-z]{1,12}\.\d{1,6})?$"#,
                      options: .regularExpression) != nil
    }

    /// The body: these six fields and nothing else.
    public static func body(platform: String, channel: String, version: String, flags: Flags) -> Data {
        let fields: [String: Any] = [
            "platform": platform, "channel": channel, "version": version,
            "firstThisWeek": flags.firstThisWeek, "firstThisMonth": flags.firstThisMonth,
            "firstEver": flags.firstEver,
        ]
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    /// `0` is offline.
    public static func outcome(status: Int) -> Outcome {
        switch status {
        case 200: .counted
        case 422: .refused
        default: .retry
        }
    }

    /// What an install keeps between pings: the last COUNTED day (the flags
    /// come from it) and the last day that is DONE (a 200 or a 422). Both
    /// `yyyy-MM-dd` UTC. Switching the count off sends nothing and keeps both,
    /// so switching it back on is not a new install.
    public struct State: Equatable, Sendable {
        public var lastCounted: String?
        public var doneDay: String?
        public init(lastCounted: String? = nil, doneDay: String? = nil) {
            self.lastCounted = lastCounted; self.doneDay = doneDay
        }

        /// Whether a ping is owed at `now`: today is not done yet.
        public func due(now: Date) -> Bool { doneDay != ActiveCount.day(now) }

        /// The state after an answer to a ping sent on `now`'s day.
        public func after(_ outcome: Outcome, now: Date) -> State {
            var next = self
            switch outcome {
            case .counted:
                // Never moved backwards by a clock that went back.
                let today = ActiveCount.day(now)
                if (next.lastCounted ?? "") < today { next.lastCounted = today }
                next.doneDay = today
            case .refused: next.doneDay = ActiveCount.day(now)
            case .retry: break
            }
            return next
        }
    }
}
