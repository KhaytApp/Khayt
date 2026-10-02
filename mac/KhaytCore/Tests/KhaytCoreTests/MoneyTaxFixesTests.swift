import Foundation
import Testing
@testable import KhaytCore

/// Seven money bugs on the Mac, each asked of the engine the screens ask.
///
/// The arithmetic is pinned in `test/money-tax-fixes.test.js`. What is pinned
/// here is that every Mac screen that had its own idea of the money now asks
/// the shared rule — with the shop's SETTINGS, which is where whether tax is
/// inside a price or added on top is written down.
@Suite struct MoneyTaxFixesTests {

    /// 15% VAT, inside the price — a Saudi shop.
    static let vat15: [String: JSONValue] = [
        "currency": .string("SAR"), "enableVat": .bool(true), "vatRate": .number(15),
    ]

    /// 8.25% sales tax added on top — a Texas shop.
    static let salesTax: [String: JSONValue] = [
        "currency": .string("USD"),
        "tax": .object([
            "name": .string("Sales Tax"), "mode": .string("exclusive"),
            "rates": .array([.object(["id": .string("st"), "label": .string("Sales tax"),
                                      "percent": .number(8.25)])]),
        ]),
    ]

    /// A finished job charged `price` whose one part costs `cost` — priced
    /// from the spool, which is how `calculator-cost` prices a part.
    static func job(_ id: String, price: Double, cost: Double,
                    extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "status": .string("completed"),
            "date": .string("2026-09-01"), "price": .number(price),
            "paidAmount": .number(price), "machineId": .string("M1"),
            "productId": .string("p1"),
            "parts": .array([.object([
                "id": .string("pt" + id), "name": .string("Part"), "material": .string("PLA"),
                "qty": .number(1), "printWeight": .number(100), "printTime": .number(2),
                "spoolWeight": .number(1000), "spoolCost": .number(cost * 10),
                "colour": .string("#fff"),
            ])]),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    // MARK: - 1. VAT is not revenue

    @Test("product profit counts the price net of an inclusive VAT")
    func productProfitIsNetOfVat() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.productProfit(
            orders: [Self.job("a", price: 115, cost: 80)],
            products: [.object(["id": .string("p1"), "name": .string("Bracket")])],
            expenses: [], untagged: "Untagged", settings: Self.vat15, clients: [], language: "en")
        let row = try #require(report.rows.first)
        #expect(row.revenue == 100, "the 15 of VAT was being counted as revenue")
        #expect(row.profit == 20, "and so as profit: 35 where the P&L says 20")
    }

