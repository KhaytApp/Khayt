import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Writing down what a customer said.
///
/// A rating could reach this book one way only — a customer submitting it
/// through the portal on their phone — so a Mac-only shop drew a ratings line
/// on Reports that could never fill.
@MainActor
struct RecordRatingTests {

    @Test("the bounds are the rule's own, so a saved rating is a drawn rating")
    func boundsComeFromTheReader() {
        // A rating stored outside one to five would sit in the book looking
        // recorded and count for nothing: `ratingOf` refuses it.
        #expect(RatingTrend.minRating == 1)
        #expect(RatingTrend.maxRating == 5)
        for n in [1, 2, 3, 4, 5] {
            let order: JSONValue = .object(["survey": .object(["rating": .number(Double(n))])])
            #expect(RatingTrend.ratingOf(order) == Double(n), Comment(rawValue: "\(n)"))
        }
        for n in [0, 6, -1] {
            let order: JSONValue = .object(["survey": .object(["rating": .number(Double(n))])])
            #expect(RatingTrend.ratingOf(order) == nil,
                    Comment(rawValue: "\(n) was accepted as a rating"))
        }
    }

    @Test("a rating outside one to five is refused with its own sentence")
    func outOfRangeRefused() async throws {
        let shop = Shop()
        await shop.load(.sample)
        guard let job = shop.orders.first else { return }
        for bad in [0, 6, -1, 99] {
            await shop.recordRating(job.id, rating: bad, comment: "")
            #expect(shop.moveProblem == shop.words.callIt("mac.rating_out_of_range"),
                    Comment(rawValue: "\(bad)"))
        }
    }

    @Test("only finished work can be rated")
    func finishedOnly() {
        // A rating on a job still on the bench would be counted by every reader
        // as the finished job's.
        #expect(RatingTrend.finishedStatuses == ["completed", "delivered"])
        #expect(RatingTrend.finishedStatuses == CycleTime.done,
                "two readers disagree about what finished means")
    }

    @Test("the sample shop is told it cannot")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        guard let job = shop.orders.first(where: {
            RatingTrend.finishedStatuses.contains($0.status)
        }) else { return }
        await shop.recordRating(job.id, rating: 5, comment: "Lovely")
        #expect(shop.moveProblem == shop.words.callIt("mac.move_sample"))
    }

    @Test("what a job already carries opens the sheet")
    func readsBackWhatIsThere() async throws {
        let shop = Shop()
        await shop.load(.sample)
        guard let job = shop.orders.first else { return }
        let held = shop.ratingOn(job.id)
        // Whatever the sample holds, the two halves agree with the reader.
        let row = shop.orderRows.first { Shop.recordId($0) == job.id }
        let byRule = row.flatMap { RatingTrend.ratingOf($0) }
        #expect(Double(held.rating) == (byRule ?? 0),
                Comment(rawValue: "sheet \(held.rating), rule \(byRule.debugDescription)"))
    }

    @Test("the shop's own entry is told apart from the customer's")
    func recordedNotSubmitted() throws {
        // The portal writes `submittedAt`; this writes `recordedAt`. A book
        // that cannot tell them apart has lost the difference between what a
        // customer said and what the shop wrote down for them.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        guard let at = source.range(of: "func recordRating(") else {
            Issue.record("recordRating has moved"); return
        }
        let body = source[at.lowerBound...].prefix(1800)
        #expect(body.contains("\"recordedAt\""))
        #expect(!body.contains("\"submittedAt\""))
    }

    @Test("the sheet and the menu item are on the shells that ship")
    func wiredIn() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        func read(_ name: String) throws -> String {
            try String(contentsOf: sources.appending(path: name), encoding: .utf8)
        }
        #expect(try read("ShopWindow.swift").contains("RatingSheet(shop: shop"),
                "nothing raises the rating sheet")
        #expect(try read("Menus.swift").contains("shop.ratingFor = one"),
                "no menu can record a rating")
    }
}
