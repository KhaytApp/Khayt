import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// When the queue will finish, and what will be late because of it.
///
/// The arithmetic is `lib/schedule.js`'s. What is tested here is that the Mac
/// asks it, that the answer means what the screen will say it means, and — the
/// part that has caught this repository twice today — that the sample book can
/// REACH the case the screen draws.
@MainActor
struct TimelineTests {

    static func shop() async throws -> Shop {
        let s = Shop()
        await s.load(.sample)
        return s
    }

    @Test("the shop projects its queue")
    func itAsks() async throws {
        let shop = try await Self.shop()
        let timeline = try #require(shop.timeline, "nothing was projected at all")
        #expect(!timeline.machines.isEmpty)
        #expect(timeline.dailyHours > 0, "a day with no hours in it projects nothing")
    }

    /// Only what is actually on the floor. A quote nobody has accepted is not
    /// in the queue, and counting it would push every real job's date out and
    /// invent lateness that does not exist.
    @Test("a quote is not in the queue")
    func quotesAreNotQueued() async throws {
        let shop = try await Self.shop()
        let timeline = try #require(shop.timeline)
        let projected = Set(timeline.machines.flatMap(\.jobs).map(\.id))
        let quoted = shop.orders.filter { $0.status == "quote" }.map(\.id)
        #expect(!quoted.isEmpty, "no quotes in the sample, so this proves nothing")
        for id in quoted {
            #expect(!projected.contains(id), "\(id) is a quote and was counted as work")
        }
        // And the ones that ARE on the floor were.
        let onFloor = shop.orders.filter { ["pending", "printing", "post", "qc", "on_hold"].contains($0.status) }
        #expect(!onFloor.isEmpty)
        for o in onFloor { #expect(projected.contains(o.id), "\(o.id) is on the floor and was not projected") }
    }

    /// THE CASE THE SCREEN DRAWS. Without a job in it, the line ships unseen.
    @Test("the sample book has a job that will miss its due date")
    func somebodyCanSeeIt() async throws {
        let shop = try await Self.shop()
        // The exclusion below only bites once the attention panel has loaded,
        // so a test that does not check this can pass while the screen draws
        // nothing — which is exactly what happened: `willBeLate` was 8 with no
        // facts and 2 with them, and only the 2 reaches a screen.
        #expect(shop.facts != nil, "no facts, so nothing was excluded and this proves nothing")
        #expect(!shop.willBeLate.isEmpty,
                "no sample job is projected late once the already-late are removed, so this section has never been drawn")
    }

    /// And the distinction the whole feature rests on: a job that is ALREADY
    /// late is in the attention panel, and saying it again in different words
    /// is how a screen teaches somebody to skim it.
    @Test("a job that is already late is not also reported as going to be")
    func noDoubleCounting() async throws {
        let shop = try await Self.shop()
        let already = Set((shop.facts?.attn.items ?? [])
            .filter { $0.kind == "order" }.map(\.id))
        for job in shop.willBeLate {
            #expect(!already.contains(job.id),
                    "\(job.id) is in the attention panel AND in the projection")
        }
    }

    /// A projection is only useful with the date attached.
    @Test("a job at risk carries the day it is now expected")
    func itSaysWhen() async throws {
        let shop = try await Self.shop()
        let job = try #require(shop.willBeLate.first)
        let ready = try #require(shop.readyDate(of: job.id), "no projected date")
        #expect(ready.count == 10, "\(ready) is not a yyyy-MM-dd date")
        if let due = job.dueDate, !due.isEmpty {
            #expect(ready > due, "\(job.id) is 'at risk' but lands on or before \(due)")
        }
    }
}
