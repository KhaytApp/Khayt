import Foundation

/// How many hours a shop prints on each day of the week — ported to Swift.
///
/// ── THE DEFAULT IS THE WHOLE MODULE ───────────────────────────────────────
///
/// It used to be written out in four places as
/// `{ mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 0, sun: 0 }` — a FOUR-day
/// week, matching no working week anywhere. The Gulf works Sunday to Thursday;
/// most of Europe and the Americas work Monday to Friday. That literal is
/// neither: it takes the Gulf's weekend and loses Sunday as well.
///
/// It is not cosmetic. These hours feed the average working day, the due-date
/// suggestion on an order, the machine queue-clear date and the schedule
/// projection — so a shop that never opened Working Hours had every one of
/// those computed against four days instead of five, and quoted dates further
/// out than it needed to.
///
/// Khayt's primary market is Saudi Arabia, so the default is Sunday to
/// Thursday. A shop that has set its own hours is untouched.
public enum WorkingWeek {

    /// Day keys, in the order the settings grid shows them — and in `getDay()`
    /// order, which is what `hoursOnDay` indexes with.
    public static let dayKeys = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// Sunday to Thursday, eight hours, Friday–Saturday weekend.
    public static let defaultHours: [String: Double] = [
        "sun": 8, "mon": 8, "tue": 8, "wed": 8, "thu": 8, "fri": 0, "sat": 0,
    ]

    /// The shop's hours, or the default — never a partial answer.
    ///
    /// A stored value missing a day is that day CLOSED rather than that day at
    /// the default's hours: a shop that edited its week meant what it left out.
    /// Capped at 24 because a day is 24 hours, and anything that is not a
    /// finite positive number is zero.
    public static func hours(settings: JSONValue?) -> [String: Double] {
        guard case .object(let s)? = settings else { return defaultHours }
        let stored = s["workingHours"]
        // `!wh || typeof wh !== 'object'` — and in JavaScript an ARRAY IS AN
        // OBJECT. So a `workingHours: [8]` left behind by some bad write does
        // NOT fall back to the default: it reads every day off an array that
        // has none of them and comes out as a shop that never opens. Reading
        // it as "not an object, use the default" gives a shop a full week it
        // did not ask for, and the harness caught exactly that.
        let week: [String: JSONValue]
        switch stored {
        case .object(let o): week = o
        case .array: week = [:]
        default: return defaultHours
        }
        var out: [String: Double] = [:]
        for key in dayKeys {
            let n = JSSemantics.number(week[key])
            out[key] = (n.isFinite && n > 0) ? Swift.min(24, n) : 0
        }
        return out
    }

    /// Hours on one day, by `getDay()` index — 0 is Sunday.
    ///
    /// The index wraps in both directions, the way the original's
    /// `((n % 7) + 7) % 7` does: -1 is Saturday, not a crash.
    public static func hoursOnDay(settings: JSONValue?, dayIndex: Double) -> Double {
        // `DAY_KEYS[((n % 7) + 7) % 7]` — an ARRAY SUBSCRIPT, and JavaScript
        // does not round one. `DAY_KEYS[0.5]` is `undefined`, so the day has no
        // hours; truncating to Sunday would hand back Sunday's. Same for NaN,
        // which indexes nothing either. Only a whole index names a day.
        let n = dayIndex
        guard n.isFinite, n == n.rounded(.towardZero) else { return 0 }
        let index = Int((n.truncatingRemainder(dividingBy: 7) + 7)
            .truncatingRemainder(dividingBy: 7))
        guard dayKeys.indices.contains(index) else { return 0 }
        return hours(settings: settings)[dayKeys[index]] ?? 0
    }

    /// Days a week the shop actually works — what a lead-time promise counts in.
    public static func workingDaysPerWeek(settings: JSONValue?) -> Int {
        let week = hours(settings: settings)
        return dayKeys.filter { (week[$0] ?? 0) > 0 }.count
    }

    /// Which days the shop is open, by `getDay()` index.
    public static func openDays(settings: JSONValue?) -> [Bool] {
        let week = hours(settings: settings)
        return dayKeys.map { (week[$0] ?? 0) > 0 }
    }

    /// The shop's average working hours per CALENDAR day.
    ///
    /// Weekly hours over SEVEN, not over the days it opens: a job printing
    /// through a weekend still takes those days off the calendar, and a
    /// delivery date is a calendar date. Eight when the shop has not said.
    public static func dailyWorkingHours(settings: JSONValue?) -> Double {
        // Every value the object holds, not only the seven day keys — the
        // original reduces over `Object.values`, so a stray key would count.
        // `hours()` only ever returns the seven, which is what makes the two
        // agree; the note is here because it is not obvious from the call.
        let total = hours(settings: settings).values.reduce(0.0) { $0 + ($1 > 0 ? $1 : 0) }
        return total > 0 ? total / 7 : 8
    }
}
