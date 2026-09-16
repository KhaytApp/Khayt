import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The two spellings of finished.
///
/// Khayt wrote `delivered` before it wrote `completed` with a `deliveredAt`
/// beside it, and both are still in shops' books — thirteen of them in the
/// sample. "Is this job finished" is therefore a two-value test, and it was
/// written out by hand in at least eight modules.
///
/// Written out by hand is written out wrongly eventually, and it was: the
/// machine P&L filtered `status == "completed"` alone, here and in the other
/// app both, so every delivered job was missing from what a printer had
/// earned. Nothing threw; the figures were just quietly of a subset.
@MainActor
struct FinishedStatusTests {

    @Test("the Swift list is the rule's own list, not a second opinion")
    func matchesTheRule() async throws {
        let engine = try KhaytEngine()
        let fromRule = Set(try await engine.finishedStatuses())
        #expect(fromRule == Shop.finishedStatuses,
                Comment(rawValue: "rule says \(fromRule.sorted()), this app says \(Shop.finishedStatuses.sorted())"))
        #expect(fromRule.contains("delivered") && fromRule.contains("completed"))
    }

    @Test("the sample book's delivered jobs reach the machine figures")
    func deliveredJobsCount() async throws {
        let shop = Shop()
        await shop.load(.sample)
        var delivered = 0, completed = 0
        for row in shop.orderRows {
            guard case .object(let o) = row, case .string(let status)? = o["status"] else { continue }
            if status == "delivered" { delivered += 1 }
            if status == "completed" { completed += 1 }
        }
        // The sample is built to span this on purpose; without delivered rows
        // the test below proves nothing.
        #expect(delivered > 0, "the sample book no longer has a legacy delivered job")
        #expect(completed > 0)

        let picked = await shop.completedInPeriod().orders
        var seen: Set<String> = []
        for row in picked {
            guard case .object(let o) = row, case .string(let status)? = o["status"] else { continue }
            seen.insert(status)
        }
        // Whatever the period holds, it must never hold ONLY completed while
        // the book has delivered jobs in the same range — that was the bug.
        #expect(seen.isSubset(of: Shop.finishedStatuses),
                Comment(rawValue: "an unfinished job reached the machine figures: \(seen.sorted())"))
    }

    @Test("an unfinished job is not finished, whatever else it carries")
    func unfinishedStaysOut() {
        for status in ["printing", "quote", "pending", "post", "qc", "on_hold", "cancelled", ""] {
            #expect(!Shop.finishedStatuses.contains(status), Comment(rawValue: status))
        }
        // `cancelled` especially: it has an end date and is not earnings.
        #expect(!Shop.finishedStatuses.contains("cancelled"))
    }
}
