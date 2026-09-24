import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// The book is written in the Gregorian calendar whatever the Mac is set to.
@MainActor
struct BookCalendarTests {
    @Test("the book calendar is Gregorian, and today is written as the book writes a day")
    func gregorian() {
        #expect(Calendar.book.identifier == .gregorian)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12))!
        #expect(Shop.today(day) == "2026-09-24")
    }

    @Test("no source reads the Mac's own calendar to read or write the book")
    func noCurrentCalendar() throws {
        // Calendar.current is a Hijri calendar on a Mac set to Umm al-Qura, and
        // every place that used it to write or compare a YYYY-MM-DD was wrong
        // there. Showing a date is `Words.say`; the book is `Calendar.book`.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        var offences: [String] = []
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("Calendar.current") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offences.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offences.isEmpty, "use Calendar.book: \(offences)")
    }

    @Test("a day is the shop's local midnight, and a timestamp is the local day it happened on")
    func localDays() {
        let midnight = Calendar.book.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        #expect(Order.day("2026-09-24") == midnight, "a bare day parsed as UTC shows 3:00 AM in Riyadh")
        let instant = "2026-09-24T09:15:00.000Z"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let at = iso.date(from: instant)!
        #expect(Order.day(instant) == Calendar.book.startOfDay(for: at))
        #expect(Calendar.localDay(ofInstant: instant) == Calendar.book.dayString(at))
        #expect(Calendar.localDay(ofInstant: "2026-09-24") == "2026-09-24")
        #expect(Order.day("") == nil && Order.day("soon") == nil)
    }
}