    @Test("machine profit counts the price net of an inclusive VAT")
    func machineProfitIsNetOfVat() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.machineProfit(
            machines: [.object(["id": .string("M1"), "name": .string("U1")])],
            completed: [Self.job("a", price: 115, cost: 80)],
            expenses: [], maintenance: [],
            settings: Self.vat15, clients: [], unassigned: "Unassigned")
        #expect(try #require(report.rows.first).revenue == 100)
    }

    @Test("profit per hour's actual side is net of an inclusive VAT")
    func profitPerHourIsNetOfVat() async throws {
        let report = try await KhaytEngine().profitPerHour(
            products: [.object(["id": .string("p1"), "nameEn": .string("Bracket"),
                                "basePrice": .number(115), "baseCost": .number(80),
                                "parts": .array([.object(["printTime": .number(2),
                                                          "qty": .number(1)])])])],
            orders: [Self.job("a", price: 115, cost: 80)],
            expenses: [], inventory: [], consumables: [],
            settings: Self.vat15, clients: [], language: "en")
        let actual = try #require(report.rows.first?.actual)
        #expect(actual.revenue == 100)
    }

    @Test("break-even's margin is on what the shop keeps")
    func breakEvenIsNetOfVat() async throws {
        let result = try await KhaytEngine().breakEven(
            fixedCosts: [.object(["name": .string("Rent"), "amount": .number(1000)])],
            completed: [Self.job("a", price: 115, cost: 80)],
            since: "2026-01-01", month: "2026-09", settings: Self.vat15, clients: [])
        #expect(result.marginPct.map { abs($0 - 0.2) < 1e-9 } == true,
                "30.4% is the VAT counted as margin; the P&L says 20%")
    }

    @Test("an exclusive shop's profit is the price it typed — the tax was never in it")
    func exclusiveIsUnchanged() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.productProfit(
            orders: [Self.job("a", price: 100, cost: 80)],
            products: [.object(["id": .string("p1"), "name": .string("Bracket")])],
            expenses: [], untagged: "Untagged", settings: Self.salesTax, clients: [], language: "en")
        #expect(try #require(report.rows.first).revenue == 100)
    }

    @Test("the ledger's figures: billed, kept, tax and owed, in the job's own currency")
    func orderFigures() async throws {
        let engine = try KhaytEngine()
        let inclusive = try await engine.orderFigures(
            [Self.job("a", price: 115, cost: 80, extra: ["paidAmount": .number(0)])],
            settings: Self.vat15, clients: [])
        #expect(inclusive["a"] == .init(billed: 115, net: 100, tax: 15, owed: 115))
        let exclusive = try await engine.orderFigures(
            [Self.job("b", price: 100, cost: 80, extra: ["paidAmount": .number(100)])],
            settings: Self.salesTax, clients: [])
        #expect(exclusive["b"] == .init(billed: 108.25, net: 100, tax: 8.25, owed: 8.25))
    }

    // MARK: - 3. owed in the order's own currency

    @Test("a foreign job's own-currency owed is not the shop's figure")
    func owedInOwnCurrency() async throws {
        let engine = try KhaytEngine()
        var settings = Self.vat15
        settings["exchangeRates"] = .object(["USD": .number(3.75)])
        let row = Self.job("u", price: 100, cost: 10,
                           extra: ["currency": .string("USD"), "paidAmount": .number(0)])
        let own = try await engine.orderFigures([row], settings: settings, clients: [])
        let base = try await engine.owedByOrder([row], settings: settings, clients: [],
                                                currencies: ["SAR": .object([:]), "USD": .object([:])])
        #expect(own["u"]?.owed == 100, "100 USD is owed in USD")
        #expect(base["u"] == 375, "and 375 in the shop's riyals — a different figure")
    }

    // MARK: - 7. tax added on top

    @Test("an exclusive shop records a payment of price + tax in full")
    func paymentIncludesTax() async throws {
        let engine = try KhaytEngine()
        let order = Self.job("t", price: 100, cost: 10, extra: ["paidAmount": .number(0)])
        let done = try await engine.recordPayment(order: order, amount: 108.25, method: "card",
                                                  paidAt: "2026-10-02", today: "2026-10-02",
                                                  settings: Self.salesTax)
        guard case .object(let o) = done.order else { Issue.record("no order"); return }
        #expect(o["paidAmount"] == .number(108.25), "it was clamped to the pre-tax 100")
        #expect(o["paymentStatus"] == .string("paid"))
    }

    @Test("what an exclusive shop is owed includes the tax")
    func owedIncludesTax() async throws {
        let engine = try KhaytEngine()
        let order = Self.job("t", price: 100, cost: 10, extra: ["paidAmount": .number(100)])
        #expect(try await engine.owedRaw(order: order, settings: Self.salesTax) == 8.25)
        #expect(try await engine.owedRaw(order: order, settings: Self.vat15) == 0)
    }

    // MARK: - 6. a gift card and a plan

    @Test("a plan covering price − gift card settles the order once collected")
    func giftCardPlanSettles() async throws {
        let engine = try KhaytEngine()
        let order = Self.job("g", price: 500, cost: 10, extra: [
            "paidAmount": .number(0), "giftCardDiscount": .number(100),
            "instalmentBase": .number(0),
        ])
        let rows: [JSONValue] = [
            .object(["amount": .number(200), "paid": .bool(true)]),
            .object(["amount": .number(200), "paid": .bool(true)]),
        ]
        let out = try await engine.collectionTotals(order: order, instalments: rows,
                                                    settings: Self.vat15)
        #expect(out.paidAmount == 400)
        #expect(out.paymentStatus == "paid", "it stayed partial, chasing the card's 100")
    }

    @Test("the payment sheet's owed counts the gift card and the credit note")
    func cashDueCountsTenders() async throws {
        let engine = try KhaytEngine()
        let order = Self.job("c", price: 500, cost: 10, extra: [
            "giftCardDiscount": .number(100),
            "creditNotes": .array([.object(["amount": .number(50)])]),
        ])
        let due = try await engine.cashDue(order: order, settings: Self.vat15)
        #expect(due.cash == 350)
        #expect(try await engine.cashDue(order: Self.job("d", price: 100, cost: 1),
                                         settings: Self.salesTax).gross == 108.25)
    }

    // MARK: - 2. the invoice adds up

    @Test("the invoice Subtotal is the items, so the lines add up to the total")
    func invoiceSummaryAddsUp() async throws {
        let engine = try KhaytEngine()
        let s = try await engine.invoiceSummary(
            order: Self.job("i", price: 280, cost: 1, extra: [
                "rushFeeAmount": .number(25), "shippingCost": .number(30),
            ]), settings: Self.vat15)
        #expect(s.itemsSubtotal == 225)
        #expect(s.itemsSubtotal + s.rush + s.shipping - s.discount == s.total)
    }

    // MARK: - 5. the ZATCA QR has a time

    /// Tag 3 out of a base64 TLV — one-byte lengths, which every field here has.
    static func tag3(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        let bytes = [UInt8](data)
        var i = 0
        while i + 1 < bytes.count {
            let tag = bytes[i], len = Int(bytes[i + 1])
            let value = bytes[(i + 2)..<min(bytes.count, i + 2 + len)]
            if tag == 3 { return String(decoding: value, as: UTF8.self) }
            i += 2 + len
        }
        return nil
    }

    @Test("a date-only stamp reaches the QR as a full ISO 8601 date-time")
    func zatcaTimestampHasATime() async throws {
        let payload = try await KhaytEngine().zatcaPayload(
            sellerName: "Shop", vatNumber: "300000000000003", timestamp: "2026-07-02",
            total: "115.00", vatAmount: "15.00")
        let stamp = try #require(Self.tag3(payload))
        #expect(stamp.range(of: #"^2026-07-0[12]T\d{2}:\d{2}:\d{2}Z$"#,
                            options: .regularExpression) != nil,
                "tag 3 read \(stamp) — a day, with no time")
    }
}
