import Foundation

/// Which records fall in a period — "this month", "last quarter", a custom
/// span. Ported to Swift.
///
/// ── DATES ARE COMPARED AS STRINGS, ON PURPOSE ─────────────────────────────
///
/// A record's date is written in the shop's LOCAL time as `YYYY-MM-DD`.
/// Comparing it as a date would shift it by a day at either end of the month
/// for any shop not on UTC, so "this month" would gain or lose a record at the
/// boundary depending on where the shop is. The strings are already in the
/// shop's calendar; slicing them keeps them there.
///
/// The clock is passed in for the same reason every rule here takes one: a
/// period that reads a clock inside itself cannot be tested for the day it
/// gets wrong.
public enum DateRange {

    public static let ranges = ["all", "month", "last_month", "quarter",
                                "last_quarter", "year", "custom"]

    /// A date as the shop writes a day: `YYYY-MM-DD`, in local time.
    public static func localDay(_ date: Date, calendar: Calendar = .current) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return pad(p.year ?? 0, 4) + "-" + pad(p.month ?? 0, 2) + "-" + pad(p.day ?? 0, 2)
    }

    /// `YYYY-MM`, in local time.
    public static func localMonth(_ date: Date, calendar: Calendar = .current) -> String {
        let p = calendar.dateComponents([.year, .month], from: date)
        return pad(p.year ?? 0, 4) + "-" + pad(p.month ?? 0, 2)
    }

    public struct Custom: Sendable {
        public let from: String
        public let to: String
        public init(from: String = "", to: String = "") { self.from = from; self.to = to }
    }

    /// Does this record's date fall in the period, when the date is whatever
    /// the book happened to store?
    ///
    /// The JavaScript is handed the field itself and coerces it on the way
    /// past: a falsy value — absent, `null`, `0`, `false`, an empty string —
    /// fails the `if (!dateStr)` guard, and anything else is stringified. Put
    /// here rather than at each call site so the coercion is the module's and
    /// is covered by the module's own parity test.
    public static func inRange(_ date: JSONValue?, range: String?,
                               now: Date = Date(), custom: Custom = Custom(),
                               calendar: Calendar = .current) -> Bool {
        let text = JSSemantics.truthy(date) ? JSSemantics.text(date) : nil
        return inRange(text, range: range, now: now, custom: custom, calendar: calendar)
    }

    /// Does this record's date fall in the period?
    public static func inRange(_ dateStr: String?, range: String?,
                               now: Date = Date(), custom: Custom = Custom(),
                               calendar: Calendar = .current) -> Bool {
        guard let range, !range.isEmpty else { return true }
        if range == "all" { return true }
        guard let dateStr, !dateStr.isEmpty else { return false }

        // ── ONE DELIBERATE CHANGE, INHERITED FROM THE ORIGINAL ─────────────
        //
        // The renderer asked only whether the string parsed and then sliced
        // it, so a record dated "2026" fell out of every period except `year`,
        // which it landed in because the first four characters happen to be
        // the year. A malformed date filed into a period by accident is worse
        // than one left out of all of them. Every record Khayt writes is
        // `YYYY-MM-DD`, so nothing a shop has changes.
        guard startsWithADay(dateStr), isParseableDate(dateStr) else { return false }

        let ds = String(dateStr.prefix(10))

        if range == "custom" {
            // Neither end set is no filter at all — the picker's own "any".
            if custom.from.isEmpty && custom.to.isEmpty { return true }
            if !custom.from.isEmpty && ds < custom.from { return false }
            if !custom.to.isEmpty && ds > custom.to { return false }
            return true
        }

        let nowParts = calendar.dateComponents([.year, .month], from: now)
        let nowYear = nowParts.year ?? 0
        let nowMonth = (nowParts.month ?? 1) - 1      // `getMonth()` is 0-based

        switch range {
        case "month":
            return ds.prefix(7) == "\(pad(nowYear, 4))-\(pad(nowMonth + 1, 2))"
        case "last_month":
            // `new Date(y, m - 1, 1)` rolls the year over by itself.
            let (y, m) = rolled(year: nowYear, month: nowMonth - 1)
            return ds.prefix(7) == "\(pad(y, 4))-\(pad(m + 1, 2))"
        case "quarter":
            let dsMonth = (Int(ds.dropFirst(5).prefix(2)) ?? 1) - 1
            let dsYear = Int(ds.prefix(4)) ?? 0
            return dsYear == nowYear && floorDiv(dsMonth, 3) == floorDiv(nowMonth, 3)
        case "last_quarter":
            // `new Date(y, m - (m % 3), 0)` — day zero is the day BEFORE the
            // first of that month, so this is the last day of the previous
            // quarter, and the start is that quarter's first month.
            let (endY, endM) = rolled(year: nowYear, month: nowMonth - (nowMonth % 3))
            guard let firstOfQuarter = calendar.date(from: DateComponents(year: endY, month: endM + 1, day: 1)),
                  let lastQEnd = calendar.date(byAdding: .day, value: -1, to: firstOfQuarter)
            else { return false }
            let endParts = calendar.dateComponents([.year, .month], from: lastQEnd)
            let startMonth = floorDiv((endParts.month ?? 1) - 1, 3) * 3
            guard let lastQStart = calendar.date(from: DateComponents(
                year: endParts.year, month: startMonth + 1, day: 1)) else { return false }
            return ds >= localDay(lastQStart, calendar: calendar)
                && ds <= localDay(lastQEnd, calendar: calendar)
        case "year":
            return ds.prefix(4) == pad(nowYear, 4)
        default:
            // An unknown period lets everything through, like the original's
            // final `return true` — a picker offering a value this does not
            // know shows the whole book rather than an empty screen.
            return true
        }
    }

    // MARK: - The bits that have to behave like JavaScript

    /// `/^\d{4}-\d{2}-\d{2}/` — anchored at the start, and the tail is not
    /// this test's business.
    static func startsWithADay(_ s: String) -> Bool {
        let d = Array(s.utf8)
        guard d.count >= 10 else { return false }
        func digit(_ i: Int) -> Bool { d[i] >= 48 && d[i] <= 57 }
        return digit(0) && digit(1) && digit(2) && digit(3) && d[4] == 45
            && digit(5) && digit(6) && d[7] == 45 && digit(8) && digit(9)
    }

    /// Would `new Date(s)` produce something other than Invalid Date?
    ///
    /// Only asked of strings that already start `YYYY-MM-DD`, which narrows it
    /// to the date-time grammar — and the grammar that matters is the one the
    /// ENGINE implements, not the one the specification writes down. Those
    /// differ, so this was measured rather than transcribed: a probe asked
    /// JavaScriptCore about every boundary in turn, and the surprises were
    ///
    ///   * `23:59:60` is ACCEPTED — a leap second, which the spec's `00`–`59`
    ///     would refuse;
    ///   * `24:00:00` is accepted but `24:00:01` is not;
    ///   * a lowercase `t` separator is accepted and a lowercase `z` zone is
    ///     not, which is not a symmetry anybody would guess;
    ///   * an offset needs two digits an hour (`+3:30` is refused) and may
    ///     drop its colon (`+0330` is fine).
    ///
    /// `DateFormatter` is no use here: it is lenient in different places than
    /// this is, so it would agree on the ordinary cases and quietly differ on
    /// exactly these.
    static func isParseableDate(_ s: String) -> Bool {
        let chars = Array(s)
        let year = Int(String(chars[0..<4])) ?? 0
        let month = Int(String(chars[5..<7])) ?? 0
        let day = Int(String(chars[8..<10])) ?? 0
        guard (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year)
        else { return false }
        guard chars.count > 10 else { return true }

        guard chars[10] == "T" || chars[10] == "t" || chars[10] == " " else { return false }
        var rest = Array(chars[11...])
        guard !rest.isEmpty else { return false }

        // The zone, if there is one. Uppercase `Z` only.
        if rest.last == "Z" {
            rest.removeLast()
        } else if let sign = rest.lastIndex(where: { $0 == "+" || $0 == "-" }),
                  sign >= rest.count - 6, sign > 0 {
            guard offsetIsValid(Array(rest[(sign + 1)...])) else { return false }
            rest = Array(rest[..<sign])
        }

        // HH:MM[:SS][.sss]
        let bits = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if bits.count == 2 {
            // At least one digit, and only digits. `12:00:00.` is refused.
            guard !bits[1].isEmpty, bits[1].allSatisfy(\.isASCIIDigit) else { return false }
        }
        let clock = bits[0].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2 || clock.count == 3 else { return false }
        guard clock.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCIIDigit) }) else { return false }
        let hour = Int(String(clock[0])) ?? 99, minute = Int(String(clock[1])) ?? 99
        let second = clock.count == 3 ? (Int(String(clock[2])) ?? 99) : 0
        // Midnight at the far end of the day is a real time, and only at
        // exactly midnight.
        if hour == 24 { return minute == 0 && second == 0 }
        // 60 seconds: a leap second, which this engine takes.
        return hour < 24 && minute < 60 && second <= 60
    }

    /// `HH:MM` or `HHMM` after the sign.
    private static func offsetIsValid(_ offset: [Character]) -> Bool {
        let digits: [Character]
        if offset.count == 5 && offset[2] == ":" {
            digits = Array(offset[0..<2]) + Array(offset[3..<5])
        } else if offset.count == 4 {
            digits = offset
        } else {
            return false
        }
        guard digits.allSatisfy(\.isASCIIDigit) else { return false }
        let hours = Int(String(digits[0..<2])) ?? 99
        let minutes = Int(String(digits[2..<4])) ?? 99
        return hours < 24 && minutes < 60
    }

    // MARK: - Small things, spelled JavaScript's way

    static func pad(_ n: Int, _ width: Int) -> String {
        let text = String(n)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    /// `Math.floor(a / b)` for integers — which rounds toward NEGATIVE
    /// infinity, unlike Swift's `/`. Only matters for a negative month index,
    /// which `nowMonth - (nowMonth % 3)` cannot produce and the quarter
    /// comparison can, from a malformed `ds`.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// A 0-based month index outside 0…11, rolled into a year and a month the
    /// way `new Date(y, m, 1)` does.
    static func rolled(year: Int, month: Int) -> (Int, Int) {
        var y = year, m = month
        while m < 0 { m += 12; y -= 1 }
        while m > 11 { m -= 12; y += 1 }
        return (y, m)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        default: return 0
        }
    }
}

private extension Character {
    /// Not `isNumber`, which is true of Arabic-Indic and every other script's
    /// digits — and `new Date("2026-09-17T١٢:00:00")` is Invalid Date.
    var isASCIIDigit: Bool { isASCII && isNumber }
}
