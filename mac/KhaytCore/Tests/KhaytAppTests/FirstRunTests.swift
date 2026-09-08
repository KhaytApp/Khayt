import Testing
import Foundation
import KhaytCore
@testable import KhaytApp

/// What a shop sees before it has sold anything.
///
/// This is the first screen Khayt ever shows anybody, and it showed eight zeros
/// and a dash: 0.00 revenue, 0.00 gross, 0.00% margin, 0.00 average, "—" on
/// time, 0 jobs, 0 completed. Every figure in that section is over completed
/// jobs, so a book with none has nothing to state — and every other screen in
/// the app draws something when it is empty while the front door totalled
/// nothing and reported it.
@MainActor
struct FirstRunTests {

    /// The distinction the whole thing rests on: a shop that has never traded
    /// is not a shop that had a quiet month. A quiet month really did earn
    /// 0.00 and must still say so.
    @Test func aQuietMonthIsNotAnEmptyBook() throws {
        #expect(Shop.hasNotTraded(orders: []), "no jobs at all")
        #expect(!Shop.hasNotTraded(orders: [try Self.order(status: "completed")]),
                "a completed job means the figures mean something")
        #expect(!Shop.hasNotTraded(orders: [try Self.order(status: "quote")]),
                "even a quote is a book that has started")
    }

    /// Asked of the WHOLE book, never the period — otherwise picking "This
    /// month" in a quiet month would turn the front door into a first-run
    /// screen for a shop that has been trading for a year.
    @Test func thePeriodPickerCannotEmptyTheFrontDoor() throws {
        let lastYear = try Self.order(status: "completed", date: "2025-03-04")
        #expect(!Shop.hasNotTraded(orders: [lastYear]),
                "a book with old jobs has traded, whatever the picker says")
    }

    /// The same shape `CustomerTests` builds one with — every field `Order`
    /// requires, so a decode failure here is a real change to the record and
    /// not a thin fixture.
    static func order(status: String, date: String = "2026-09-02") throws -> Order {
        let row: [String: JSONValue] = [
            "id": .string("ORD-1"), "date": .string(date), "status": .string(status),
            "project": .string("Turbine bracket"), "client": .string("KAUST"),
            "price": .number(100), "paidAmount": .number(0),
            "paymentStatus": .string("unpaid"), "printTime": .number(1),
            "priority": .bool(false), "notes": .string(""),
        ]
        return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
    }
}
