import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Selling a piece that was printed weeks ago.
///
/// ── WHY EVERYTHING LANDS ON THE SALE ──────────────────────────────────────
///
/// A shelf piece was made in August for nobody in particular and sells in
/// October. The shop chose to recognise its COST at the sale, which keeps each
/// sale's margin honest and matches how the catalogue already prices a piece.
///
/// The print HOURS have to follow, and that is not a style choice:
/// `lib/cost-trends.js` computes revenue per print-hour by summing both and
/// dividing, so revenue arriving with no hours behind it would inflate what a
/// shop believes an hour of its own printing earns. Recording zero hours
/// against a real sale corrupts a headline figure silently.
@MainActor
struct SellFromShelfTests {

    /// The marker travels through the shared rule and comes back on the
    /// record — the half a Swift-only change would have missed.
    @Test("an order can say it came off the shelf")
    func theMarkerSurvivesTheRule() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.newOrder(
            ["project": .string("Kaaba desk piece"),
             "parts": .array([.object(["name": .string("body"), "qty": .number(1),
                                       "printWeight": .number(120), "printTime": .number(2.4),
                                       "unitCost": .number(30)])]),
             "margin": .number(50), "fromStock": .bool(true)],
            orders: [], settings: [:], now: Date(),
            tokens: (tracking: [1], quoteApproval: [2]))
        guard case .object(let record) = out.order else { Issue.record("no order"); return }
        #expect(record["fromStock"] == .bool(true), "the marker did not reach the record")
    }

    /// And an ordinary job does NOT carry it, so not one record in any
    /// existing book changes shape.
    @Test("a made-to-order job is unmarked, not marked false")
    func ordinaryJobsAreUntouched() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.newOrder(
            ["project": .string("Turbine bracket"),
             "parts": .array([.object(["name": .string("b"), "qty": .number(1),
                                       "printWeight": .number(50), "printTime": .number(1),
                                       "unitCost": .number(10)])]),
             "margin": .number(40)],
            orders: [], settings: [:], now: Date(),
            tokens: (tracking: [1], quoteApproval: [2]))
        guard case .object(let record) = out.order else { Issue.record("no order"); return }
        #expect(record["fromStock"] == nil || record["fromStock"] == .null, """
            an ordinary job carries the marker, so every order in every book \
            changes shape for a feature it does not use
            """)
    }

    /// Swift reads it back, and reads its absence as "made to order" rather
    /// than as a decoding failure — which is every order written before this.
    @Test("an order written before the shelf existed decodes as made to order")
    func absentMeansMadeToOrder() throws {
        let plain = try JSONDecoder().decode(Order.self, from: Data("""
        {"id":"ORD-1","date":"2026-01-01","status":"completed","project":"x","price":10,"paidAmount":0,"costBasis":4,"printTime":1,"currency":"SAR","client":"","paymentStatus":"unpaid","priority":false,"notes":"","parts":[]}
        """.utf8))
        #expect(plain.fromStock == false)
        let sold = try JSONDecoder().decode(Order.self, from: Data("""
        {"id":"ORD-2","date":"2026-01-01","status":"completed","project":"x","price":10,"paidAmount":10,"costBasis":4,"printTime":1,"currency":"SAR","client":"","paymentStatus":"paid","priority":false,"notes":"","parts":[],"fromStock":true}
        """.utf8))
        #expect(sold.fromStock)
    }

    /// THE ONE THAT PROTECTS A HEADLINE FIGURE. Revenue with no hours behind
    /// it inflates revenue-per-print-hour, and nothing on screen would say so.
    @Test("a sale carrying no hours would inflate what an hour earns")
    func hoursMustTravelWithTheSale() async throws {
        let engine = try KhaytEngine()
        func trend(hours: Double) async throws -> Double? {
            let job: JSONValue = .object([
                "id": .string("ORD-S"), "date": .string("2026-09-10"),
                "status": .string("completed"), "price": .number(500),
                "printTime": .number(hours),
                "parts": .array([.object(["printWeight": .number(100), "qty": .number(1),
                                          "printTime": .number(hours)])]),
            ])
            let out = try await engine.costTrends(orders: [job], spools: [], settings: [:],
                                                  clients: [], now: Date(timeIntervalSince1970: 1_789_000_000),
                                                  months: 3)
            return out.perHour
        }
        let withHours = try await trend(hours: 2.5)
        let without = try await trend(hours: 0)
        #expect(withHours != nil, "the fixture stopped producing a reading")
        #expect(without == nil || (withHours ?? 0) < (without ?? .infinity), """
            a zero-hour sale did not distort revenue-per-hour in this fixture, \
            so this test no longer guards the reason the hours travel
            """)
    }
}
