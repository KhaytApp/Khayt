import Foundation
import Testing
@testable import KhaytCore

/// The shop's due dates as a calendar feed, against the JavaScript it came
/// from.
///
/// This one is subscribed to. A shop adds the URL to Calendar once and then
/// trusts whatever appears in it — so a feed that parses on one app and not
/// the other, or puts an event a day out, is wrong in a way nobody
/// investigates until a job is missed. Compared as TEXT, byte for byte,
/// including the CRLF line endings the format requires.
@MainActor
struct LanCalendarParityTests {

    private func js() throws -> JSModule { try JSModule(["lan-calendar"]) }

    private func theirs(_ js: JSModule, _ store: JSONValue) throws -> String {
        if case .string(let s) = try js.value("globalThis.KhaytLanCalendar.feed(ARG0)", [store]) {
            return s
        }
        return "«not a string»"
    }

    private func check(_ store: JSONValue, _ what: String, _ js: JSModule) throws {
        let mine = LanCalendar.feed(store)
        let theirs = try theirs(js, store)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n--- swift\n\(mine)\n--- js\n\(theirs)"))
    }

    private func book(_ jobs: [JSONValue], shopName: JSONValue? = nil) -> JSONValue {
        var root: [String: JSONValue] = ["printLog": .array(jobs)]
        if let shopName { root["settings"] = .object(["shopName": shopName]) }
        return .object(root)
    }

