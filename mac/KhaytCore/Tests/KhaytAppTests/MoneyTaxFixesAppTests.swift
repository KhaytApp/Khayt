import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac screens that printed money the shared rules disagree with.
///
/// `KhaytCoreTests/MoneyTaxFixesTests` pins what the engine answers. These pin
/// that the invoice, the ledger and the job rows USE those answers.
@MainActor
struct MoneyTaxFixesAppTests {

    // MARK: - 2. the invoice summary adds up

    @Test("Subtotal is the items: 225 + rush 25 + shipping 30 = 280")
    func invoiceSubtotalIsTheItems() async throws {
        let paper = InvoiceTests.paper(order: [
            "price": .number(280), "paidAmount": .number(0),
            "rushFeeAmount": .number(25), "shippingCost": .number(30),
        ])
        var p = paper
        p.price = 280
        p.subtotal = 243.48
        p.taxTotal = 36.52
        let doc = try await InvoiceTests.build(p)
        #expect(doc.html.contains("<span class=\"v\">225.00 "),
                "the Subtotal row printed the whole 280 above Rush 25 and Shipping 30")
        #expect(!doc.html.contains("<span class=\"v\">280.00 "),
                "280 is the total, not a line above it")
    }

    // MARK: - 4. the customer's currency

    @Test("a job with no currency of its own is invoiced in the customer's")
    func invoiceUsesTheCustomersCurrency() async throws {
        var paper = InvoiceTests.paper()
        paper.clients = [.object(["id": .string("C1"), "nameEn": .string("Acme Metalworks"),
                                  "currency": .string("USD")])]
        paper.currencies = ["SAR": .object(["symbol": .string("SAR")]),
                            "USD": .object(["symbol": .string("US$")])]
        let doc = try await InvoiceTests.build(paper)
        #expect(doc.html.contains("US$"),
                "Electron goes order → customer → shop; the Mac skipped the customer")
    }

    // MARK: - 1. the ledger's margin

    static func order(price: Double, cost: Double) throws -> Order {
        let row: JSONValue = .object([
            "id": .string("L1"), "date": .string("2026-09-01"), "project": .string("Lid"),
            "status": .string("completed"), "price": .number(price),
            "paidAmount": .number(price), "costBasis": .number(cost),
            "paymentStatus": .string("paid"), "printTime": .number(1),
            "priority": .bool(false), "notes": .string(""), "client": .string("A shop"),
        ])
        return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
    }

    @Test("the ledger's margin is on the price net of VAT")
    func ledgerMarginIsNetOfVat() throws {
        var job = try Self.order(price: 115, cost: 80)
        job.figures = .init(billed: 115, net: 100, tax: 15, owed: 0)
        let money = Shop.ledgerMoney(job)
        #expect(money.margin.map { abs($0 - 0.2) < 1e-9 } == true,
                "30.4% is the VAT read as margin; the P&L says 20%")
        #expect(money.marginMoney == 20)
        #expect(money.net == 100)
        #expect(money.vat == 15)
        #expect(money.charged == 115)
    }

    @Test("an exclusive shop's ledger charges price + tax and keeps the price")
    func ledgerExclusive() throws {
        var job = try Self.order(price: 100, cost: 80)
        job.figures = .init(billed: 108.25, net: 100, tax: 8.25, owed: 8.25)
        let money = Shop.ledgerMoney(job)
        #expect(money.charged == 108.25)
        #expect(money.marginMoney == 20)
    }

    @Test("an unregistered shop has no tax line on the ledger")
    func ledgerUnregistered() throws {
        var job = try Self.order(price: 115, cost: 80)
        job.figures = .init(billed: 115, net: 115, tax: 0, owed: 0)
        let money = Shop.ledgerMoney(job)
        #expect(money.vat == nil)
        #expect(money.net == nil)
        #expect(money.marginMoney == 35)
    }

    // MARK: - 3. owed in the order's own currency

    @Test("the row's owed is in the job's own currency, not the shop's")
    func owedInOwnCurrency() throws {
        var job = try Self.order(price: 100, cost: 10)
        job.owedResolved = 375          // the shop's riyals
        job.figures = .init(billed: 100, net: 100, tax: 0, owed: 100)
        #expect(job.owedInOwnCurrency == 100, "printed beside USD, this read 375.00 USD")
        #expect(job.owed == 375, "and the shop-currency figure stays for totals")
    }

    @Test("the rows that print a job's own currency print its own owed")
    func theRowsAreWired() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        for file in ["OrderInspector.swift", "OrdersTable.swift", "CustomersTable.swift",
                     "Kanban.swift"] {
            let src = try String(contentsOf: dir.appending(path: file), encoding: .utf8)
            #expect(src.contains("owedInOwnCurrency"), "\(file) prints the shop's owed")
            #expect(!src.contains("Money.figure(job.owed)"), "\(file)")
            #expect(!src.contains("Money.text(job.owed,"), "\(file)")
        }
    }
}
