import Foundation
import Testing
@testable import KhaytCore

/// How many quotes turn into work, through the engine.
///
/// `test/quote-funnel.test.js` pins the rules. What matters here is that the
/// correction survives: a delivered job is finished work, and leaving it out is
/// what made the other app's win rate too low for every shop that marks work
/// delivered.
@Suite struct QuoteFunnelTests {

    static let now = Date(timeIntervalSince1970: 1_789_084_800)   // 2026-09-11

    static func quote(_ id: String, _ status: String, price: Double,
                      sent: String? = nil, accepted: String? = nil,
                      date: String = "2026-08-01") -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "status": .string(status),
            "date": .string(date), "price": .number(price),
        ]
        if let sent { o["quoteSentAt"] = .string(sent) }
        if let accepted { o["quoteAcceptedAt"] = .string(accepted) }
        return .object(o)
    }

    static func run(_ engine: KhaytEngine,
                    _ orders: [JSONValue]) async throws -> KhaytEngine.QuoteFunnel {
        try await engine.quoteFunnel(orders: orders, now: now, settings: [:], clients: [])
    }

    static func step(_ f: KhaytEngine.QuoteFunnel, _ key: String) -> KhaytEngine.QuoteFunnel.Step? {
        f.steps.first { $0.key == key }
    }

    /// THE CORRECTION. `delivered` is past `completed` in Khayt's pipeline.
    @Test("delivered work is finished work, so the win rate is not too low")
    func deliveredCounts() async throws {
        let engine = try KhaytEngine()
        let funnel = try await Self.run(engine, [
            Self.quote("1", "delivered", price: 100, sent: "2026-08-01", accepted: "2026-08-02"),
            Self.quote("2", "completed", price: 100, sent: "2026-08-01", accepted: "2026-08-02"),
        ])
        #expect(Self.step(funnel, "finished")?.count == 2)
        #expect(funnel.totals.winRateByCount == 1)
    }

    @Test("a cancelled quote was accepted and was not converted")
    func cancelledIsNotConverted() async throws {
        let engine = try KhaytEngine()
        let funnel = try await Self.run(engine, [
            Self.quote("1", "cancelled", price: 9000, sent: "2026-08-01", accepted: "2026-08-02"),
            Self.quote("2", "printing", price: 100, sent: "2026-08-01", accepted: "2026-08-02"),
        ])
        #expect(Self.step(funnel, "accepted")?.count == 2)
        #expect(Self.step(funnel, "converted")?.count == 1)
        #expect(Self.step(funnel, "finished")?.count == 0)
    }

    /// Ten small quotes won and one large one lost is a very different month
    /// from the reverse, and a count cannot tell them apart.
    @Test("the two win rates disagree, which is the point of having both")
    func bothRatesAreReported() async throws {
        let engine = try KhaytEngine()
        let funnel = try await Self.run(engine, [
            Self.quote("1", "completed", price: 1000, sent: "2026-08-01", accepted: "2026-08-02"),
            Self.quote("2", "quote", price: 99000, sent: "2026-08-01"),
        ])
        #expect(funnel.totals.winRateByCount == 0.5)
        #expect(funnel.totals.winRateByValue == 0.01)
    }

    /// A funnel is a report; an open quote is a phone call.
    @Test("quotes still waiting are counted, valued and dated")
    func openQuotesAreActionable() async throws {
        let engine = try KhaytEngine()
        let funnel = try await Self.run(engine, [
            Self.quote("1", "quote", price: 20000, sent: "2026-07-01"),
            Self.quote("2", "quote", price: 500, sent: "2026-09-09"),
        ])
        #expect(funnel.totals.openCount == 2)
        #expect(funnel.totals.openValue == 20500)
        #expect(funnel.totals.oldestOpenDays == 72)
    }

    /// Nought would read as "you win nothing", which is a different and untrue
    /// claim about a shop that has simply never quoted.
    @Test("a shop that has never quoted has no rate, not a rate of nought")
    func neverQuotedHasNoRate() async throws {
        let engine = try KhaytEngine()
        let funnel = try await Self.run(engine, [
            Self.quote("1", "completed", price: 500),   // no quote history at all
        ])
        #expect(Self.step(funnel, "created")?.count == 0)
        #expect(funnel.totals.winRateByCount == nil)
        #expect(funnel.totals.medianDaysToDecide == nil)
    }

    /// A screen can only have been reviewed against data that reaches it.
    @Test("the sample shop reaches every step of the funnel")
    func theSampleReachesIt() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root, case .array(let orders)? = book["printLog"] else {
            Issue.record("could not read the sample shop"); return
        }
        let engine = try KhaytEngine()
        let funnel = try await Self.run(engine, orders)
        for step in funnel.steps {
            #expect(step.count > 0, "step \(step.key) is never drawn with data in it")
        }
        // And the steps must actually narrow, or the chart shows nothing.
        #expect(try #require(Self.step(funnel, "finished")).count
                < #require(Self.step(funnel, "created")).count)
        #expect(funnel.totals.openCount > 0, "no open quote, so that sentence is undrawn")
    }
}
