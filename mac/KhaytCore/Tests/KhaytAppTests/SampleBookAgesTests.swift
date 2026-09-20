import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The sample book cannot age out of the case it covers.
///
/// ── WHAT USED TO HAPPEN ───────────────────────────────────────────────────
///
/// `TimelineTests` asserts that some sample job is *projected* late but is not
/// late YET, because that is the case the "at risk" section draws and without
/// one the section ships unseen. The sample's dates were fixed and the calendar
/// was not, so that case expired: on 2026-09-18 every job on the floor was
/// already late, the projection had nothing left to report, and two tests
/// failed — on a green branch, overnight, with no commit in between. It
/// happened again on 2026-09-20.
///
/// A test that decays is worse than one that fails: it fails on a day nobody
/// chose, in somebody else's pull request, about something they did not touch.
///
/// ── WHY THE CHORE WAS NOT THE ANSWER ──────────────────────────────────────
///
/// What this file used to do was warn early so somebody could move the due
/// dates forward by hand. That chore buys about ten days, and ten is not a
/// slip in the estimate — it is the whole width of the window. The "at risk"
/// case has to sit later than today plus the warning and earlier than the day
/// the queue reaches it, and the busiest machine's queue is nineteen days long.
/// No arrangement of FIXED dates is worth more than that.
///
/// So the dates are not fixed any more: `SampleBook` moves the whole book by
/// the number of days between the day it was written for and today. What this
/// file does now is prove that the move works — not next week, but on days
/// nobody has lived through yet.
/// The anchor day, and four days nobody has lived through.
///
/// 37 is deliberately not a multiple of seven: the projection counts the shop's
/// WORKING days, so a book moved by a whole number of weeks would land on the
/// same weekdays and hide a fault that only shows when it does not. The other
/// three walk out far enough that a slow drift would show.
///
/// At file scope because `@Test(arguments:)` reads it while building the test
/// list, which is not on the main actor — inside the suite it would be isolated
/// to one and unreadable from there.
private let sampleDaysOut = [0, 37, 180, 400, 1_000]

@MainActor
struct SampleBookAgesTests {

    /// Room for a clock a day either way.
    ///
    /// The first attempt at keeping this alive placed the job so that it was at
    /// risk on the developer's Mac, and CI failed anyway: the runner was on
    /// 2026-09-17 while the Mac was on 2026-09-18, an ordinary timezone apart.
    /// The window was missed by ONE DAY, in a test written to stop exactly
    /// that. So the case has to survive being read a day early or a day late.
    static let slack = 2

