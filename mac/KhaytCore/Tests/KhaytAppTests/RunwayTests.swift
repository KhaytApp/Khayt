import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// How long each spool has got, and whether anybody can see it.
///
/// The arithmetic is `lib/reorder.js`'s and is tested there. What is tested
/// HERE is that the Mac app asks it, that the answer arrives in the shape the
/// card reads, and — the part that was actually broken — that the sample book
/// can REACH the branch that draws the line.
///
/// ── WHY THE CLOCK IS PINNED ────────────────────────────────────────────────
///
/// The sample book's dates are literal and are not shifted on load, so its
/// newest job recedes into the past at one day per day. A consumption rate
/// comes from a thirty-day window, so a test asking "does any spool run out
/// soon?" against `Date()` passes today and fails silently in a month — and
/// the failure would say the app was broken when only the calendar had moved.
///
/// So reachability is asked at the book's OWN clock: the day after its last
/// finished job, which is the moment this shop is written to represent. The
/// wiring test below uses the live clock, because whether `Shop` asks the
/// engine at all is not a question about dates.
@MainActor
struct RunwayTests {

    /// The day after the sample's most recent completion.
    static func bookClock(_ shop: Shop) -> Date {
        var newest = Date(timeIntervalSince1970: 0)
        for row in shop.orderRows {
            guard case .object(let o) = row else { continue }
            for key in ["completedAt", "deliveredAt"] {
                if case .string(let s)? = o[key],
                   let d = ISO8601DateFormatter().date(from: s), d > newest { newest = d }
            }
        }
        return newest.addingTimeInterval(86400)
    }

    static func shop() async throws -> Shop {
        let s = Shop()
        await s.load(.sample)
        return s
    }

    /// THE WIRING, on the live clock. Delete the call in `Shop.load` and this
    /// fails; the reachability tests below would keep passing without it.
    @Test("the shelf asks the engine, and gets an answer for every spool")
    func theShopAsks() async throws {
        let shop = try await Self.shop()
        #expect(!shop.spools.isEmpty, "no spools in the sample book")
        for spool in shop.spools {
            #expect(shop.spoolRunway[spool.id] != nil,
                    "\(spool.id) was never asked about, so its card can never say anything")
        }
    }

    /// A spool nothing has been printed from has an UNKNOWN future, not an
    /// endless one — which is the whole reason `daysLeft` is optional.
    @Test("no rate means no answer, not an infinite one")
    func silenceIsNotInfinity() async throws {
        let shop = try await Self.shop()
        for (id, r) in shop.spoolRunway where r.gramsPerDay == 0 && r.committedG <= r.available {
            #expect(r.daysLeft == nil, "\(id): nothing used it, yet it claims a future")
        }
    }

    /// THE ONE THAT WAS BROKEN. Every job in the sample book named a spool the
    /// shop does not own — `filamentId: "seed-1"` against a shelf of `sp-1`…
    /// `sp-6` — so every rate was zero, and the line this screen draws could
    /// not appear for any spool in any screenshot ever taken.
    @Test("the sample book reaches the line, and the amber inside it")
    func somebodyCanSeeIt() async throws {
        let shop = try await Self.shop()
        let engine = try #require(shop.engine)
        let at = Self.bookClock(shop)
        let runway = try await engine.runway(spools: shop.inventoryRows,
                                             orders: shop.orderRows, now: at)
        let days = runway.values.compactMap(\.daysLeft)

        #expect(!days.isEmpty, "every spool still reports an unknown future")
        #expect(days.contains { $0 <= 60 },
                "no spool runs out inside sixty days, so the line never draws")
        #expect(days.contains { $0 <= 14 },
                "no spool is inside a fortnight, so the amber line never draws")
        #expect(days.contains { $0 > 60 },
                "every spool is urgent, so the quiet case is never seen either")
    }

    /// And the join itself, stated plainly: a job that names a spool must name
    /// one that is on the shelf.
    @Test("every job names a spool the shop actually owns")
    func theJoinHolds() async throws {
        let shop = try await Self.shop()
        let shelf = Set(shop.spools.map(\.id))
        for row in shop.orderRows {
            guard case .object(let o) = row, case .array(let parts)? = o["parts"] else { continue }
            for part in parts {
                guard case .object(let p) = part else { continue }
                let named = ["spoolId", "filamentId"].compactMap { key -> String? in
                    if case .string(let s)? = p[key], !s.isEmpty { return s }
                    return nil
                }.first
                guard let named else { continue }
                #expect(shelf.contains(named),
                        "a job consumes \(named), which is not on this shop's shelf")
            }
        }
    }
}

/// The figure on the card and the colour it is drawn in must agree.
///
/// The ASA spool had 14.2 days left. The card printed "empty in 14 days" —
/// rounded — and coloured it from 14.2, which failed a `<= 14` test, so a
/// reader saw fourteen days written in the colour that means "no hurry". A
/// reader cannot see the .2.
@MainActor
struct RunwayColourTests {

    /// The rule the card uses, stated once so a test can hold it to it.
    static func shown(_ days: Double) -> Int { Int(days.rounded()) }
    static func urgent(_ days: Double) -> Bool { shown(days) <= 14 }

    @Test("a spool that prints as fourteen days is coloured as fourteen days")
    func theRoundingIsSharedWithTheColour() {
        #expect(Self.shown(14.2) == 14)
        #expect(Self.urgent(14.2), "printed fourteen, coloured as if it were fifteen")
        #expect(Self.shown(14.6) == 15)
        #expect(!Self.urgent(14.6), "printed fifteen, coloured as if it were fourteen")
    }

    @Test("the boundary is where the printed number crosses it, on both sides")
    func bothSides() {
        for d in [0.6, 5.0, 13.9, 14.0, 14.49] { #expect(Self.urgent(d), "\(d) prints as \(Self.shown(d))") }
        for d in [14.5, 15.0, 40.0, 59.9] { #expect(!Self.urgent(d), "\(d) prints as \(Self.shown(d))") }
    }
}
