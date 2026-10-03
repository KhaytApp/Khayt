import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The figures on the reports screen.
///
/// There was no test here at all, which is how a screen full of zeros gets
/// shipped: `KPI_SCRIPT` puts four shared modules together in one expression,
/// and every way of getting that wrong returns a valid object with nothing in
/// it. The note in `KhaytEngine.kpis` records two occasions when exactly that
/// happened — a toolbar reading 52,691.57 above a tile reading 0.
///
/// So these assert real figures against a book small enough to add up by hand.
@MainActor
struct KpiTests {

    /// Two completed jobs and one still printing, all inside the range.
    static func book(now: Date) -> (orders: [JSONValue], clients: [JSONValue]) {
        let day = { (back: Int) -> String in
            let d = Calendar(identifier: .gregorian).date(byAdding: .day, value: -back, to: now)!
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: d)
        }
        let orders: [JSONValue] = [
            .object([
                "id": .string("A"), "status": .string("completed"), "date": .string(day(3)),
                "price": .number(400), "paidAmount": .number(400),
                "currency": .string("SAR"), "clientId": .string("C1"),
                "parts": .array([.object(["unitCost": .number(90), "qty": .number(1)])]),
            ]),
            .object([
                "id": .string("B"), "status": .string("completed"), "date": .string(day(2)),
                "price": .number(600), "paidAmount": .number(100),
                "currency": .string("SAR"), "clientId": .string("C1"),
                "parts": .array([.object(["unitCost": .number(110), "qty": .number(1)])]),
            ]),
            .object([
                "id": .string("C"), "status": .string("printing"), "date": .string(day(1)),
                "price": .number(999), "paidAmount": .number(0),
                "currency": .string("SAR"), "parts": .array([]),
            ]),
        ]
        let clients: [JSONValue] = [
            .object(["id": .string("C1"), "nameEn": .string("Nadia"), "nameAr": .string("نادية")]),
        ]
        return (orders, clients)
    }

    static let settings: [String: JSONValue] = [
        "currency": .string("SAR"), "contentLanguages": .array([.string("en"), .string("ar")]),
    ]

    @Test("the figures are the arithmetic, not zeros")
    func figures() async throws {
        let now = Date()
        let (orders, clients) = Self.book(now: now)
        // "all" rather than a window: this test is about the arithmetic, and a
        // book dated relative to today would break on the first of a month.
        let out = try await KhaytEngine().kpis(orders: orders, clients: clients,
                                               settings: Self.settings, range: "all",
                                               language: "en")
        #expect(out.orderCount == 3)
        #expect(out.completedCount == 2)
        #expect(out.revenue == 1000, "400 + 600")
        #expect(out.cost == 200, "90 + 110 — the parts, not the price")
        #expect(out.grossProfit == 800)
        #expect(out.grossMargin == 80)
        #expect(out.avgOrderValue == 500, "revenue over the COMPLETED count")
        // Every row, not only the finished ones — the job still on the printer
        // is money the shop is owed too. Revenue and cost are the other way
        // round, and mixing the two up is how a dashboard reads plausibly and
        // wrongly.
        #expect(out.outstanding == 1499, "500 still owed on B, plus all 999 of C")
    }

    /// A cancelled job is not an order and is owed by nobody; a costed part
    /// with no `unitCost` costs what it was costed at; shipping is a cost.
    /// The Mac counted the first, priced the second at zero and dropped the
    /// third — Khayt did none of those, so one book showed two margins.
    @Test("cancelled jobs are not counted, costed parts and shipping are cost")
    func cancelledAndCost() async throws {
        let now = Date()
        var (orders, clients) = Self.book(now: now)
        orders.append(.object([
            "id": .string("X"), "status": .string("cancelled"), "date": .string("2026-01-01"),
            "price": .number(5000), "paidAmount": .number(0), "currency": .string("SAR"),
        ]))
        orders.append(.object([
            "id": .string("D"), "status": .string("completed"), "date": .string("2026-01-02"),
            "price": .number(100), "paidAmount": .number(100), "currency": .string("SAR"),
            "shippingCost": .number(15),
            "parts": .array([.object(["spoolCost": .number(100), "spoolWeight": .number(1000),
                                      "printWeight": .number(250), "qty": .number(2)])]),
        ]))
        let out = try await KhaytEngine().kpis(orders: orders, clients: clients,
                                               settings: Self.settings, range: "all",
                                               language: "en")
        #expect(out.orderCount == 4, "the cancelled job is not an order")
        #expect(out.outstanding == 1499, "nor is it 5000 owed")
        #expect(out.cost == 265, "90 + 110 + 2 × 25 g-cost + 15 shipping")
    }

    /// The failure mode this file exists for: every one of these returns a
    /// perfectly valid `Kpis` full of nothing, and no screen says why.
    @Test("an empty book is zeros, and a book outside the range is too")
    func emptyIsHonest() async throws {
        let engine = try KhaytEngine()
        let none = try await engine.kpis(orders: [], clients: [], settings: Self.settings,
                                         range: "30d", language: "en")
        #expect(none.orderCount == 0)
        #expect(none.revenue == 0)

        // Real jobs, wrong window. Zero here is the right answer, and it has to
        // be distinguishable from the wiring being broken — which is what the
        // test above is for.
        let old: [JSONValue] = [.object([
            "id": .string("OLD"), "status": .string("completed"), "date": .string("2000-01-01"),
            "price": .number(400), "paidAmount": .number(400), "parts": .array([]),
        ])]
        let thisYear = try await engine.kpis(orders: old, clients: [], settings: Self.settings,
                                             range: "year", language: "en")
        #expect(thisYear.orderCount == 0, "a job from 2000 is not in this year")
        #expect(thisYear.revenue == 0)

        // And the same job under "all", so the zero above is the filter and not
        // a book the engine failed to read.
        let ever = try await engine.kpis(orders: old, clients: [], settings: Self.settings,
                                         range: "all", language: "en")
        #expect(ever.revenue == 400)
    }

    /// `clientName` is passed into `kpi-rows` and the resolver has to survive
    /// every shape a job takes: a link, free text, or neither. It used to read
    /// `o.client` and now resolves `clientId` through the content-language
    /// rule, and the way to get THAT wrong is to throw on a job with no client
    /// at all — which would take the whole screen down, not one row.
    @Test("a job with no customer does not take the figures with it")
    func clientResolutionIsTotal() async throws {
        let now = Date()
        var (orders, clients) = Self.book(now: now)
        orders.append(contentsOf: [
            // A link to a client the book no longer has.
            .object(["id": .string("D"), "status": .string("completed"),
                     "price": .number(1), "parts": .array([]), "clientId": .string("GONE")]),
            // Free text where a link would be — the field the old resolver read.
            .object(["id": .string("E"), "status": .string("completed"),
                     "price": .number(2), "parts": .array([]), "client": .string("Walk-in")]),
            // Neither.
            .object(["id": .string("F"), "status": .string("completed"),
                     "price": .number(4), "parts": .array([])]),
        ])
        let out = try await KhaytEngine().kpis(orders: orders, clients: clients,
                                               settings: Self.settings, range: "all",
                                               language: "en")
        #expect(out.revenue == 1007, "every shape of customer still adds up")
        #expect(out.completedCount == 5)
    }
}
