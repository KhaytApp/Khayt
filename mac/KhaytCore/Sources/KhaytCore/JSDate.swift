import Foundation

/// `Date.parse` and the local-calendar readers, as JavaScript does them.
///
/// ── WHY THIS IS ITS OWN FILE ──────────────────────────────────────────────
///
/// Several rules bucket records by month, and every one of them reads the
/// month in LOCAL time while parsing the stamp by a rule that is sometimes UTC
/// and sometimes not. `lib/forecast.js` carries the scar in a comment:
///
///   > Using UTC in a UTC+3 shop put orders completed between 00:00 and 03:00
///   > on the 1st into the PREVIOUS month, and — because curKey is derived
///   > from Date.now() the same way — slid the entire forecast window back a
///   > month when the app was opened in those hours. The tests never caught
///   > it: they build both "now" and the fixtures with Date.UTC, so they were
///   > self-consistently wrong.
///
/// A port that gets this wrong is that bug again, and it is not visible in a
/// test that constructs its own fixtures the same way it constructs its clock.
/// So the rule is written out once, here, and checked against the engine.
public enum JSDate {

    /// `Date.parse(s)` — milliseconds since the epoch, or nil for NaN.
    ///
    /// ── THE PART THAT SURPRISES ───────────────────────────────────────────
    ///
    /// **A date with no time is UTC. A date WITH a time and no zone is LOCAL.**
    /// That is the specification, and it means `2026-09-01` and
    /// `2026-09-01T00:00:00` are different instants in every shop that is not
    /// on UTC — three hours apart in Riyadh, and on different calendar days in
    /// the Americas. The book holds both spellings, so the difference is real
    /// rather than theoretical.
    public static func parse(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        guard let form = form(of: text) else { return nil }
        let days = LanCalendar.days(fromCivil: form.year, form.month, form.day)
        var ms = Double(days) * 86_400_000
            + Double(form.hour) * 3_600_000 + Double(form.minute) * 60_000
            + Double(form.second) * 1000 + Double(form.milli)
        switch form.zone {
        case .utc: break
        case .offset(let minutes): ms -= Double(minutes) * 60_000
        case .local:
            // The local offset AT THAT INSTANT, not today's — a stamp from
            // August in a zone that moves for summer time is read with
            // August's offset. `TimeZone` is asked, rather than a constant.
            let guess = Date(timeIntervalSince1970: ms / 1000)
            ms -= Double(TimeZone.current.secondsFromGMT(for: guess)) * 1000
        }
        return ms
    }

    /// `new Date(ms).getFullYear()` and `.getMonth()` — LOCAL, and the month
    /// is zero-based because everything that consumes it is.
    public static func localYearMonth(ms: Double) -> (year: Int, month: Int) {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let shifted = ms / 1000 + Double(TimeZone.current.secondsFromGMT(for: date))
        let days = Int(floor(shifted / 86_400))
        let civil = LanCalendar.civil(fromDays: days)
        return (civil.0, civil.1 - 1)
    }

    /// `getDay()` and `getHours()` — LOCAL, like every other reader here.
    ///
    /// `getDay()` is 0 for Sunday, which is what the working week is indexed
    /// by. The 1st of January 1970 was a Thursday, and the arithmetic is
    /// anchored on that rather than on a `Calendar`, for the same reason
    /// `localYearMonth` is: a `Calendar` brings a first-weekday preference and
    /// an era with it, and JavaScript has neither.
    public static func localDayAndHour(ms: Double) -> (weekday: Int, hour: Int) {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let shifted = ms / 1000 + Double(TimeZone.current.secondsFromGMT(for: date))
        let days = Int(floor(shifted / 86_400))
        let secondsIntoDay = shifted - Double(days) * 86_400
        // 1970-01-01 was a Thursday — day 4 counting Sunday as 0 — and the
        // modulo is floored so days before the epoch land in 0...6 too.
        let weekday = ((days + 4) % 7 + 7) % 7
        return (weekday, Int(floor(secondsIntoDay / 3600)))
    }

    /// What a parsed stamp is made of.
    struct Form {
        var year = 0, month = 1, day = 1
        var hour = 0, minute = 0, second = 0, milli = 0
        var zone: Zone = .utc
    }
    enum Zone { case utc, local, offset(Int) }

