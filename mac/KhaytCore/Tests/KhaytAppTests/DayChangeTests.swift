import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Late is a fact about today, and a Mac left open overnight never reloads.
/// Lateness was worked out at load only, so a job due yesterday stayed "not
/// late" — off the widget's Today and out of the badge — until the next edit.
@MainActor
struct DayChangeTests {

    @Test("a new day re-asks which jobs are late, from the rows in hand")
    func lateMovesWithTheDay() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let before = shop.overdueCount

        // A year on, jobs still open that were due within it are late.
        await shop.dayChanged(now: Date().addingTimeInterval(365 * 86_400))
        #expect(shop.overdueCount > before, "the late count did not move with the day")

        // And back to today: the same answer the load gave.
        await shop.dayChanged(now: Date())
        #expect(shop.overdueCount == before)
    }
}
