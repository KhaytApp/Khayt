import Foundation
import Testing
@testable import KhaytCore

/// Which records fall in a period, against the JavaScript it came from.
///
/// Two things here are much harder to port than they look, and both are asked
/// about at length rather than spot-checked.
///
/// **What counts as a date.** The rule calls `new Date(s)` and asks whether it
/// came back valid. `2026-02-30` did not. `2026-06-15T10:00` did. `2026-06-15x`
/// did not. Swift has no function that agrees with that, so the port writes the
/// grammar out — and the only way to know it wrote it correctly is to ask the
/// original about every string that might be a date.
///
/// **The local calendar.** `new Date(y, m - 1, 1)` is local time, and so is
/// `getFullYear()`. The quarter arithmetic is four of those in a row. A port
/// that reached for UTC anywhere would be a day out for most of the world, at
/// the two boundaries where anybody would notice.
@MainActor
struct DateRangeParityTests {

    private func js() throws -> JSModule { try JSModule(["date-range"]) }

    private func theirs(_ js: JSModule, _ date: JSONValue, _ range: JSONValue,
                        now: Date, from: String = "", to: String = "") throws -> Bool {
        let answer = try js.value("""
            globalThis.KhaytDateRange.inRange(ARG0, ARG1, {
              now: new Date(ARG2), from: ARG3, to: ARG4,
            })
            """, [date, range, .number(now.timeIntervalSince1970 * 1000),
                  .string(from), .string(to)])
        if case .bool(let b) = answer { return b }
        return false
    }

    /// Clocks chosen to sit on the edges the arithmetic has: the first and last
    /// day of a month, of a quarter, and of a year — and a leap day.
    private var clocks: [Date] {
        ["2026-09-17T13:00:00Z", "2026-01-01T00:30:00Z", "2026-12-31T23:30:00Z",
         "2026-03-01T00:00:00Z", "2026-04-01T00:00:00Z", "2026-07-01T00:00:00Z",
         "2026-10-01T00:00:00Z", "2024-02-29T12:00:00Z", "2026-02-28T22:00:00Z",
         "2026-11-30T23:59:00Z"].compactMap {
            ISO8601DateFormatter().date(from: $0)
        }
    }

    /// Dates, near-dates, and things that are not dates at all.
    private var dates: [JSONValue] {
        var out: [JSONValue] = []
        for text in [
            // Real days across the boundaries.
            "2026-09-17", "2026-09-01", "2026-09-30", "2026-08-31", "2026-10-01",
            "2026-06-30", "2026-07-01", "2025-12-31", "2026-01-01", "2026-12-31",
            "2024-02-29", "2025-02-28", "2026-03-31", "2026-04-01",
            // Days that are not days.
            "2026-02-30", "2026-02-29", "2026-13-01", "2026-00-10", "2026-01-00",
            "2026-04-31", "2026-06-31", "2026-11-31", "9999-12-31", "0000-01-01",
            // The shapes the module's own note is about.
            "2026", "2026-09", "26-09-17", "2026-9-17", "2026/09/17",
            // A stamp with a tail, which is most of what the book holds.
            "2026-09-17T14:32:00.000Z", "2026-09-17T14:32:00Z",
            "2026-09-17T14:32:00", "2026-09-17T14:32", "2026-09-17 14:32",
            "2026-09-17T24:00:00Z", "2026-09-17T24:00:01Z", "2026-09-17T23:59:60Z",
            "2026-09-17T14:32:00+03:00", "2026-09-17T14:32:00-0800",
            "2026-09-17T14:32:00.5Z", "2026-09-17T14:32:00.Z",
            // A tail that is not a time at all.
            "2026-09-17x", "2026-09-17T", "2026-09-17Tnope", "2026-09-17-",
            "2026-09-17T14", "2026-09-17T1:2", "2026-09-17T14:32:00+3",
            "", " ", "  2026-09-17", "2026-09-17 ",
            // ── THE BOUNDARIES OF THE ENGINE'S OWN GRAMMAR ────────────────
            //
            // Measured, not transcribed: the port asks JavaScriptCore what it
            // accepts, and these are the answers that are not what the
            // specification says. They are in the corpus so the grammar is
            // pinned by a test rather than by a probe somebody ran once.
            "2026-09-17T23:59:60Z",        // a leap second — ACCEPTED
            "2026-09-17T23:59:61Z", "2026-09-17T23:60:00Z", "2026-09-17T25:00:00Z",
            "2026-09-17T24:00:00Z",        // midnight at the far end — accepted
            "2026-09-17T24:00:01Z", "2026-09-17T24:01:00Z",
            "2026-09-17t14:32:00Z",        // lowercase separator — accepted
            "2026-09-17T14:32:00z",        // lowercase zone — refused
            "2026-09-17T12:00:00+0330", "2026-09-17T12:00:00+3:30",
            "2026-09-17T12:00:00+24:00", "2026-09-17T12:00:00-14:00",
            "2026-09-17T12:00:00+01:60", "2026-09-17T12:00:00+01:00:00",
            "2026-09-17T12:00:00.1234567Z", "2026-09-17T12:00:00.",
            "2026-09-17T12:00:00ZZ", "2026-09-17  12:00:00",
            "2026-09-17T23:59:60.500Z", "2026-09-17T23:59:60",
            // Digits that are digits in another script. `Character.isNumber`
            // is true of these, and the engine refuses them.
            "2026-09-17T١٢:00:00Z", "٢٠٢٦-09-17",
        ] { out.append(.string(text)) }
        out += [.null, .bool(true), .bool(false), .number(0), .number(20260917),
                .array([]), .object([:])]
        return out
    }

