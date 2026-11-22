import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac's half of test/money-display.test.js — three faults from a job saved
/// in a client's currency (#2148):
///
/// * the ZATCA QR stated a EUR job's total and VAT as riyals;
/// * the Owed meter was `paidAmount / due` and ignored credit notes and gift
///   cards, so it disagreed with the figure printed above it;
/// * the owed figures in the jobs table, on the board and in a customer's job
///   list carried no currency, so SAR and EUR jobs read alike.
@MainActor
struct MoneyDisplayTests {

    static let settings: [String: JSONValue] = [
        "currency": .string("SAR"), "taxMode": .string("none"),
        "exchangeRates": .object(["EUR": .number(9)]),
    ]

    static func decoded(_ value: JSONValue) throws -> Order {
        try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(value))
    }

    // MARK: - The QR states riyals

    @Test("a EUR job's QR amounts are converted at the rate stored on it, not today's")
    func qrConvertsAtTheStoredRate() async throws {
        let engine = try KhaytEngine()
        let eur: JSONValue = .object(["id": .string("E"), "currency": .string("EUR"), "fxRate": .number(4)])
        let r = try await engine.zatcaAmounts(order: eur, settings: Self.settings,
                                              total: 28.75, vatAmount: 3.75)
        #expect(r == .amounts(total: 115, vatAmount: 15))
        let sar: JSONValue = .object(["id": .string("S")])
        #expect(try await engine.zatcaAmounts(order: sar, settings: Self.settings,
                                              total: 115, vatAmount: 15)
                == .amounts(total: 115, vatAmount: 15))
    }

    @Test("a foreign job with no stored rate gets no QR, and the reason names it")
    func qrRefusedWithoutARate() async throws {
        let engine = try KhaytEngine()
        let eur: JSONValue = .object(["id": .string("E"), "currency": .string("EUR")])
        let r = try await engine.zatcaAmounts(order: eur, settings: Self.settings,
                                              total: 28.75, vatAmount: 3.75)
        guard case .refused(let why) = r else { Issue.record("expected a refusal, got \(r)"); return }
        #expect(why.params["missing"] == .array([.string("inv.qr_foreign_currency")]))
        // And it reads as words, not as the key.
        let words = Words()
        await words.load("en", engine: engine)
        #expect(words.zatcaRefusal(why).contains("SAR"))
        let ar = Words()
        await ar.load("ar", engine: engine)
        #expect(ar.zatcaRefusal(why) != "inv.qr_foreign_currency")
    }

    // MARK: - The meter agrees with the figure above it

    @Test("1,000 with 500 paid and a 300 credit note: 200 owed over an 80% meter")
    func meterCountsCreditNotes() async throws {
        let engine = try KhaytEngine()
        let row: JSONValue = .object([
            "id": .string("C"), "date": .string("2026-08-01"), "price": .number(1000),
            "status": .string("completed"), "paidAmount": .number(500),
            "creditNotes": .array([.object(["amount": .number(300)])]),
        ])
        var job = try Self.decoded(row)
        job.figures = try await engine.orderFigures([row], settings: Self.settings, clients: [])["C"]
        #expect(abs(job.owedInOwnCurrency - 200) < 0.005)
        #expect(abs(job.settledFraction - 0.8) < 0.0001)
    }

    @Test("a gift card settles the meter as the owed figure does")
    func meterCountsGiftCards() async throws {
        let engine = try KhaytEngine()
        let row: JSONValue = .object([
            "id": .string("G"), "date": .string("2026-08-01"), "price": .number(400),
            "status": .string("completed"), "paidAmount": .number(100),
            "giftCardDiscount": .number(100),
        ])
        var job = try Self.decoded(row)
        job.figures = try await engine.orderFigures([row], settings: Self.settings, clients: [])["G"]
        #expect(abs(job.owedInOwnCurrency - 200) < 0.005)
        #expect(abs(job.settledFraction - 0.5) < 0.0001)
    }

    @Test("no figures yet: the meter falls back with the owed figure, never past full")
    func meterFallback() throws {
        let job = try Self.decoded(.object([
            "id": .string("F"), "price": .number(100), "status": .string("completed"),
            "paidAmount": .number(150),
        ]))
        #expect(job.settledFraction == 1)
        let unpriced = try Self.decoded(.object(["id": .string("U"), "status": .string("completed")]))
        #expect(unpriced.settledFraction == 0)
    }

    // MARK: - A job's figure carries its own currency

    @Test("a job in the shop's currency is a bare figure; one in another carries its mark")
    func figureMarksAForeignJob() {
        #expect(Money.figure(200, currency: "", shop: "SAR") == Money.figure(200))
        #expect(Money.figure(200, currency: "SAR", shop: "SAR") == Money.figure(200))
        #expect(Money.figure(200, currency: "sar", shop: "SAR") == Money.figure(200))
        #expect(Money.figure(200, currency: "EUR", shop: "SAR") == Money.text(200, "EUR"))
        #expect(Money.figure(200, currency: "EUR", shop: "SAR").contains("EUR"))
    }
}
