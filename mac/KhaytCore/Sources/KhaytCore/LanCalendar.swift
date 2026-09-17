import Foundation

/// The shop's due dates as a calendar feed — ported to Swift.
///
/// One all-day event per open job with a due date, served at `/calendar.ics`
/// so a shop can subscribe to its own queue from the Calendar app or a phone.
/// Who may fetch it — the calendar token or the owner PIN — is the host's
/// gate, as it always was; this is a function of the book alone.
public enum LanCalendar {

    /// Which statuses appear, and how each is reported.
    ///
    /// A finished, delivered or cancelled job is not a due date any more.
    /// `on_hold` maps to CANCELLED rather than being dropped: the calendar
    /// keeps the entry and strikes it through, which is what a held job is —
    /// still expected, not happening now. An unknown status is TENTATIVE.
    static let statuses = ["printing": "CONFIRMED", "post": "CONFIRMED",
                           "qc": "CONFIRMED", "pending": "TENTATIVE",
                           "on_hold": "CANCELLED"]
    static let closed: Set<String> = ["completed", "delivered", "cancelled"]

    /// The iCalendar text for a book.
    public static func feed(_ store: JSONValue) -> String {
        var jobs: [JSONValue] = []
        if case .object(let root) = store, case .array(let rows)? = root["printLog"] {
            jobs = rows
        }

        var events: [String] = []
        for row in jobs {
            guard case .object(let job) = row else { continue }
            let due = JSSemantics.truthy(job["dueDate"]) ? JSSemantics.text(job["dueDate"]) : ""
            guard !due.isEmpty else { continue }
            let status = JSSemantics.text(job["status"])
            guard !closed.contains(status) else { continue }
            guard let start = day(due), let end = day(due, plusDays: 1) else { continue }

            // `o.project || o.id` — the id is the fallback, so an unnamed job
            // still says which one it is.
            let name = JSSemantics.truthy(job["project"]) ? job["project"] : job["id"]
            // `o.client || 'No client'`, escaped either way — the fallback has
            // nothing in it to escape, but running it through keeps the two
            // sides one expression rather than two that happen to agree.
            let client = escaped(JSSemantics.truthy(job["client"])
                ? JSSemantics.text(job["client"]) : "No client")
            let id = JSSemantics.text(job["id"])
            events.append([
                "BEGIN:VEVENT",
                "UID:khayt-\(id)@khaytapp.com",
                "DTSTART;VALUE=DATE:\(start)",
                "DTEND;VALUE=DATE:\(end)",
                "SUMMARY:\(escaped(JSSemantics.text(name))) (\(client))",
                "STATUS:\(statuses[status] ?? "TENTATIVE")",
                "END:VEVENT",
            ].joined(separator: "\r\n"))
        }

        var shopName = "Khayt"
        if case .object(let root) = store, case .object(let settings)? = root["settings"],
           JSSemantics.truthy(settings["shopName"]) {
            shopName = JSSemantics.text(settings["shopName"])
        }
        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Khayt//Khayt//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:\(escaped(shopName)) Orders",
            events.joined(separator: "\r\n"),
            "END:VCALENDAR",
        ].joined(separator: "\r\n")
    }

    /// `YYYY-MM-DD` as iCalendar's `YYYYMMDD`, optionally a day on.
    ///
    /// ── IT IS `new Date(due + "T00:00:00Z")`, AND THAT IS LENIENT ─────────
    ///
    /// Parsed as UTC, which is what keeps a due date on the day the shop wrote
    /// it: read in local time, a shop west of Greenwich would see every event
    /// a day early in its own calendar.
    ///
    /// The leniency is the part a port gets wrong. The original APPENDS the
    /// time to whatever it was given, so the engine also accepts a bare year
    /// and a year-month:
    ///
    ///     "2026"        → 2026-01-01
    ///     "2026-10"     → 2026-10-01
    ///     "2026-10-02T12:00:00Z" → invalid, because appending gives nonsense
    ///
    /// A job dated `2026` therefore appears in a shop's calendar on New Year's
    /// Day. That is a fault in the original, and it is REPRODUCED rather than
    /// quietly corrected: a feed people already subscribe to must not change
    /// which events it contains because it was ported. Measured against
    /// JavaScriptCore, not assumed.
    static func day(_ text: String, plusDays: Int = 0) -> String? {
        guard let parts = dateParts(text) else { return nil }
        // ── ARITHMETIC, NOT `Calendar` ────────────────────────────────────
        //
        // `Calendar` reports year 0 as year 1 of the BC era, so a job dated
        // `0000-01-01` — which the engine accepts and which this feed must
        // therefore render — came out as `00010101`. JavaScript's calendar is
        // proleptic Gregorian with a year zero and no eras, so the conversion
        // is done that way here: days since an epoch, add, convert back.
        let (y, m, d) = parts
        let moved = civil(fromDays: days(fromCivil: y, m, d) + plusDays)
        // `${y}${m}${dy}` — the MONTH and DAY are padded to two and the YEAR
        // is not. So year 0 prints as `00101`, not `00000101`, which is not a
        // date any calendar will read. Reproduced: the feed is subscribed to,
        // and a port is not the place to start emitting different events.
        return String(moved.0) + DateRange.pad(moved.1, 2) + DateRange.pad(moved.2, 2)
    }

    /// Howard Hinnant's `days_from_civil`: a proleptic Gregorian date to a day
    /// number, with no era and a real year zero.
    static func days(fromCivil y: Int, _ m: Int, _ d: Int) -> Int {
        let y = y - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                   // [0, 399]
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy           // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    /// And back again.
    static func civil(fromDays z: Int) -> (Int, Int, Int) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD`, with the missing parts defaulting to
    /// the first — the three shapes that stay valid once `T00:00:00Z` is glued
    /// to the end. Anything else is not a date here.
    static func dateParts(_ text: String) -> (Int, Int, Int)? {
        // The engine trims leading whitespace before parsing, so " 2026-10-02"
        // is a date to it. Trailing whitespace is NOT trimmed, because the
        // time is glued on after it.
        let chars = Array(text.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        func digits(_ from: Int, _ count: Int) -> Int? {
            guard chars.count >= from + count else { return nil }
            let slice = chars[from..<(from + count)]
            guard slice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(slice))
        }
        guard let year = digits(0, 4) else { return nil }
        if chars.count == 4 { return (year, 1, 1) }
        guard chars.count >= 7, chars[4] == "-", let month = digits(5, 2),
              (1...12).contains(month) else { return nil }
        if chars.count == 7 { return (year, month, 1) }
        guard chars.count == 10, chars[7] == "-", let day = digits(8, 2),
              day >= 1, day <= DateRange.daysIn(month: month, year: year)
        else { return nil }
        return (year, month, day)
    }

    /// iCalendar's own escape, and only what the original escapes.
    ///
    /// Newlines become a space — a folded line in the middle of a SUMMARY is
    /// how a feed stops parsing — and backslash, semicolon and comma are
    /// backslash-escaped because each is a field separator in this format.
    /// Colons and quotes are NOT escaped, which is correct: they are ordinary
    /// text inside a property value.
    static func escaped(_ s: String) -> String {
        // UNICODE SCALARS, not Characters. Swift treats "\r\n" as ONE grapheme
        // cluster, so a `for c in s` loop comparing against "\r" and "\n"
        // walks straight past a Windows line ending and leaves it in the feed
        // — which is exactly the thing this escape exists to remove. Caught by
        // the harness on the one corpus entry that used CRLF.
        var out = ""
        var lastWasBreak = false
        for scalar in s.unicodeScalars {
            if scalar == "\r" || scalar == "\n" {
                // `/[\r\n]+/g → ' '` — a RUN of them collapses to one space.
                if !lastWasBreak { out.append(" ") }
                lastWasBreak = true
                continue
            }
            lastWasBreak = false
            if scalar == "\\" || scalar == ";" || scalar == "," { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}
