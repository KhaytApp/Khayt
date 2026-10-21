import Foundation
import Testing
@testable import KhaytCore

/// The active-install count's rules (khayt-cloud #123), shared by the Mac and
/// the iPhone.
struct ActiveCountTests {

    /// Noon UTC on a day, so no time zone moves it.
    static func at(_ day: String, hour: Int = 12) -> Date {
        let p = day.split(separator: "-").map { Int($0)! }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour))!
    }

    @Test("the day is UTC, Gregorian and Western digits")
    func day() {
        #expect(ActiveCount.day(Self.at("2026-10-21")) == "2026-10-21")
        // 23:30 in Riyadh is 20:30 UTC the same day; 01:00 Riyadh is the day before in UTC.
        #expect(ActiveCount.day(Self.at("2026-10-21", hour: 22)) == "2026-10-21")
        #expect(ActiveCount.day(Self.at("2026-10-22", hour: 0)) == "2026-10-22")
    }

    @Test("a first ping is first this week, this month and ever")
    func first() {
        let f = ActiveCount.flags(lastCounted: nil, now: Self.at("2026-10-21"))
        #expect(f == .init(firstThisWeek: true, firstThisMonth: true, firstEver: true))
        #expect(ActiveCount.flags(lastCounted: "garbage", now: Self.at("2026-10-21")).firstEver)
    }

    @Test("the week starts on Monday, ISO 8601, across a year's end")
    func weeks() {
        // Wed 21 Oct after Tue 20 Oct: same week, same month.
        #expect(ActiveCount.flags(lastCounted: "2026-10-20", now: Self.at("2026-10-21"))
                == .init(firstThisWeek: false, firstThisMonth: false, firstEver: false))
        // Mon 26 Oct after Sun 25 Oct: a new week.
        #expect(ActiveCount.flags(lastCounted: "2026-10-25", now: Self.at("2026-10-26")).firstThisWeek)
        #expect(!ActiveCount.flags(lastCounted: "2026-10-25", now: Self.at("2026-10-26")).firstThisMonth)
        // Thu 1 Jan 2026 is in ISO week 1 with Mon 29 Dec 2025: same week, new month.
        let f = ActiveCount.flags(lastCounted: "2025-12-29", now: Self.at("2026-01-01"))
        #expect(!f.firstThisWeek && f.firstThisMonth)
        // The same week number a year later is a different week.
        #expect(ActiveCount.flags(lastCounted: "2025-10-21", now: Self.at("2026-10-21")).firstThisWeek)
    }

    @Test("the body is exactly the six fields")
    func body() throws {
        let data = ActiveCount.body(platform: "mac", channel: "alpha", version: "4.0.0-alpha.86",
                                    flags: .init(firstThisWeek: true, firstThisMonth: false, firstEver: false))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["platform", "channel", "version", "firstThisWeek", "firstThisMonth", "firstEver"])
        #expect(json["version"] as? String == "4.0.0-alpha.86" && json["firstThisWeek"] as? Bool == true)
    }

    @Test("only versions the cloud takes are sent")
    func versions() {
        #expect(ActiveCount.accepts(version: "4.0.0-alpha.86") && ActiveCount.accepts(version: "3.11.21"))
        #expect(!ActiveCount.accepts(version: "") && !ActiveCount.accepts(version: "4.0.0-Alpha.1"))
        #expect(!ActiveCount.accepts(version: "4.0") && !ActiveCount.accepts(version: "4.0.0-alpha"))
    }

    @Test("a 200 counts the day, a 422 only finishes it, anything else retries")
    func answers() {
        let now = Self.at("2026-10-21")
        let was = ActiveCount.State(lastCounted: "2026-10-19", doneDay: "2026-10-19")
        #expect(was.due(now: now))
        let counted = was.after(ActiveCount.outcome(status: 200), now: now)
        #expect(counted == .init(lastCounted: "2026-10-21", doneDay: "2026-10-21") && !counted.due(now: now))
        let refused = was.after(ActiveCount.outcome(status: 422), now: now)
        #expect(refused == .init(lastCounted: "2026-10-19", doneDay: "2026-10-21"))
        for status in [0, 404, 500, 503, 429] {
            #expect(was.after(ActiveCount.outcome(status: status), now: now) == was)
        }
    }
}
