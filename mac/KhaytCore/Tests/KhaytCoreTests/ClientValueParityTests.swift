import Foundation
import Testing
@testable import KhaytCore

/// Which customers are worth keeping, against the JavaScript it came from.
///
/// The table this replaced counted every order with a client's id on it, so
/// the cases worth pinning are the ones it got wrong: a quote is not value, a
/// voided job is not value, and a name that has never bought is not "quiet".
@MainActor
struct ClientValueParityTests {

    private func js() throws -> JSModule { try JSModule(["client-value"]) }

    private func check(_ clients: [JSONValue], _ orders: [JSONValue],
                       now: Double, quietDays: Double = 90, limit: Int = 10,
                       _ what: String, _ js: JSModule) throws {
        let revenues = orders.map { order -> Double in
            guard case .object(let o) = order else { return 0 }
            let n = JSSemantics.number(o["price"])
            return n.isFinite ? n : 0
        }
        let mine = ClientValue.report(clients: clients, orders: orders, revenues: revenues,
                                      now: now, quietDays: quietDays, limit: limit)
        let v = try js.value("""
            globalThis.KhaytClientValue.clientValue(
              {clients: ARG0, orders: ARG1, now: ARG2, quietDays: ARG3, limit: ARG4},
              {revenueOf: function (o) { var n = Number(o && o.price);
                                         return isFinite(n) ? n : 0; }})
            """, [.array(clients), .array(orders), .number(now),
                  .number(quietDays), .number(Double(limit))])
        guard case .object(let o) = v, case .array(let rows)? = o["rows"],
              case .object(let t)? = o["totals"] else {
            Issue.record("not a report"); return
        }
        let theirRows: [ClientValue.Row] = rows.map { row in
            guard case .object(let r) = row else {
                return .init(clientId: "?", name: "?", value: -1, jobs: -1, averageJob: -1,
                             lastSeen: nil, daysSince: nil, quiet: false,
                             shareOfRevenue: -1, inFlight: -1)
            }
            var seen: Double?; if case .number(let n)? = r["lastSeen"] { seen = n }
            var since: Int?; if case .number(let n)? = r["daysSince"] { since = Int(n) }
            var quiet = false; if case .bool(let b)? = r["quiet"] { quiet = b }
            return .init(clientId: JSSemantics.text(r["clientId"]),
                         name: JSSemantics.text(r["name"]),
                         value: JSSemantics.number(r["value"]),
                         jobs: Int(JSSemantics.number(r["jobs"])),
                         averageJob: JSSemantics.number(r["averageJob"]),
                         lastSeen: seen, daysSince: since, quiet: quiet,
                         shareOfRevenue: JSSemantics.number(r["shareOfRevenue"]),
                         inFlight: JSSemantics.number(r["inFlight"]))
        }
        let theirs = ClientValue.Report(rows: theirRows, totals: .init(
            earned: JSSemantics.number(t["earned"]),
            clients: Int(JSSemantics.number(t["clients"])),
            topShare: JSSemantics.number(t["topShare"]),
            quiet: Int(JSSemantics.number(t["quiet"]))))
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine.rows.map { ($0.clientId, $0.value, $0.inFlight, $0.quiet) }) \(mine.totals)
              js    \(theirs.rows.map { ($0.clientId, $0.value, $0.inFlight, $0.quiet) }) \(theirs.totals)
            """))
    }

    private func client(_ id: String, _ name: String, company: String = "") -> JSONValue {
        var c: [String: JSONValue] = ["id": .string(id)]
        if !name.isEmpty { c["name"] = .string(name) }
        if !company.isEmpty { c["company"] = .string(company) }
        return .object(c)
    }

    private func job(_ client: String, price: Double, status: String = "completed",
                     date: String = "2026-09-01", done: String = "",
                     voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["clientId": .string(client), "price": .number(price),
                                      "status": .string(status), "date": .string(date)]
        if !done.isEmpty { o["completedAt"] = .string(done) }
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    /// 2026-09-18T09:00:00Z.
    private let now = 1789707600000.0

    private var clients: [JSONValue] {
        [client("C-1", "Salem"), client("C-2", "", company: "Aramco"),
         client("C-3", "Noura"), client("C-4", "Never bought"),
         client("", "No id"), .null, .string("x"), .object([:])]
    }

    @Test("a real book of customers")
    func realBook() throws {
        let js = try js()
        try check(clients, [
            job("C-1", price: 1200, done: "2026-09-04T10:00:00Z"),
            job("C-1", price: 800, status: "delivered", date: "2026-08-02"),
            job("C-2", price: 5000, done: "2026-09-10T10:00:00Z"),
            job("C-3", price: 300, done: "2026-02-01T10:00:00Z"),
            // A quote is NOT value, and is not in flight either.
            job("C-1", price: 9000, status: "quote"),
            // Agreed and under way: in flight, not value.
            job("C-2", price: 4000, status: "printing"),
            job("C-3", price: 700, status: "cancelled"),
            job("C-1", price: 400, voided: true),
            job("C-9", price: 100),           // a client nobody has
            .null, .string("x"), .object([:]),
        ], now: now, "a real book", js)
    }

    @Test("a quote at the top of lifetime value is the fault this exists for")
    func quotesAreNotValue() throws {
        let js = try js()
        try check([client("C-1", "Asks a lot"), client("C-2", "Buys")],
                  [job("C-1", price: 50000, status: "quote"),
                   job("C-1", price: 50000, status: "quote"),
                   job("C-2", price: 900, done: "2026-09-01T10:00:00Z")],
                  now: now, "ten quotes and no sale", js)
        let mine = ClientValue.report(
            clients: [client("C-1", "Asks a lot")],
            orders: [job("C-1", price: 50000, status: "quote")],
            revenues: [50000], now: now)
        #expect(mine.totals.earned == 0, "a quote counted as earned")
        #expect(mine.rows.isEmpty, "a customer who has bought nothing is ranked")
    }

    @Test("a name that has never bought is not quiet")
    func neverBoughtIsNotQuiet() throws {
        // Calling it churn risk would put every new name on a list the shop is
        // meant to act on.
        let js = try js()
        try check([client("C-1", "New"), client("C-2", "Old")],
                  [job("C-2", price: 100, done: "2026-01-01T10:00:00Z")],
                  now: now, "one new, one long gone", js)
        let mine = ClientValue.report(
            clients: [client("C-1", "New")], orders: [], revenues: [], now: now)
        #expect(mine.totals.quiet == 0)
    }

    @Test("how long is quiet, including nought and nonsense")
    func quietWindows() throws {
        let js = try js()
        for quiet in [90.0, 0, 1, 365, -5, 10000] {
            try check([client("C-1", "Salem")],
                      [job("C-1", price: 100, done: "2026-06-01T10:00:00Z")],
                      now: now, quietDays: quiet, "quiet after \(quiet)", js)
        }
    }

    @Test("the ranking, its tie-breaks, and the limit")
    func rankingAndLimit() throws {
        let js = try js()
        let people = [client("C-1", "Zahra"), client("C-2", "Adel"), client("C-3", "Badr")]
        // All three earned the same: in-flight breaks the tie, then the name.
        try check(people, [job("C-1", price: 100, done: "2026-09-01T10:00:00Z"),
                           job("C-2", price: 100, done: "2026-09-01T10:00:00Z"),
                           job("C-3", price: 100, done: "2026-09-01T10:00:00Z"),
                           job("C-2", price: 500, status: "printing")],
                  now: now, "a three-way tie", js)
        for limit in [10, 1, 2, 0, -1, 100] {
            try check(people, [job("C-1", price: 300, done: "2026-09-01T10:00:00Z"),
                               job("C-2", price: 200, done: "2026-09-01T10:00:00Z"),
                               job("C-3", price: 100, done: "2026-09-01T10:00:00Z")],
                      now: now, limit: limit, "limit \(limit)", js)
        }
    }

    @Test("how badly it would hurt to lose the biggest one")
    func topShare() throws {
        let js = try js()
        try check([client("C-1", "Most of it"), client("C-2", "The rest")],
                  [job("C-1", price: 6000, done: "2026-09-01T10:00:00Z"),
                   job("C-2", price: 4000, done: "2026-09-01T10:00:00Z")],
                  now: now, "sixty forty", js)
        try check([client("C-1", "Only one")],
                  [job("C-1", price: 6000, done: "2026-09-01T10:00:00Z")],
                  now: now, "all of it", js)
        try check([client("C-1", "Nobody")], [], now: now, "nothing at all", js)
    }
}
