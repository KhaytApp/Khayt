import Foundation

public extension Calendar {
    /// The calendar a Khayt book is written in: Gregorian, in this device's
    /// time zone. NEVER `Calendar.current`.
    ///
    /// Every day in the book is `YYYY-MM-DD` in the Gregorian calendar — the
    /// other app writes it that way, the cloud and the phone read it that way.
    /// A Mac set to the Islamic (Umm al-Qura) calendar, which a shop in Saudi
    /// Arabia may well choose, turned `Calendar.current` into a Hijri calendar,
    /// and `Shop.today()` then wrote "1448-04-02" into the book as today's
    /// date. Found by the September 2026 scan. Showing a date in the shop's own
    /// calendar is `Words.say`'s job; reading and writing the book is this.
    ///
    /// ONE calendar, made once: a sort of the library asks it thousands of
    /// times, and building a fresh `Calendar` per question cost the shop a
    /// second every time the library opened (Sep 2026). `autoupdatingCurrent`
    /// keeps it on the Mac's time zone if that changes while the app runs.
    static let book: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// `YYYY-MM-DD` for this moment, in this calendar.
    func dayString(_ date: Date) -> String {
        let c = dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The shop's local day an ISO instant happened on. `at.prefix(10)` is the
    /// UTC day, which in Riyadh is yesterday until 03:00. A string that is
    /// not a full timestamp is returned as its first ten characters.
    static func localDay(ofInstant iso: String) -> String {
        if let d = instant(iso) { return book.dayString(d) }
        return String(iso.prefix(10))
    }

    /// A full ISO timestamp, with or without fractional seconds — parsed by
    /// two styles made ONCE (a formatter per call cost the library a second
    /// per draw, Sep 2026).
    static func instant(_ iso: String) -> Date? {
        (try? isoFractional.parse(iso)) ?? (try? isoWhole.parse(iso))
    }
    // Value types, Sendable: made once, shared by every thread safely.
    // `timeZoneSeparator: .colon`: the book holds `+03:00` as well as `Z`, and
    // the default style reads only `+0300`.
    private static let isoFractional = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true)
    private static let isoWhole = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)
}
