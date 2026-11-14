import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The inspector's button now reads `lib/order-next-step.js` (S1 PR A). This
/// is the differential the plan asked for: on every job of the sample book,
/// the button offers exactly what the Swift rule it replaces offered — the
/// walk along `Stage.progression`, and Delivered for a finished job.
@MainActor
struct NextStepSharedRuleTests {

    /// The rule as it was before this PR, kept here as the reference.
    static func before(_ job: Order, shop: Shop) -> NextStep? {
        guard shop.canMoveJobs else { return nil }
        if job.status == "completed" && job.deliveredAt == nil { return .deliver }
        guard let here = Stage.of(job), let there = here.stepped(by: 1) else { return nil }
        return here == .quote ? .accept(there) : .move(there)
    }

    @Test("on every sample job the button is what the old Swift rule gave")
    func differential() async throws {
        let shop = Shop()
        await shop.load(.sample)
        defer { shop.pretendsControl = false }
        shop.pretendsControl = true
        #expect(shop.canMoveJobs)
        #expect(shop.nextSteps.count == shop.orders.count, "one answer per job, read at load")
        var seen: Set<String> = []
        for job in shop.orders {
            let got = shop.nextStep(for: job.id)
            #expect(got == Self.before(job, shop: shop),
                    Comment(rawValue: "\(job.id) (\(job.status)): \(String(describing: got))"))
            if let stage = Stage.of(job) { seen.insert(stage.rawValue) }
        }
        // The sample has to reach the stages for this to prove anything.
        for stage in ["quote", "pending", "printing", "completed"] {
            #expect(seen.contains(stage), "the sample has no \(stage) job")
        }
    }

    @Test("what the rule adds is on hand for the job page, and not yet a button")
    func heldForThePage() async throws {
        let shop = Shop()
        await shop.load(.sample)
        defer { shop.pretendsControl = false }
        shop.pretendsControl = true
        // A quote: the rule leads with Send quote; the button still says Accept.
        if let quote = shop.orders.first(where: { Stage.of($0) == .quote }) {
            #expect(shop.nextSteps[quote.id]?.primary?.code == "send_quote")
            #expect(shop.nextStep(for: quote.id) == .accept(.pending))
        }
        // On hold: the rule says Resume; no button here until the page.
        if let held = shop.orders.first(where: { Stage.of($0) == .on_hold }) {
            #expect(shop.nextSteps[held.id]?.primary?.code == "resume")
            #expect(shop.nextStep(for: held.id) == nil)
        }
        // An answer for a stage the job is no longer in is not used.
        let printing = try #require(shop.orders.first { Stage.of($0) == .printing })
        let other = try #require(shop.orders.first { Stage.of($0) == .pending })
        shop.nextSteps[printing.id] = shop.nextSteps[other.id]
        #expect(shop.nextStep(for: printing.id) == nil)
    }
}
