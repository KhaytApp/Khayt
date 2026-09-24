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
    static var book: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// `YYYY-MM-DD` for this moment, in this calendar.
    func dayString(_ date: Date) -> String {
        let c = dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The shop's local day an ISO instant happened on. `at.prefix(10)` is the
    /// UTC day, which in Riyadh is yesterday until 03:00. A string that is
    /// not a full timestamp is returned as its first ten characters.
    static func localDay(ofInstant iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return book.dayString(d) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return book.dayString(d) }
        return String(iso.prefix(10))
    }
}
