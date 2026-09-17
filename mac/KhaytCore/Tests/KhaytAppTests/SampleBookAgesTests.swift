import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The sample book's dates are fixed, and the calendar is not.
///
/// ── WHAT HAPPENED ─────────────────────────────────────────────────────────
///
/// `TimelineTests` asserts that some sample job is *projected* late but is not
/// late YET, because that is the case the "at risk" section draws and without
/// one the section ships unseen. The sample's newest due date was 2026-09-17.
/// On 2026-09-18 every job on the floor was already late, so the projection had
/// nothing left to report and two tests failed — on a green branch, overnight,
/// with no commit in between.
///
/// A test that decays is worse than one that fails: it fails on a day nobody
/// chose, in somebody else's pull request, about something they did not touch.
///
/// ── SO THIS FAILS EARLY, ON PURPOSE ───────────────────────────────────────
///
/// The margin below is the warning. When it goes red there is still a month of
/// room, and the chore is to move the sample's queue forward — not to work out
/// at midnight why a stranger's branch broke.
///
/// The right fix is for the sample's dates to move with the clock, so it cannot
/// age at all. That is a larger change than this one: thirty-one test files
/// mention a literal date, and shifting the whole book would have to be
/// measured against all of them.
@MainActor
struct SampleBookAgesTests {

    /// How much warning the chore gets.
    ///
    /// Not much is available, and that is the honest number rather than a
    /// comfortable one — see below.
    static let margin = 7

    static func book() throws -> [String: JSONValue] {
        let url = try #require(AppResources.bundle.url(forResource: "sample-shop",
                                                       withExtension: "json"))
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    /// Every due date on a job that is still on the floor.
    static func queueDueDates() throws -> [String] {
        guard case .array(let jobs)? = try book()["printLog"] else { return [] }
        let onTheFloor: Set<String> = ["pending", "printing", "post", "qc", "on_hold"]
        return jobs.compactMap { row in
            guard case .object(let job) = row,
                  case .string(let status)? = job["status"], onTheFloor.contains(status),
                  case .string(let due)? = job["dueDate"], !due.isEmpty else { return nil }
            return due
        }
    }

    /// ── WHY THE WINDOW IS SHORT, AND CANNOT BE MADE LONG ──────────────────
    ///
    /// The case is "projected late, but not late YET", so the job's due date
    /// has to sit BETWEEN today and the day the queue reaches it. That gap is
    /// the queue's own length — about three weeks on this shop's busiest
    /// machine — and it slides forward a day for every day that passes, while
    /// a date written into a file does not.
    ///
    /// So no arrangement of fixed dates keeps this case alive for longer than
    /// the queue. The sample is set to the far end of it (`ORD-01041`, last on
    /// the busiest machine), which is the most that can be bought.
    ///
    /// The real fix is for the sample's dates to move with the clock, so it
    /// cannot age at all. That is a larger change than this one: thirty-one
    /// test files mention a literal date, and shifting the whole book would
    /// have to be measured against all of them.
    /// ── AND THE CLOCK IS NOT ONE CLOCK ────────────────────────────────────
    ///
    /// The first attempt at this placed the job so that it was at risk on the
    /// developer's Mac, and CI failed anyway: the runner was on 2026-09-17
    /// while the Mac was on 2026-09-18, an ordinary timezone apart. The window
    /// was missed by ONE DAY, in a test written to stop exactly that.
    ///
    /// So the check below asks for slack at BOTH ends: room before the case
    /// expires, and enough distance between the job's due date and the day the
    /// queue reaches it that a clock a day either way cannot flip it.
    static let slack = 2

    @MainActor
    static func atRisk() async -> (job: Order, ready: String)? {
        let shop = Shop()
        await shop.load(.sample)
        guard let job = shop.willBeLate.first, let ready = shop.readyDate(of: job.id)
        else { return nil }
        return (job, ready)
    }

    @Test("the at-risk case still has room before it expires")
    func theCaseHasRoomLeft() async throws {
        let (job, ready) = try #require(await Self.atRisk(), """
            No sample job is projected late while still being ahead of its due             date, so the "at risk" section has nothing to draw and TimelineTests             is already failing. Move the due date of the LAST job on the busiest             machine to just inside that machine's projected ready date.
            """)
        let due = try #require(job.dueDate, "the at-risk job has no due date")
        // Far enough past its date that a runner a day behind still sees it.
        let earliest = DateFormatter.shopDay.string(
            from: Calendar.current.date(byAdding: .day, value: Self.slack,
                                        to: Order.day(due) ?? Date()) ?? Date())
        #expect(ready >= earliest, Comment(rawValue: """
            \(job.id) is projected ready \(ready) against a due date of \(due) — \
            under \(Self.slack) days of slack. A machine whose clock is a day \
            behind this one will not see it as at risk at all, which is how \
            this test passed locally and failed on CI the first time it was \
            written. Move the due date a few days earlier.
            """))
        let deadline = DateFormatter.shopDay.string(
            from: Calendar.current.date(byAdding: .day, value: Self.margin, to: Date()) ?? Date())
        #expect(due >= deadline, Comment(rawValue: """
            The sample's "at risk" case expires on \(due), which is under             \(Self.margin) days away. Once today passes it, the job moves into             the attention panel as ALREADY late and the projection has nothing             left to report — TimelineTests then fails on a day nobody chose, in             somebody else's pull request.

            The chore: run the queue's due dates forward again. Keep six behind             today so the attention panel still has its six, and put the last job             on the busiest machine just inside that machine's projected ready             date.
            """))
    }

    @Test("the queue still has six overdue jobs and a horizon past them")
    func theQueueStraddlesToday() throws {
        // Both halves matter. Six overdue is what the attention panel is sized
        // for; work still ahead of its date is what the projection reads.
        let dates = try Self.queueDueDates()
        #expect(!dates.isEmpty, "no job on the floor has a due date, so nothing here is checked")
        let today = DateFormatter.shopDay.string(from: Date())
        #expect(dates.count { $0 < today } >= 6,
                Comment(rawValue: "only \(dates.count { $0 < today }) queued jobs are overdue"))
        #expect(dates.contains { $0 > today }, "no queued job is still ahead of its date")
    }
}
