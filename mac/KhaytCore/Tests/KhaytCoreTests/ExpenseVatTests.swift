import Testing
import Foundation
@testable import KhaytCore

/// The tax a shop pays on its own purchases.
///
/// Khayt has never asked for it, so every expense in every existing book
/// carries none — and must keep costing exactly what it cost. What is new is
/// that a shop CAN record it, and when it does, the tax stops being a cost and
/// starts being something it reclaims.
struct ExpenseVatTests {

    static func made(_ input: [String: JSONValue]) async throws -> [String: JSONValue] {
        let engine = try KhaytEngine()
        let written = try await engine.newExpense(input, id: "EXP-1", today: "2026-09-08")
        guard case .object(let record)? = written.expense else {
            Issue.record("the rule refused: \(written.refused ?? "no reason")")
            return [:]
        }
        return record
    }

    static func number(_ v: JSONValue?) -> Double? {
        if case .number(let n)? = v { return n }
        return nil
    }

    @Test func anExpenseWithNoTaxRecordedCarriesZero() async throws {
        let record = try await Self.made(["amount": .number(230), "category": .string("filament"),
                                          "date": .string("2026-09-08")])
        #expect(Self.number(record["amount"]) == 230)
        #expect(Self.number(record["vatAmount"]) == 0,
                "an expense that says nothing about tax reclaims nothing")
    }

    @Test func theTaxOnTheReceiptIsKept() async throws {
        let record = try await Self.made(["amount": .number(230), "vatAmount": .number(30),
                                          "category": .string("filament"),
                                          "date": .string("2026-09-08")])
        #expect(Self.number(record["amount"]) == 230, "what was paid is what was paid")
        #expect(Self.number(record["vatAmount"]) == 30)
    }

    /// A mistyped tax must not stop somebody recording what they spent, so the
    /// rule clamps rather than refuses — and the clamp is the shared one, so
    /// both apps write the same record.
    @Test func aReceiptCannotCarryMoreTaxThanItCost() async throws {
        for (typed, expected) in [(500.0, 100.0), (-5.0, 0.0), (0.0, 0.0)] {
            let record = try await Self.made(["amount": .number(100),
                                              "vatAmount": .number(typed),
                                              "category": .string("other"),
                                              "date": .string("2026-09-08")])
            #expect(Self.number(record["amount"]) == 100)
            #expect(Self.number(record["vatAmount"]) == expected,
                    "\(typed) on a 100 receipt should clamp to \(expected)")
        }
    }
}
