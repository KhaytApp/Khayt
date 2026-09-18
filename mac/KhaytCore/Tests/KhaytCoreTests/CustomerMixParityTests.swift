import Foundation
import Testing
@testable import KhaytCore

/// New customers against returning ones, against the JavaScript it came from.
///
/// The module exists because four separate things were wrong before it, so the
/// cases worth pinning are those four — especially the first, which only shows
/// up when one customer's first two jobs land on the same day.
@MainActor
struct CustomerMixParityTests {

    private func js() throws -> JSModule { try JSModule(["customer-mix"]) }

    private func check(_ orders: [JSONValue], from: String = "", to: String = "",
                       _ what: String, _ js: JSModule) throws {
        // The same `revenueOf` on both sides — the real one is `order-money`,
        // which has not moved.
        let revenues = orders.map { order -> Double in
            guard case .object(let o) = order else { return 0 }
            let n = JSSemantics.number(o["price"])
            return n.isFinite ? n : 0
        }
        let mine = CustomerMix.report(orders: orders, revenues: revenues, from: from, to: to)
        let v = try js.value("""
            globalThis.KhaytCustomerMix.customerMix(
              {orders: ARG0, from: ARG1, to: ARG2},
              {revenueOf: function (o) { var n = Number(o && o.price);
                                         return isFinite(n) ? n : 0; }})
            """, [.array(orders), .string(from), .string(to)])
        guard case .object(let o) = v else { Issue.record("not a report"); return }
        func side(_ key: String) -> CustomerMix.Side {
            guard case .object(let s)? = o[key] else {
                return .init(revenue: -1, jobs: -1, clients: -1, shareOfRevenue: nil)
            }
            var share: Double?; if case .number(let n)? = s["shareOfRevenue"] { share = n }
            return .init(revenue: JSSemantics.number(s["revenue"]),
                         jobs: Int(JSSemantics.number(s["jobs"])),
                         clients: Int(JSSemantics.number(s["clients"])),
                         shareOfRevenue: share)
        }
        var totals = CustomerMix.Totals(revenue: -1, jobs: -1, clients: -1, firstOrderValue: nil)
        if case .object(let t)? = o["totals"] {
            var first: Double?; if case .number(let n)? = t["firstOrderValue"] { first = n }
            totals = .init(revenue: JSSemantics.number(t["revenue"]),
                           jobs: Int(JSSemantics.number(t["jobs"])),
                           clients: Int(JSSemantics.number(t["clients"])),
                           firstOrderValue: first)
        }
        let theirs = CustomerMix.Report(fresh: side("fresh"), returning: side("returning"),
                                        totals: totals)
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine)
              js    \(theirs)
            """))
    }

    private func job(_ id: String, _ client: String, _ date: String, price: Double,
                     status: String = "completed", voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "clientId": .string(client),
                                      "date": .string(date), "price": .number(price),
                                      "status": .string(status)]
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    @Test("a customer's first two jobs on ONE DAY are one new sale and one repeat")
    func sameDayFirstOrders() throws {
        // The fault the module exists for: comparing dates as strings made both
        // of them new, so a shop taking two jobs from one new customer recorded
        // two new-customer sales.
        let js = try js()
        try check([job("A-1", "C-1", "2026-09-01", price: 100),
                   job("A-2", "C-1", "2026-09-01", price: 200)], "two on one day", js)
        // …and the SECOND by id is the repeat, so the answer does not move.
        try check([job("A-2", "C-1", "2026-09-01", price: 200),
                   job("A-1", "C-1", "2026-09-01", price: 100)], "the other order", js)
    }

    @Test("a real book, and the window inside it")
    func realBook() throws {
        let js = try js()
        let book = [job("A-1", "C-1", "2026-06-02", price: 400),
                    job("A-2", "C-1", "2026-08-10", price: 900),
                    job("A-3", "C-2", "2026-09-01", price: 1200, status: "delivered"),
                    job("A-4", "C-2", "2026-09-14", price: 300),
                    job("A-5", "C-3", "2026-09-20", price: 750),
                    job("A-6", "C-1", "2026-09-28", price: 150),
                    job("A-7", "C-4", "2026-09-05", price: 500, voided: true),
                    job("A-8", "C-5", "2026-09-06", price: 500, status: "printing"),
                    .object(["id": .string("A-9"), "date": .string("2026-09-07"),
                             "status": .string("completed"), "price": .number(90)]),
                    .null, .string("x"), .number(1), .object([:])]
        for (from, to) in [("", ""), ("2026-09-01", "2026-09-30"),
                           ("2026-09-01", ""), ("", "2026-08-31"),
                           ("2026-10-01", "2026-10-31")] {
            try check(book, from: from, to: to,
                      "\(from.debugDescription)…\(to.debugDescription)", js)
        }
    }

    @Test("history decides who is new, even from outside the window")
    func historyIsNotFiltered() throws {
        // A customer whose first order is BEFORE the window is returning inside
        // it. Pre-filtering the orders would have made them new again.
        let js = try js()
        try check([job("A-1", "C-1", "2026-01-05", price: 100),
                   job("A-2", "C-1", "2026-09-10", price: 400)],
                  from: "2026-09-01", to: "2026-09-30", "first order before the window", js)
    }

    @Test("a customer new AND returning inside one window is one person")
    func distinctClients() throws {
        let js = try js()
        try check([job("A-1", "C-1", "2026-09-02", price: 100),
                   job("A-2", "C-1", "2026-09-20", price: 300)],
                  from: "2026-09-01", to: "2026-09-30", "new then back", js)
        let mine = CustomerMix.report(
            orders: [job("A-1", "C-1", "2026-09-02", price: 100),
                     job("A-2", "C-1", "2026-09-20", price: 300)],
            revenues: [100, 300], from: "2026-09-01", to: "2026-09-30")
        #expect(mine.fresh.clients == 1)
        #expect(mine.returning.clients == 1)
        #expect(mine.totals.clients == 1, "one person counted as two")
    }

    @Test("nothing at all has no share, rather than a share of nought")
    func emptyHasNoShare() throws {
        let js = try js()
        try check([], "no orders", js)
        try check([job("A-1", "C-1", "2026-09-01", price: 0)], "no money", js)
        let empty = CustomerMix.report(orders: [], revenues: [])
        #expect(empty.fresh.shareOfRevenue == nil)
        #expect(empty.totals.firstOrderValue == nil)
    }

    @Test("a period picker can override the two dates")
    func windowPredicateOverrides() throws {
        // The other app's range picker owns "this quarter" and hands in a
        // predicate; the two dates are then not consulted at all.
        let book = [job("A-1", "C-1", "2026-01-05", price: 100),
                    job("A-2", "C-2", "2026-09-10", price: 400)]
        let only = CustomerMix.report(orders: book, revenues: [100, 400],
                                      from: "2026-09-01", to: "2026-09-30",
                                      inWindow: { order in
            guard case .object(let o) = order, case .string(let id)? = o["id"] else { return false }
            return id == "A-1"
        })
        #expect(only.totals.jobs == 1)
        #expect(only.totals.revenue == 100, "the dates were consulted anyway")
    }
}
