import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac's half of the money review (see test/money-review.test.js).
///
/// * The accountant's file carried a USD customer's job as the shop's own
///   currency at face value, with the base columns empty: the export handed
///   `AccountingRows` neither `currencyOf` nor `toBase`, where the other app
///   hands it `orderCurrency` and `convertToBase`.
/// * A quote, a cancelled job, a voided invoice and one credited in full were
///   counted as owed in the title bar, the widget and the customers table.
@MainActor
struct MoneyReviewTests {

    static let settings: [String: JSONValue] = [
        "currency": .string("SAR"), "taxMode": .string("none"),
        "exchangeRates": .object(["USD": .number(3.75)]),
    ]

    static let clients: [JSONValue] = [
        .object(["id": .string("C-USD"), "nameEn": .string("Dollar Co"), "currency": .string("USD")]),
    ]

    static func order(_ id: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "date": .string("2026-08-01"), "price": .number(100),
            "status": .string("completed"),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    /// The data lines of a generic CSV, keyed by invoice number.
    static func lines(_ csv: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        let rows = csv.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: \.isNewline).map(String.init)
        guard let header = rows.first?.split(separator: ",").map(String.init),
              let no = header.firstIndex(of: "InvoiceNo") else { return out }
        for row in rows.dropFirst() {
            let cells = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard no < cells.count else { continue }
            out[cells[no]] = cells
        }
        return out
    }

    @Test("a USD customer's job exports as USD, with the shop's base columns filled in")
    func exportCarriesTheCurrency() async throws {
        let engine = try KhaytEngine()
        let csv = try await engine.invoiceCsv(
            [Self.order("USD-1", ["clientId": .string("C-USD")]),
             Self.order("SAR-1")],
            settings: Self.settings, clients: Self.clients, format: "generic")
        let header = csv.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: \.isNewline).first.map { $0.split(separator: ",").map(String.init) } ?? []
        let rows = Self.lines(csv)
        let cur = try #require(header.firstIndex(of: "Currency"))
        let base = try #require(header.firstIndex(of: "BaseCurrency"))
        let baseTotal = try #require(header.firstIndex(of: "BaseTotal"))

        let usd = try #require(rows["USD-1"])
        #expect(usd[cur] == "USD")
        #expect(usd[base] == "SAR")
        #expect(usd[baseTotal] == "375.00")

        let sar = try #require(rows["SAR-1"])
        #expect(sar[cur] == "SAR")
        #expect(sar[baseTotal] == "100.00")
    }

    @Test("the export leaves out what is not an invoice, and nets off a credit note")
    func exportScope() async throws {
        let engine = try KhaytEngine()
        let csv = try await engine.invoiceCsv(
            [Self.order("P", ["status": .string("split"), "splitInto": .array([.string("P-1")])]),
             Self.order("P-1"),
             Self.order("V", ["voidedAt": .string("2026-08-02")]),
             Self.order("X", ["status": .string("cancelled")]),
             Self.order("G", ["nonBusiness": .bool(true)]),
             Self.order("N", ["creditNotes": .array([.object(["amount": .number(40)])])])],
            settings: Self.settings, clients: [], format: "generic")
        let rows = Self.lines(csv)
        #expect(Set(rows.keys) == ["P-1", "N"])
        #expect(rows["N"]?.contains("60.00") == true)
    }

    static func decoded(_ value: JSONValue) throws -> Order {
        try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(value))
    }

    @Test("a quote, a cancelled job, a voided and a fully credited order owe nothing")
    func nothingOwed() throws {
        for extra: [String: JSONValue] in [
            ["status": .string("quote")], ["status": .string("cancelled")],
            ["voidedAt": .string("2026-08-02")], ["creditedAt": .string("2026-08-02")],
        ] {
            var job = try Self.decoded(Self.order("O", extra))
            #expect(job.owed == 0, "dead-engine fallback, \(extra)")
            #expect(job.owedInOwnCurrency == 0)
            #expect(job.isSettled)
            // Even if a stale answer was resolved onto the row.
            job.owedResolved = 100
            #expect(job.owed == 0, "resolved, \(extra)")
        }
        let open = try Self.decoded(Self.order("O"))
        #expect(open.owed == 100)
        #expect(open.owesAtAll)
    }
}