    /// The date-time string grammar, as far as the book ever uses it.
    ///
    /// ── AND THAT SCOPE IS DELIBERATE, AND MEASURED ────────────────────────
    ///
    /// `Date.parse` has a second, implementation-defined half: the engine also
    /// takes `2026/09/17`, `2026-9-17`, `Sep 17 2026` and a long tail besides,
    /// as LOCAL time. Reproducing that is an unbounded job with no
    /// specification to hold it to.
    ///
    /// It is also unnecessary. Counted across both books:
    ///
    ///     573  YYYY-MM-DDTHH:MM:SS.sssZ
    ///      61  YYYY-MM-DDTHH:MM:SS.ssssssZ
    ///     246  YYYY-MM-DD
    ///     153  YYYY-MM-DDTHH:MM:SSZ
    ///
    /// — every one of them ISO, because every one was written by Khayt. So
    /// this covers the grammar the book HAS, and `JSDateParityTests` pins the
    /// boundary so the difference is a decision on the record rather than a
    /// surprise. (The six-digit fraction is why only the first three are read:
    /// that is the specification, and the harness confirms the engine agrees.)
    ///
    /// Deliberately NOT `DateFormatter` either: it is lenient in different
    /// places than the engine is, so it would agree on the ordinary stamps and
    /// differ on exactly the ones worth testing.
    static func form(of text: String) -> Form? {
        // The engine trims leading whitespace.
        let s = Array(text.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        func digits(_ from: Int, _ count: Int) -> Int? {
            guard s.count >= from + count else { return nil }
            let slice = s[from..<(from + count)]
            guard slice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(slice))
        }
        guard let year = digits(0, 4) else { return nil }
        var form = Form(year: year)

        if s.count == 4 { return form }                       // YYYY — UTC
        guard s.count >= 7, s[4] == "-", let month = digits(5, 2),
              (1...12).contains(month) else { return nil }
        form.month = month
        if s.count == 7 { return form }                       // YYYY-MM — UTC
        guard s.count >= 10, s[7] == "-", let day = digits(8, 2),
              day >= 1, day <= DateRange.daysIn(month: month, year: year) else { return nil }
        form.day = day
        if s.count == 10 { return form }                      // YYYY-MM-DD — UTC

        guard s[10] == "T" || s[10] == "t" || s[10] == " " else { return nil }
        var rest = Array(s[11...])
        guard !rest.isEmpty else { return nil }

        // A time with NO zone is LOCAL — this is the whole trap.
        form.zone = .local
        if rest.last == "Z" {
            form.zone = .utc
            rest.removeLast()
        } else if let sign = rest.lastIndex(where: { $0 == "+" || $0 == "-" }),
                  sign >= rest.count - 6, sign > 0 {
            guard let minutes = offsetMinutes(Array(rest[(sign + 1)...])) else { return nil }
            form.zone = .offset(rest[sign] == "-" ? -minutes : minutes)
            rest = Array(rest[..<sign])
        }

        let bits = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if bits.count == 2 {
            guard !bits[1].isEmpty, bits[1].allSatisfy({ $0.isASCII && $0.isNumber })
            else { return nil }
            // Only the first three digits count; the rest are dropped, not
            // rounded.
            let padded = (String(bits[1]) + "000").prefix(3)
            form.milli = Int(padded) ?? 0
        }
        let clock = bits[0].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2 || clock.count == 3,
              clock.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        form.hour = Int(String(clock[0])) ?? 99
        form.minute = Int(String(clock[1])) ?? 99
        form.second = clock.count == 3 ? (Int(String(clock[2])) ?? 99) : 0
        if form.hour == 24 { return form.minute == 0 && form.second == 0 ? form : nil }
        guard form.hour < 24, form.minute < 60, form.second <= 60 else { return nil }
        return form
    }

    /// `HH:MM` or `HHMM` after the sign, as minutes.
    static func offsetMinutes(_ offset: [Character]) -> Int? {
        let digits: [Character]
        if offset.count == 5 && offset[2] == ":" {
            digits = Array(offset[0..<2]) + Array(offset[3..<5])
        } else if offset.count == 4 {
            digits = offset
        } else { return nil }
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let hours = Int(String(digits[0..<2])) ?? 99
        let minutes = Int(String(digits[2..<4])) ?? 99
        guard hours < 24, minutes < 60 else { return nil }
        return hours * 60 + minutes
    }
}
