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

    @Test("every timestamp shape the book holds is read, the same as the old per-call formatter")
    func timestamps() {
        let old = { (iso: String) -> Date? in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: iso) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: iso)
        }
        for iso in ["2026-09-24T09:15:00.000Z", "2026-09-24T09:15:00Z", "2026-09-24T12:15:00+03:00",
                    "2026-09-24T12:15:00.123+03:00", "2026-09-24T09:15:00.5Z"] {
            #expect(Calendar.instant(iso) != nil, "\(iso)")
            // To the millisecond: the two parsers round a fraction's last
            // binary digit differently, which is not a different moment.
            #expect(abs((Calendar.instant(iso) ?? .distantPast).timeIntervalSince(old(iso) ?? .distantFuture)) < 0.001,
                    "\(iso) reads differently")
        }
        #expect(Calendar.instant("2026-09-24") == nil && Calendar.instant("soon") == nil)
    }

    @Test("sorting a big library reads each date once, not per comparison")
    @MainActor
    func sortCost() throws {
        let files = try (0..<400).map { i -> LibraryFile in
            let json: [String: Any] = ["id": "PF-\(i)", "name": "m\(i)", "favorite": i % 17 == 0,
                                       "updatedAt": String(format: "2026-09-%02dT10:00:00.000Z", i % 28 + 1)]
            return try JSONDecoder().decode(LibraryFile.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let began = Date()
        let sorted = LibrarySort.khayt.sorted(files)
        #expect(Date().timeIntervalSince(began) < 0.2, "sorting 400 models took over 200 ms")
        #expect(sorted.first?.isFavourite == true, "favourites first")
        #expect(sorted == files.sorted(by: LibrarySort.khayt.order), "the same order as the comparator")
    }
}
