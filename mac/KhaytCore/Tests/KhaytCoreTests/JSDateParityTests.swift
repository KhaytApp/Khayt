import Foundation
import Testing
@testable import KhaytCore

/// `Date.parse` and the local-calendar readers, against the engine itself.
///
/// Several rules bucket records by month, and `lib/forecast.js` carries the
/// scar of getting this wrong in a comment: reading the month in UTC put a
/// UTC+3 shop's early-morning jobs into the previous month and slid the whole
/// forecast window back — *"the tests never caught it: they build both now and
/// the fixtures with Date.UTC, so they were self-consistently wrong."*
///
/// So this compares against `Date.parse` itself rather than against a fixture,
/// and the corpus mixes the two spellings the book actually holds — the one
/// that is UTC and the one that is not.
@MainActor
struct JSDateParityTests {

    /// No module needed: the subject is the engine's own `Date`.
    private func js() throws -> JSModule { try JSModule([]) }

    /// Every stamp shape the book holds, plus the ones that decide the rule.
    static let stamps = [
        // Date-only — UTC, per the specification.
        "2026-09-17", "2026-01-01", "2026-12-31", "2024-02-29", "2026-09-01",
        // A time with NO zone — LOCAL. Same wall clock, different instant.
        "2026-09-01T00:00:00", "2026-09-01T02:59:59", "2026-09-17T13:45:00",
        "2026-09-01T00:00", "2026-09-01 00:00:00", "2026-09-01t00:00:00",
        // Explicitly UTC.
        "2026-09-01T00:00:00Z", "2026-09-17T14:32:00.000Z", "2026-09-17T14:32:00.5Z",
        "2026-09-17T14:32:00.123456Z", "2026-09-17T24:00:00Z", "2026-09-17T23:59:60Z",
        // Offsets.
        "2026-09-17T14:32:00+03:00", "2026-09-17T14:32:00-08:00",
        "2026-09-17T14:32:00+0330", "2026-09-17T00:30:00+03:00",
        // Shorter forms — also UTC.
        "2026", "2026-09",
        // And things that are not stamps.
        "", "   ", "not a date", "2026-13-01", "2026-02-30", "2026-09-17T25:00:00Z",
        "2026-09-17T14:32:00z", "2026-09-17T14:32:00+3:30", "2026-09-17x",
        "17-09-2026", "2026-09-17T", "2026-09-17T14",
    ]

    @Test("every stamp parses to the same instant, or to nothing at all")
    func parseMatches() throws {
        let js = try js()
        for text in Self.stamps {
            let mine = JSDate.parse(text)
            let answer = try js.value("(function (s) { var t = Date.parse(s); "
                                    + "return Number.isNaN(t) ? null : t; })(ARG0)",
                                      [.string(text)])
            var theirs: Double?
            if case .number(let n) = answer { theirs = n }
            let said = mine.map { "\($0)" } ?? "nil"
            let heard = theirs.map { "\($0)" } ?? "nil"
            #expect(mine == theirs,
                    Comment(rawValue: "\(text.debugDescription): swift \(said) vs js \(heard)"))
        }
    }

    /// ── WHERE THIS DELIBERATELY STOPS ─────────────────────────────────────
    ///
    /// `Date.parse` has a second, implementation-defined half: the engine also
    /// takes `2026/09/17` and `2026-9-17`, as LOCAL time. Reproducing that
    /// tail is an unbounded job with no specification to hold it to — and it
    /// is unnecessary, because every stamp in both books is ISO, written by
    /// Khayt itself. Counted: 573 + 61 + 246 + 153, and none of them this.
    ///
    /// Pinned so the boundary is a decision rather than a surprise. If a
    /// non-ISO stamp ever does reach the book, this test is where to start.
    @Test("the legacy date forms are refused here, and the engine still takes them")
    func legacyFormsAreOutOfScope() throws {
        let js = try js()
        for text in ["2026/09/17", "2026-9-17", "2026/9/17"] {
            #expect(JSDate.parse(text) == nil,
                    Comment(rawValue: "\(text) is now in scope — update the note in JSDate"))
            let answer = try js.value("(function (s) { var t = Date.parse(s); "
                                    + "return Number.isNaN(t) ? null : t; })(ARG0)",
                                      [.string(text)])
            guard case .number = answer else {
                Issue.record(Comment(rawValue: "the engine stopped taking \(text) — this test can go"))
                continue
            }
        }
    }

    @Test("a date with no time and the same date with one are DIFFERENT instants")
    func theTrapIsReal() throws {
        // ── AND THIS HAS TO MEAN SOMETHING UNDER UTC TOO ──────────────────
        //
        // The first version recorded an issue when the machine was on UTC,
        // "because there is nothing to see" — which FAILS the test on CI,
        // where the runner is on UTC. Caught by running the suite under six
        // zones rather than by reasoning about it.
        //
        // So the assertion is the RELATIONSHIP, which holds everywhere: the
        // two spellings are exactly the zone's offset apart. On UTC that is
        // zero and they coincide, which is the correct answer there and not a
        // reason to skip.
        let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 1_787_000_000))
        let bare = try #require(JSDate.parse("2026-09-01"))
        let timed = try #require(JSDate.parse("2026-09-01T00:00:00"))
        #expect(timed - bare == Double(-offset) * 1000, Comment(rawValue:
            "the gap is \(timed - bare) ms; this zone is \(-offset * 1000) ms from UTC"))
        if offset != 0 {
            #expect(bare != timed,
                    "the date-only form is UTC and the timed form is local; they cannot match")
        }
    }

    @Test("the local year and month agree with the engine's own readers")
    func localReadersMatch() throws {
        let js = try js()
        var instants: [Double] = []
        for text in Self.stamps { if let ms = JSDate.parse(text) { instants.append(ms) } }
        // Plus the boundaries: the first and last millisecond of a local month,
        // which is where a UTC reading lands in the wrong bucket.
        for extra in [0.0, -1, 1, 1_790_000_000_000, 1_767_225_600_000,
                      1_767_225_599_999, 1_767_225_600_001, -86_400_000, 1e12] {
            instants.append(extra)
        }
        for ms in instants {
            let mine = JSDate.localYearMonth(ms: ms)
            guard case .array(let pair) = try js.value(
                "(function (t) { var d = new Date(t); return [d.getFullYear(), d.getMonth()]; })(ARG0)",
                [.number(ms)]), pair.count == 2,
                  case .number(let y) = pair[0], case .number(let m) = pair[1]
            else { Issue.record("no answer for \(ms)"); continue }
            #expect(mine.year == Int(y) && mine.month == Int(m),
                    Comment(rawValue: "\(ms): swift \(mine) vs js (\(Int(y)), \(Int(m)))"))
        }
    }

    @Test("every hour of a month boundary lands in the same month on both sides")
    func monthBoundariesMatch() throws {
        // The exact failure the module's comment describes: a shop three hours
        // ahead, between midnight and 03:00 on the 1st.
        let js = try js()
        let firstOfSeptember = try #require(JSDate.parse("2026-09-01T00:00:00Z"))
        for hour in -6...6 {
            let ms = firstOfSeptember + Double(hour) * 3_600_000
            let mine = JSDate.localYearMonth(ms: ms)
            guard case .number(let key) = try js.value(
                "(function (t) { var d = new Date(t); return d.getFullYear() * 12 + d.getMonth(); })(ARG0)",
                [.number(ms)]) else { Issue.record("no key for \(ms)"); continue }
            #expect(mine.year * 12 + mine.month == Int(key),
                    Comment(rawValue: "hour \(hour) of the boundary landed in a different month"))
        }
    }
}