    static func rawBook() throws -> [String: JSONValue] {
        let url = try #require(AppResources.bundle.url(forResource: "sample-shop",
                                                       withExtension: "json"))
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    // MARK: - The move itself

    @Test("a day moves, a version does not, and a book on its own anchor is untouched")
    func onlyDaysMove() throws {
        #expect(SampleBook.shiftingDay("2026-09-20", by: 3) == "2026-09-23")
        #expect(SampleBook.shiftingDay("2026-09-20T09:00:00.000Z", by: 3)
                == "2026-09-23T09:00:00.000Z")
        // Not days, and must come back exactly as they went in.
        #expect(SampleBook.shiftingDay("4.0.0-alpha.28", by: 3) == "4.0.0-alpha.28")
        #expect(SampleBook.shiftingDay("ORD-01041", by: 3) == "ORD-01041")
        #expect(SampleBook.shiftingDay("2026-09-20 and then some", by: 3)
                == "2026-09-20 and then some")
        #expect(SampleBook.shiftingDay("2026-02-31", by: 3) == "2026-02-31",
                "a date the calendar does not have was quietly repaired")
        #expect(SampleBook.shiftingDay("trk-sample01", by: 3) == "trk-sample01")

        // On the anchor itself the book is the file, byte for byte. This is
        // what makes the literal dates in the other test files mean what they
        // say on the day somebody reads them.
        let anchor = try #require(SampleBook.anchor)
        #expect(SampleBook.rebased(try Self.rawBook(), to: anchor) == (try Self.rawBook()))
    }

    @Test("every date in the book moves, and by the same number of days")
    func theWholeBookMoves() throws {
        let anchor = try #require(SampleBook.anchor)
        let later = try #require(Calendar.current.date(byAdding: .day, value: 400, to: anchor))
        let moved = SampleBook.rebased(try Self.rawBook(), to: later)
        let before = Self.everyDay(in: .object(try Self.rawBook())).sorted()
        let after = Self.everyDay(in: .object(moved)).sorted()
        #expect(before.count > 100, "only \(before.count) dates found — the walk has rotted")
        #expect(before.count == after.count, "the move lost or invented a date")
        // Shifting a job's due date but not the day it was raised would leave a
        // sample book that contradicts itself, so the check is that EVERY date
        // moved by the same amount rather than that the queue looks right.
        let gaps = Set(zip(before, after).map { a, b in
            Calendar.current.dateComponents(
                [.day], from: DateFormatter.shopDay.date(from: String(a.prefix(10))) ?? Date(),
                to: DateFormatter.shopDay.date(from: String(b.prefix(10))) ?? Date()).day ?? -1
        })
        #expect(gaps == [400], Comment(rawValue: "the book moved by \(gaps.sorted())"))
    }

    static func everyDay(in value: JSONValue) -> [String] {
        switch value {
        case .string(let s):
            guard s.count >= 10, DateFormatter.shopDay.date(from: String(s.prefix(10))) != nil,
                  s.count == 10 || s.dropFirst(10).hasPrefix("T") else { return [] }
            return [s]
        case .array(let a):  return a.flatMap { everyDay(in: $0) }
        case .object(let o): return o.values.flatMap { everyDay(in: $0) }
        default: return []
        }
    }

    // MARK: - And the shop it describes is the same shop, on any day

    /// The sample shop as it would be read on a given day — the real load path,
    /// so what is proved here is what the app does rather than a reconstruction
    /// of it. `load` takes the day and hands it to BOTH the rebasing and the
    /// projection, which is the point: asking the two about different days
    /// would measure a moved book against today's calendar and prove nothing.
    static func shop(on day: Date) async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample, asOf: day)
        #expect(shop.problem == nil, Comment(rawValue: "the sample would not load: "
                                             + (shop.problem ?? "")))
        return shop
    }

    @Test("on any day, the queue still straddles today with six behind it",
          arguments: sampleDaysOut)
    func theQueueStraddles(_ out: Int) async throws {
        let anchor = try #require(SampleBook.anchor)
        let day = try #require(Calendar.current.date(byAdding: .day, value: out, to: anchor))
        let today = DateFormatter.shopDay.string(from: day)
        let shop = try await Self.shop(on: day)
        let onTheFloor: Set<String> = ["pending", "printing", "post", "qc", "on_hold"]
        let due = shop.orders.filter { onTheFloor.contains($0.status) }
            .compactMap(\.dueDate).filter { !$0.isEmpty }
        #expect(due.count { $0 < today } == 6, Comment(rawValue:
            "\(out) days out, \(due.count { $0 < today }) queued jobs are overdue, not 6 — "
            + "the attention panel is sized for six"))
        #expect(due.contains { $0 > today }, Comment(rawValue:
            "\(out) days out, no queued job is still ahead of its date"))
    }

    @Test("on any day, one job is projected late while still ahead of its date",
          arguments: sampleDaysOut)
    func theCaseSurvives(_ out: Int) async throws {
        let anchor = try #require(SampleBook.anchor)
        let day = try #require(Calendar.current.date(byAdding: .day, value: out, to: anchor))
        let today = DateFormatter.shopDay.string(from: day)
        let shop = try await Self.shop(on: day)
        let timeline = try #require(shop.timeline, "nothing on the floor to project")

        // "At risk" is the job the projection says will miss a date it has not
        // missed yet. A job already overdue is not this case — it is in the
        // attention panel, and the section would have nothing of its own.
        let risky = timeline.machines.flatMap(\.jobs)
            .filter { $0.late && $0.dueDate > today }
        #expect(!risky.isEmpty, Comment(rawValue:
            "\(out) days out, no sample job is projected late while still ahead of its "
            + "due date, so the 'at risk' section has nothing to draw"))

        // And with room on both sides, so a machine whose clock is a day out
        // still sees it. This is the check that failed on CI the first time,
        // by exactly one day.
        for job in risky {
            let earliest = DateFormatter.shopDay.string(from:
                Calendar.current.date(byAdding: .day, value: Self.slack,
                                      to: Order.day(job.dueDate) ?? day) ?? day)
            #expect(job.etaDate >= earliest, Comment(rawValue:
                "\(out) days out, \(job.id) is projected ready \(job.etaDate) against a due "
                + "date of \(job.dueDate) — under \(Self.slack) days of slack, so a machine "
                + "a day behind this one will not see it as at risk at all"))
            let latest = DateFormatter.shopDay.string(from:
                Calendar.current.date(byAdding: .day, value: Self.slack, to: day) ?? day)
            #expect(job.dueDate >= latest, Comment(rawValue:
                "\(out) days out, \(job.id) is due \(job.dueDate), under \(Self.slack) days "
                + "away — a machine a day ahead of this one reads it as already late"))
        }
    }
}