    private func job(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    @Test("a real queue")
    func realQueue() throws {
        let js = try js()
        try check(book([
            job(["id": .string("ORD-1"), "project": .string("Turbine bracket"),
                 "client": .string("KAUST Prototyping Lab"), "status": .string("printing"),
                 "dueDate": .string("2026-10-02")]),
            job(["id": .string("ORD-2"), "project": .string("Lamp ×4"),
                 "client": .string("ليلى"), "status": .string("pending"),
                 "dueDate": .string("2026-09-30")]),
            job(["id": .string("ORD-3"), "project": .string("Held part"),
                 "status": .string("on_hold"), "dueDate": .string("2026-11-01")]),
        ], shopName: .string("Khayt Riyadh")), "a queue", js)
    }

    @Test("only open jobs with a date appear")
    func onlyOpenJobs() throws {
        let js = try js()
        var jobs: [JSONValue] = []
        for status in ["printing", "post", "qc", "pending", "on_hold", "quote",
                       "completed", "delivered", "cancelled", "split", "", "nonsense"] {
            jobs.append(job(["id": .string("O-\(status)"), "project": .string(status),
                             "status": .string(status), "dueDate": .string("2026-10-02")]))
        }
        // And jobs with no date, which never appear whatever their status.
        jobs.append(job(["id": .string("O-nodate"), "status": .string("printing")]))
        jobs.append(job(["id": .string("O-blank"), "status": .string("printing"),
                         "dueDate": .string("")]))
        jobs.append(job(["id": .string("O-null"), "status": .string("printing"),
                         "dueDate": .null]))
        try check(book(jobs), "every status", js)
    }

    @Test("a date that is not a date is skipped, not printed wrong")
    func baddatesAreSkipped() throws {
        let js = try js()
        for due in ["2026-13-01", "2026-02-30", "2026", "2026-10", "not a date",
                    "2026-10-02T12:00:00Z", "2026-10-02 ", " 2026-10-02",
                    "0000-01-01", "9999-12-31", "2024-02-29", "2026-02-28"] {
            try check(book([job(["id": .string("O-1"), "project": .string("p"),
                                 "status": .string("printing"), "dueDate": .string(due)])]),
                      "due \(due)", js)
        }
    }

    @Test("the day after is the day after, across every boundary")
    func dtendRollsOver() throws {
        // DTEND is exclusive, so an all-day event on the 31st ends on the 1st.
        // Month ends, year ends and a leap day are where an off-by-one shows.
        let js = try js()
        for due in ["2026-01-31", "2026-02-28", "2024-02-28", "2024-02-29",
                    "2026-04-30", "2026-12-31", "2026-06-30", "2026-03-01"] {
            try check(book([job(["id": .string("O-1"), "project": .string("p"),
                                 "status": .string("printing"), "dueDate": .string(due)])]),
                      "due \(due)", js)
        }
    }

    @Test("a name that would break the feed is escaped, and only what needs it")
    func escapingMatches() throws {
        // A backslash, a semicolon and a comma each separate fields in this
        // format. A newline inside a SUMMARY is how a feed stops parsing.
        // A colon and a quote are ordinary text and must NOT be escaped.
        let js = try js()
        for name in ["Plain", "A, B", "A; B", "A\\B", "A\nB", "A\r\nB", "A\n\n\nB",
                     "A: B", "A \"B\"", "semi;comma,back\\slash", "", "   ",
                     "🧵 spool", "قوس توربين", "line1\rline2", "\n", "\\\\", ",,,"] {
            try check(book([job(["id": .string("O-1"), "project": .string(name),
                                 "client": .string(name), "status": .string("printing"),
                                 "dueDate": .string("2026-10-02")])]),
                      "name \(name.debugDescription)", js)
        }
    }

    @Test("the shop's name is escaped too, and falls back")
    func shopNameMatches() throws {
        let js = try js()
        // Only the values the original survives — see the test below for the
        // ones that make it throw.
        for name in [JSONValue.string("Khayt; Riyadh"), .string(""), .null,
                     .string("A\nB"), .string("A\r\nB"), .bool(false)] {
            try check(book([], shopName: name), "shop \(name)", js)
        }
        // And with no settings object at all.
        try check(.object(["printLog": .array([])]), "no settings", js)
        try check(.object([:]), "an empty book", js)
    }

    /// ── ONE PLACE THE PORT DELIBERATELY DOES NOT AGREE ────────────────────
    ///
    /// `(store.settings?.shopName || 'Khayt').replace(…)`. A shop name that is
    /// truthy but not a string — a number, `true`, an array, an object — has
    /// no `.replace`, so the ORIGINAL THROWS. On the LAN server that is a
    /// subscribed calendar URL answering with a failure, for ever, because
    /// somebody's shop name was recorded as a number.
    ///
    /// The port coerces it, which is what every other name in this file does.
    /// Recorded rather than silently improved, and pinned both ways so the
    /// day the original stops throwing this test says so.
    @Test("a shop name that is not a string serves a feed here, where the original throws")
    func nonStringShopNameIsWhereThePortDiverges() throws {
        let js = try js()
        for name in [JSONValue.number(7), .bool(true), .array([]), .object([:])] {
            let store = book([], shopName: name)
            // Swift: a feed, with the name coerced the way JavaScript would.
            let mine = LanCalendar.feed(store)
            #expect(mine.contains("X-WR-CALNAME:"), Comment(rawValue: "no feed for \(name)"))
            #expect(mine.hasPrefix("BEGIN:VCALENDAR"))
            // JavaScript: an exception, which the harness reports as no answer.
            var threw = false
            do { _ = try theirs(js, store) } catch { threw = true }
            #expect(threw, Comment(rawValue:
                "the original no longer throws for \(name) — this divergence can go"))
        }
    }

    @Test("an unnamed job falls back to its id")
    func projectFallsBackToId() throws {
        let js = try js()
        for project in [JSONValue.null, .string(""), .number(0), .bool(false),
                        .string("named"), .number(7)] {
            try check(book([job(["id": .string("ORD-99"), "project": project,
                                 "status": .string("printing"),
                                 "dueDate": .string("2026-10-02")])]),
                      "project \(project)", js)
        }
    }

    @Test("rows that are not jobs, and a book that is not a book")
    func degenerateBooks() throws {
        let js = try js()
        // `null` is the exception — see the divergence test below.
        try check(book([.string("x"), .number(3), .array([]), .bool(true)]),
                  "rows that are not objects", js)
        // A missing or null printLog is an empty book to both. A truthy
        // non-array is not — see the divergence test.
        for store in [JSONValue.object(["printLog": .null]), .object([:])] {
            try check(store, "printLog \(store)", js)
        }
    }

    /// ── WHERE THE PORT DELIBERATELY DOES NOT AGREE ────────────────────────
    ///
    /// The original assumes the book holds the shapes it expects, and throws
    /// when it does not. On the LAN server each of these is a SUBSCRIBED
    /// calendar URL answering with a failure, for ever, because of one odd row
    /// or one oddly-typed setting:
    ///
    ///   * `printLog.filter(…)` — a truthy non-array has no `.filter`;
    ///   * `o.dueDate` — a `null` row has no property to read;
    ///   * `(shopName || 'Khayt').replace(…)` — a number, `true`, an array or
    ///     an object has no `.replace`.
    ///
    /// The port treats each as the empty or coerced thing it is and serves the
    /// feed, which is what the rest of this app does with a malformed book.
    /// Recorded rather than silently improved, and pinned BOTH ways — the day
    /// the original stops throwing, these say so and can go.
    @Test("a malformed book serves a feed here, where the original throws")
    func malformedBooksAreWhereThePortDiverges() throws {
        let js = try js()
        let real = job(["id": .string("O-1"), "project": .string("p"),
                        "status": .string("printing"), "dueDate": .string("2026-10-02")])
        var cases: [(String, JSONValue)] = [
            ("printLog is a string", .object(["printLog": .string("x")])),
            ("printLog is an object", .object(["printLog": .object([:])])),
            ("printLog is a number", .object(["printLog": .number(3)])),
            ("a null row", book([.null, real])),
        ]
        for name in [JSONValue.number(7), .bool(true), .array([]), .object([:])] {
            cases.append(("shopName is \(name)", book([real], shopName: name)))
        }
        for (what, store) in cases {
            let mine = LanCalendar.feed(store)
            #expect(mine.hasPrefix("BEGIN:VCALENDAR"), Comment(rawValue: "no feed for \(what)"))
            #expect(mine.hasSuffix("END:VCALENDAR"))
            var threw = false
            do { _ = try theirs(js, store) } catch { threw = true }
            #expect(threw, Comment(rawValue:
                "the original no longer throws for \(what) — that divergence can go"))
        }
        // And the real job survives beside the bad row, rather than the whole
        // feed being lost with it.
        #expect(LanCalendar.feed(book([.null, real])).contains("UID:khayt-O-1@khaytapp.com"))
    }

    @Test("the feed is CRLF throughout, as the format requires")
    func lineEndingsAreRight() throws {
        let feed = LanCalendar.feed(book([
            job(["id": .string("O-1"), "project": .string("p"),
                 "status": .string("printing"), "dueDate": .string("2026-10-02")])]))
        #expect(feed.contains("\r\n"))
        // No bare LF anywhere: a calendar client is entitled to reject one.
        var previous: Character = " "
        for c in feed {
            if c == "\n" { #expect(previous == "\r", "a bare newline in the feed") }
            previous = c
        }
        #expect(feed.hasPrefix("BEGIN:VCALENDAR\r\n"))
        #expect(feed.hasSuffix("\r\nEND:VCALENDAR"))
    }
}
