import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A date a person reads is in the BOOK's calendar, which is Gregorian.
///
/// ── WHAT WENT WRONG ───────────────────────────────────────────────────────
///
/// A formatter left alone takes the Mac's calendar as well as its language.
/// `DatesReadInTheShopsLanguageTests` put the language right and left the
/// calendar where it was, so on a Mac set to Umm al-Qura — the default for a
/// Saudi Mac — the chart readouts said "Safar 1448 AH", the masthead named the
/// Hijri month, and a backup "saved on the 14th" was a different 14th. The
/// book, the invoices and the other app all say September 2026.
///
/// Every one of those tests passed on CI, whose runner is English and
/// Gregorian; they failed only on the Mac they were written for. So the rule is
/// held here by reading the source, not by hoping a test happens to run on a
/// Hijri Mac.
///
/// ── THE RULE ──────────────────────────────────────────────────────────────
///
/// In `KhaytApp`, `KhaytWidgetViews` and `KhaytWidgets`:
///   - no `Calendar.current` / `.autoupdatingCurrent` (also `BookCalendarTests`,
///     over every source; repeated so this file states the whole rule);
///   - a `DateFormatter()` sets `.calendar` within a few lines of being made —
///     unless it writes the time of day only (`dateStyle = .none`), which has
///     no calendar field to get wrong;
///   - a `Date.FormatStyle` goes through `words.say` (which puts the book's
///     calendar on it) or names its calendar;
///   - no `.formatted(date:time:)` and no `Text(date, style:)` — neither takes
///     a calendar at all.
@MainActor
struct DatesInTheBookCalendarTests {

    /// Uses the rule cannot see is safe, each with its reason. A line matches
    /// when it contains the snippet.
    static let allowed: [(file: String, snippet: String, why: String)] = [
        ("WidgetViews.swift", "Text(due, format: .dateTime",
         "the widget's root pins \\.calendar to Gregorian, and SwiftUI formats a Text(format:) in the environment's calendar"),
        ("WidgetViews.swift", "Text(ends, style: .relative)",
         "a countdown (\"2 hr, 5 min\") names no day, month or year; and the root's calendar is Gregorian anyway"),
    ]

    static let folders = ["KhaytApp", "KhaytWidgetViews", "KhaytWidgets"]

    @Test("no date a person reads takes the Mac's calendar")
    func everyDateIsInTheBookCalendar() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        var scanned = 0
        var offences: [String] = []
        for folder in Self.folders {
            let walker = FileManager.default.enumerator(at: sources.appending(path: folder),
                                                        includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                offences += Self.offences(in: text, file: url.lastPathComponent)
            }
        }
        #expect(scanned > 100, Comment(rawValue: "scanned only \(scanned) files — the scan has rotted"))
        #expect(offences.isEmpty, Comment(rawValue: """
            these show or compute a date in the Mac's calendar, which on a Mac set \
            to Umm al-Qura is the Hijri one. Use `words.say(date, style)`, \
            `Calendar.book`, or set `.calendar = .book` on the formatter:
              \(offences.joined(separator: "\n  "))
            """))
    }

    /// The scan, separate so its own cases can be held.
    static func offences(in text: String, file: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [String] = []
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            if allowed.contains(where: { $0.file == file && line.contains($0.snippet) }) { continue }
            let near = lines[i..<min(lines.count, i + 9)].joined(separator: "\n")
            let close = lines[i..<min(lines.count, i + 4)].joined(separator: "\n")
            let before = lines[max(0, i - 2)...i].joined(separator: "\n")
            func flag(_ why: String) { found.append("\(file):\(i + 1)  \(why)  \(line.prefix(70))") }

            if BookCalendarTests.readsTheMacCalendar(Substring(line)) {
                flag("the Mac's calendar")
            }
            // A DateFormatter (not ISO8601DateFormatter, which is Gregorian by
            // definition) must be given its calendar where it is made.
            if let made = line.range(of: #"(?:let|var)\s+(\w+)\s*=\s*DateFormatter\(\)"#,
                                     options: .regularExpression) {
                let name = line[made].split(whereSeparator: { $0 == " " || $0 == "=" })[1]
                let setsCalendar = near.contains("\(name).calendar =")
                let timeOnly = near.contains("\(name).dateStyle = .none")
                if !setsCalendar && !timeOnly { flag("DateFormatter without a calendar") }
            }
            // A FormatStyle for a date: through `say`, or with a calendar.
            if line.range(of: #"Date\.FormatStyle|\.dateTime\b"#, options: .regularExpression) != nil,
               !before.contains("say("),
               !close.contains("calendar") {
                flag("a date style without the book's calendar")
            }
            if line.range(of: #"\.formatted\(\s*date:"#, options: .regularExpression) != nil {
                flag(".formatted(date:time:) takes the Mac's calendar")
            }
            if line.range(of: #"Text\([^,]+,\s*style:\s*\.(date|time|relative|offset|timer)\b"#,
                          options: .regularExpression) != nil {
                flag("Text(date, style:) takes the Mac's calendar")
            }
        }
        return found
    }

    @Test("the scan catches each shape it claims to")
    func theScanBites() {
        let bad = """
            let f = DateFormatter()
            f.dateStyle = .medium
            let s = Date().formatted(.dateTime.month())
            let t = Date().formatted(date: .abbreviated, time: .omitted)
            Text(when, style: .date)
            let c = Calendar.current
            """
        #expect(Self.offences(in: bad, file: "X.swift").count == 5)
        let good = """
            let f = DateFormatter()
            f.calendar = .book
            let g = DateFormatter()
            g.timeStyle = .short
            g.dateStyle = .none
            words.say(at, .dateTime.day().month(.abbreviated))
            var style = Date.FormatStyle.dateTime.month(.wide)
            style.calendar = .book
            // Calendar.current, in a comment
            """
        #expect(Self.offences(in: good, file: "X.swift").isEmpty,
                Comment(rawValue: "\(Self.offences(in: good, file: "X.swift"))"))
    }

    // MARK: - On a Hijri Mac

    /// `say` is the seam: a style that arrives carrying the Mac's Umm al-Qura
    /// calendar still comes out Gregorian, in either language.
    @Test("a date is said in the book's calendar even when handed the Mac's Hijri one")
    func sayIsGregorian() async {
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = Calendar.book.timeZone
        let when = Calendar.book.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12))!
        var style = Date.FormatStyle.dateTime.day().month(.wide).year()
        style.calendar = hijri
        #expect(!when.formatted(style.locale(Locale(identifier: "en"))).contains("2026"),
                "the hazard: the Hijri calendar does not say 2026")
        for language in ["en", "ar"] {
            let words = Words()
            await words.load(language, engine: nil)
            let said = words.say(when, style)
            #expect(said.contains("2026") && said.contains("14"), Comment(rawValue: "\(language): \(said)"))
        }
        let en = Words()
        await en.load("en", engine: nil)
        #expect(en.say(when, style).contains("September"))
    }

    @Test("a month label is the Gregorian month")
    func monthLabel() {
        #expect(MonthLabel.long("2026-09", language: "en") == "September 2026")
        #expect(MonthLabel.long("2026-09", language: "ar").contains("2026"))
    }
}
