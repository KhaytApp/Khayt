import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Whether a spool has gone damp, and whether the shelf can ever say so.
///
/// `lib/filament-dryness.js` has known the intervals for a long time. It could
/// not be asked about a spool, because the only `driedAt` in the store lived on
/// Bed Ready's `filamentDryLog` — a separate list of labels with nothing
/// joining it to the shelf. A shop was tracking the same roll twice, and the
/// half that knew the material was not the half that knew when it was dried.
@MainActor
struct DrynessTests {

    static func shop() async throws -> Shop {
        let s = Shop()
        await s.load(.sample)
        return s
    }

    /// The wiring. Delete the call in `Shop.load` and this fails.
    @Test("the shelf asks about every spool")
    func theShopAsks() async throws {
        let shop = try await Self.shop()
        for spool in shop.spools {
            #expect(shop.spoolDryness[spool.id] != nil,
                    "\(spool.id) was never asked about")
        }
    }

    /// The card only draws for `due` and `overdue`, so the sample must contain
    /// both — and `good` and `unknown` too, because "draws nothing" is a case a
    /// screen gets wrong as easily as any other.
    @Test("the sample book spans every state a spool can be in")
    func allFourStates() async throws {
        let shop = try await Self.shop()
        let engine = try #require(shop.engine)
        // The book's own clock — its dates are literal and never shifted, so a
        // live clock would drift this book into "overdue" for everything.
        let at = RunwayTests.bookClock(shop)
        let seen = Set(try await engine.dryness(spools: shop.inventoryRows, now: at)
                        .values.map(\.state))
        for state in ["good", "due", "overdue", "unknown"] {
            #expect(seen.contains(state), "no sample spool is '\(state)'")
        }
    }

    /// The one that would be worst to get wrong: silence is not an accusation.
    @Test("a spool nobody has recorded drying is unknown, not overdue")
    func silenceIsNotAnAccusation() async throws {
        let shop = try await Self.shop()
        let engine = try #require(shop.engine)
        let none: [JSONValue] = [.object([
            "id": .string("never"), "material": .string("PA-CF"), "storage": .string("shelf"),
        ])]
        let got = try await engine.dryness(spools: none, now: Date())
        #expect(got["never"]?.state == "unknown",
                "an unrecorded spool was accused of being wet")
        #expect(got["never"]?.daysSince == nil)
    }

    /// Storage is half the answer, and the half a shop can act on.
    @Test("a sealed box buys a spool weeks that an open shelf does not")
    func storageMatters() async throws {
        let shop = try await Self.shop()
        let engine = try #require(shop.engine)
        let dried = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5 * 86400))
        let pair: [JSONValue] = [
            .object(["id": .string("open"), "material": .string("PETG"),
                     "storage": .string("shelf"), "driedAt": .string(dried)]),
            .object(["id": .string("box"), "material": .string("PETG"),
                     "storage": .string("drybox"), "driedAt": .string(dried)]),
        ]
        let got = try await engine.dryness(spools: pair, now: Date())
        let open = try #require(got["open"]), box = try #require(got["box"])
        #expect(box.intervalDays > open.intervalDays,
                "the sealed box bought no time at all")
        #expect(box.pct < open.pct)
    }
}
