import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A job nobody charged for has not been paid for.
///
/// ── HOW THIS WAS FOUND ────────────────────────────────────────────────────
///
/// By photographing the app against a book shaped like a real shop's: twenty
/// finished jobs, one of them priced, nobody written down. The jobs table drew
/// a `Total` column of twenty `0.00`s and an `Owed` column reading **settled**
/// twenty times — the app telling a shop it had been paid for work it never
/// charged for.
///
/// `isSettled` is `owed < 0.005`, and that is true of an unpriced job as
/// surely as of a paid one. The figure was right; the word was a claim.
@MainActor
struct UnpricedIsNotSettledTests {

    static func job(_ id: String, price: Double, paid: Double = 0) throws -> Order {
        let row: [String: JSONValue] = [
            "id": .string(id), "date": .string("2026-09-01"), "status": .string("completed"),
            "project": .string("P-" + id), "client": .string(""), "price": .number(price),
            "paidAmount": .number(paid), "paymentStatus": .string(paid >= price && price > 0 ? "paid" : "unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""),
        ]
        return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
    }

    @Test("an unpriced job owes nothing and is not settled either")
    func unpricedIsNeither() throws {
        let unpriced = try Self.job("A", price: 0)
        #expect(unpriced.owed == 0, "nothing is owed on a job with no price")
        #expect(unpriced.isSettled, "the arithmetic still says nothing is outstanding")
        // …which is exactly why the table cannot use `isSettled` alone to
        // choose its WORD. The price is what tells the two apart.
        #expect(unpriced.price <= 0)
    }

    @Test("a paid job is settled, and says so")
    func paidIsSettled() throws {
        let paid = try Self.job("B", price: 180, paid: 180)
        #expect(paid.isSettled)
        #expect(paid.price > 0)
    }

    @Test("a customer whose work was never priced is not a settled customer")
    func customerWithoutAPrice() throws {
        let person = Customer(id: "CLI-1", name: "Acme",
                              orders: [try Self.job("A", price: 0), try Self.job("B", price: 0)],
                              clientId: nil, record: nil)
        #expect(person.owed == 0)
        #expect(person.isSettled, "the arithmetic agrees nothing is outstanding")
        #expect(!person.hasAPrice, "but nothing was ever charged, so there is nothing to settle")
    }

    @Test("a customer with one priced job has a price")
    func customerWithAPrice() throws {
        let person = Customer(id: "CLI-1", name: "Acme",
                              orders: [try Self.job("A", price: 0), try Self.job("B", price: 180, paid: 180)],
                              clientId: nil, record: nil)
        #expect(person.hasAPrice)
        #expect(person.isSettled)
    }

    @Test("the tables ask the price before they use the word")
    func theTablesCheckTheprice() throws {
        // The word is chosen in a SwiftUI body, which no test here can render.
        // What is checkable is that neither table reaches `isSettled` without
        // asking about the price first — delete either guard and this fails.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let jobs = try String(contentsOf: sources.appending(path: "OrdersTable.swift"), encoding: .utf8)
        let people = try String(contentsOf: sources.appending(path: "CustomersTable.swift"), encoding: .utf8)
        #expect(jobs.contains("if job.price <= 0"),
                "the jobs table calls an unpriced job settled again")
        #expect(people.contains("if !person.hasAPrice"),
                "the customers table calls an unpriced customer settled again")
    }
}