    @Test("every period over every date, at ten different clocks")
    func everyPeriodMatches() throws {
        let js = try js()
        var compared = 0
        for now in clocks {
            for range in DateRange.ranges.map(JSONValue.string) + [.null, .string(""), .string("nonsense")] {
                for date in dates {
                    // Through the `JSONValue` entry point, which is what the
                    // engine calls: the coercion from "whatever the book
                    // stored" to text is part of the rule, so it is part of
                    // what is compared.
                    let rangeText: String? = { if case .string(let s) = range { return s } else { return nil } }()
                    let mine = DateRange.inRange(date, range: rangeText, now: now)
                    let theirs = try theirs(js, date, range, now: now)
                    compared += 1
                    #expect(mine == theirs,
                            Comment(rawValue: "\(date) in \(range) at \(DateRange.localDay(now)): swift \(mine) vs js \(theirs)"))
                }
            }
        }
        #expect(compared > 3_000, "the sweep shrank: only \(compared) comparisons")
    }

    @Test("a custom span, at both ends and outside them")
    func customSpanMatches() throws {
        let js = try js()
        let now = clocks[0]
        let spans = [("", ""), ("2026-09-01", ""), ("", "2026-09-30"),
                     ("2026-09-01", "2026-09-30"), ("2026-09-17", "2026-09-17"),
                     ("2026-09-30", "2026-09-01"),   // backwards on purpose
                     ("2026", "2027"), ("nonsense", "also nonsense")]
        for (from, to) in spans {
            for date in dates {
                guard case .string(let text) = date else { continue }
                let mine = DateRange.inRange(text, range: "custom", now: now,
                                             custom: .init(from: from, to: to))
                let theirs = try theirs(js, date, .string("custom"), now: now, from: from, to: to)
                #expect(mine == theirs,
                        Comment(rawValue: "\(text) in \(from)…\(to): swift \(mine) vs js \(theirs)"))
            }
        }
    }

    @Test("the period list is the same list")
    func rangesMatch() throws {
        #expect(DateRange.ranges == (try js().strings("globalThis.KhaytDateRange.RANGES")))
    }

    @Test("a day and a month are written the same way, in local time")
    func localStampsMatch() throws {
        let js = try js()
        for now in clocks {
            let ms = now.timeIntervalSince1970 * 1000
            guard case .string(let day) = try js.value(
                "globalThis.KhaytDateRange.localDay(new Date(ARG0))", [.number(ms)]),
                  case .string(let month) = try js.value(
                "globalThis.KhaytDateRange.localMonth(new Date(ARG0))", [.number(ms)])
            else { Issue.record("no stamp for \(now)"); continue }
            #expect(DateRange.localDay(now) == day, Comment(rawValue: "day at \(now)"))
            #expect(DateRange.localMonth(now) == month, Comment(rawValue: "month at \(now)"))
        }
    }

    @Test("the quarter boundaries are the ones the original computes")
    func quarterBoundariesMatch() throws {
        // `last_quarter` is four local-calendar constructions in a row, two of
        // them with a day of zero. Asked at the first instant of each quarter,
        // where an off-by-one is a whole quarter wrong rather than a day.
        let js = try js()
        let formatter = ISO8601DateFormatter()
        for month in 1...12 {
            guard let now = formatter.date(from: String(format: "2026-%02d-01T00:00:01Z", month))
            else { continue }
            for day in stride(from: 0, through: 400, by: 7) {
                guard let d = Calendar.current.date(byAdding: .day, value: -day, to: now)
                else { continue }
                let text = DateRange.localDay(d)
                for range in ["quarter", "last_quarter", "month", "last_month", "year"] {
                    let mine = DateRange.inRange(text, range: range, now: now)
                    let theirs = try theirs(js, .string(text), .string(range), now: now)
                    #expect(mine == theirs,
                            Comment(rawValue: "\(text) in \(range) at \(DateRange.localDay(now))"))
                }
            }
        }
    }
}
