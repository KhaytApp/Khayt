import Foundation
import Testing
@testable import KhaytCore

/// How many quotes turn into work, against the JavaScript it came from.
///
/// Two of the faults the module exists for are systematic rather than edge
/// cases — a win rate too low for every shop that marks work delivered, and a
/// cancelled job counted as won — so both are pinned.
@MainActor
struct QuoteFunnelParityTests {

    private func js() throws -> JSModule { try JSModule(["quote-funnel"]) }

    private func check(_ orders: [JSONValue], now: Double, _ what: String,
                       _ js: JSModule) throws {
        let prices = orders.map { order -> Double in
            guard case .object(let o) = order else { return 0 }
            let n = JSSemantics.number(o["price"])
            return n.isFinite ? n : 0
        }
        let mine = QuoteFunnel.report(orders: orders, prices: prices, now: now)
        let v = try js.value("""
            globalThis.KhaytQuoteFunnel.quoteFunnel({orders: ARG0, now: ARG1}, {
              priceOf: function (o) { var n = Number(o && o.price);
                                      return isFinite(n) ? n : 0; }})
            """, [.array(orders), .number(now)])
        guard case .object(let o) = v, case .array(let rows)? = o["steps"],
              case .object(let t)? = o["totals"] else {
            Issue.record("not a report"); return
        }
        let theirSteps: [QuoteFunnel.Step] = rows.map { row in
            guard case .object(let r) = row else { return .init(key: "?", count: -1, value: -1) }
            return .init(key: JSSemantics.text(r["key"]),
                         count: Int(JSSemantics.number(r["count"])),
                         value: JSSemantics.number(r["value"]))
        }
        func maybe(_ k: String) -> Double? {
            if case .number(let n)? = t[k] { return n }; return nil
        }
        let theirs = QuoteFunnel.Report(steps: theirSteps, totals: .init(
            winRateByCount: maybe("winRateByCount"),
            winRateByValue: maybe("winRateByValue"),
            medianDaysToDecide: maybe("medianDaysToDecide"),
            openCount: Int(JSSemantics.number(t["openCount"])),
            openValue: JSSemantics.number(t["openValue"]),
            oldestOpenDays: maybe("oldestOpenDays").map { Int($0) }))
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine.steps) \(mine.totals)
              js    \(theirs.steps) \(theirs.totals)
            """))
    }

    private func quote(_ id: String, status: String, price: Double,
                       date: String = "2026-09-01",
                       sent: String = "", accepted: String = "",
                       voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status),
                                      "price": .number(price), "date": .string(date)]
        if !sent.isEmpty { o["quoteSentAt"] = .string(sent) }
        if !accepted.isEmpty { o["quoteAcceptedAt"] = .string(accepted) }
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    /// 2026-09-18T09:00:00Z.
    private let now = 1789707600000.0

    private var book: [JSONValue] {
        [quote("Q-1", status: "quote", price: 500, sent: "2026-09-02"),
         quote("Q-2", status: "quote", price: 1200, sent: "2026-08-20"),
         quote("Q-3", status: "printing", price: 3000, sent: "2026-08-25",
               accepted: "2026-08-28"),
         // Delivered — the step that used to fall out of the funnel entirely.
         quote("Q-4", status: "delivered", price: 900, sent: "2026-08-01",
               accepted: "2026-08-03"),
         quote("Q-5", status: "completed", price: 400, sent: "2026-08-05",
               accepted: "2026-08-06"),
         // Cancelled after being accepted — NOT converted.
         quote("Q-6", status: "cancelled", price: 7000, sent: "2026-08-10",
               accepted: "2026-08-11"),
         quote("Q-7", status: "completed", price: 250,
               sent: "2026-08-01", accepted: "2026-08-02", voided: true),
         // Never quoted at all — not in the funnel.
         quote("Q-8", status: "completed", price: 600),
         // Accepted with no sent stamp: the decision is measured from its date.
         quote("Q-9", status: "completed", price: 800, date: "2026-08-14",
               accepted: "2026-08-18"),
         .null, .string("x"), .number(1), .object([:])]
    }

    @Test("a real quarter of quoting")
    func realBook() throws {
        let js = try js()
        try check(book, now: now, "a quarter", js)
        try check([], now: now, "nothing at all", js)
    }

    @Test("delivered work counts as won, which is what used to be missing")
    func deliveredCounts() throws {
        // Every shop that marks work delivered had a win rate that was too low.
        let js = try js()
        let only = [quote("Q-1", status: "delivered", price: 100, sent: "2026-09-01",
                          accepted: "2026-09-02")]
        try check(only, now: now, "one delivered job", js)
        let mine = QuoteFunnel.report(orders: only, prices: [100], now: now)
        #expect(mine.steps.last?.count == 1, "a delivered job left the funnel")
        #expect(mine.totals.winRateByCount == 1)
    }

    @Test("a cancelled job is not a win")
    func cancelledIsNotConverted() throws {
        let js = try js()
        try check([quote("Q-1", status: "cancelled", price: 7000, sent: "2026-09-01",
                         accepted: "2026-09-02")], now: now, "cancelled", js)
        let mine = QuoteFunnel.report(
            orders: [quote("Q-1", status: "cancelled", price: 7000, sent: "2026-09-01",
                           accepted: "2026-09-02")], prices: [7000], now: now)
        #expect(mine.steps.first(where: { $0.key == "converted" })?.count == 0)
    }

    @Test("both rates, because a count cannot tell the two months apart")
    func bothRates() throws {
        // Ten small quotes won and one large one lost, then the reverse.
        let js = try js()
        var small: [JSONValue] = (1...10).map {
            quote("S-\($0)", status: "completed", price: 100,
                  sent: "2026-09-01", accepted: "2026-09-02")
        }
        small.append(quote("L-1", status: "quote", price: 5000, sent: "2026-09-01"))
        try check(small, now: now, "ten small won", js)

        var large: [JSONValue] = (1...10).map {
            quote("S-\($0)", status: "quote", price: 100, sent: "2026-09-01")
        }
        large.append(quote("L-1", status: "completed", price: 5000,
                           sent: "2026-09-01", accepted: "2026-09-02"))
        try check(large, now: now, "one large won", js)
    }

    @Test("how long a decision took, as a median")
    func medianDecision() throws {
        let js = try js()
        // An even count, an odd count, and one accepted BEFORE it was sent.
        try check([quote("Q-1", status: "completed", price: 10, sent: "2026-09-01",
                         accepted: "2026-09-03"),
                   quote("Q-2", status: "completed", price: 10, sent: "2026-09-01",
                         accepted: "2026-09-11"),
                   quote("Q-3", status: "completed", price: 10, sent: "2026-09-10",
                         accepted: "2026-09-01")],
                  now: now, "three decisions", js)
        #expect(QuoteFunnel.median([]) == nil)
        #expect(QuoteFunnel.median([3]) == 3)
        #expect(QuoteFunnel.median([1, 3]) == 2)
        #expect(QuoteFunnel.median([5, 1, 3]) == 3)
    }

    @Test("what is still open, and how long the oldest has waited")
    func openQuotes() throws {
        let js = try js()
        try check([quote("Q-1", status: "quote", price: 100, sent: "2026-09-17"),
                   quote("Q-2", status: "quote", price: 200, sent: "2026-06-01"),
                   // Sent in the FUTURE — clamped at zero rather than negative.
                   quote("Q-3", status: "quote", price: 300, sent: "2026-12-01"),
                   // No stamps at all: measured from its own date.
                   quote("Q-4", status: "quote", price: 400, date: "2026-07-04")],
                  now: now, "four open", js)
    }

    @Test("a stamp outside the ISO grammar is no stamp, which the book cannot hold")
    func nonIsoStampsDiverge() throws {
        // `Date.parse("0")` reads as the YEAR 2000 in JavaScript, so a
        // `quoteSentAt` of `0` makes the original report a quote seven hundred
        // thousand days old. `JSDate.parse` implements the ISO grammar only —
        // a scope chosen by counting every stamp in both books and finding all
        // of them ISO — so it answers nothing and the quote has no age.
        //
        // Deliberate, and asserted rather than papered over: if the legacy
        // grammar is ever added, this test says where to look.
        #expect(QuoteFunnel.timeOf(.number(0)) == nil)
        #expect(QuoteFunnel.timeOf(.string("0")) == nil)
        #expect(QuoteFunnel.timeOf(.string("March 3, 2026")) == nil)
        #expect(QuoteFunnel.timeOf(.string("2026/09/01")) == nil)
        // The shapes a book really holds do parse, on both sides.
        #expect(QuoteFunnel.timeOf(.string("2026-09-01")) != nil)
        #expect(QuoteFunnel.timeOf(.string("2026-09-01T08:00:00Z")) != nil)
        #expect(QuoteFunnel.timeOf(.string("")) == nil)
        #expect(QuoteFunnel.timeOf(.null) == nil)
        // A bare day is midnight UTC here, unlike `cycle-time`, which reads its
        // bare days local because it buckets by month. This one measures
        // durations, and both ends in one zone keeps a quote's age the same
        // number wherever it is read.
        #expect(QuoteFunnel.timeOf(.string("2026-09-01"))
                == QuoteFunnel.timeOf(.string("2026-09-01T00:00:00Z")))
    }

    @Test("stamps and prices that are not what they should be")
    func degenerate() throws {
        let js = try js()
        try check([quote("Q-1", status: "quote", price: 100, date: "not a date"),
                   .object(["id": .string("Q-2"), "status": .string("quote"),
                            "price": .string("250"),
                            "quoteSentAt": .string("2026-09-02T08:00:00Z")]),
                   .object(["id": .string("Q-3"), "status": .number(1),
                            "quoteAcceptedAt": .string("2026-09-01")]),
                   .object(["id": .string("Q-4"), "quoteSentAt": .string("2026-09-01"),
                            "price": .null])],
                  now: now, "a mess", js)
    }
}
