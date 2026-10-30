import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Payment terms per customer, as the Mac reads, writes and shows them.
///
/// The rule is `lib/payment-terms.js` (held to `KhaytCore.PaymentTerms` by
/// `PaymentTermsParityTests`). These are the Mac's ends of it: the customer
/// record carries the field through an edit, and the Receivables screen ages a
/// net-30 customer from the day the invoice falls due, not from the job.
@MainActor
struct PaymentTermsTests {

    @Test("a stored term is read through the shared rule, and written back as a number")
    func clientReadsAndWrites() throws {
        let typed = try #require(Client.decoding(["id": .string("C1"), "nameEn": .string("Ministry"),
                                                  "paymentTermsDays": .string("30")]))
        #expect(typed.paymentTermsDays == 30, "a hand-typed \"30\" is thirty days")
        #expect(typed.record["paymentTermsDays"] == .number(30))
        let bad = try #require(Client.decoding(["id": .string("C2"), "paymentTermsDays": .number(-4)]))
        #expect(bad.paymentTermsDays == 0, "negative is due on receipt")
        let none = try #require(Client.decoding(["id": .string("C3")]))
        #expect(none.paymentTermsDays == 0)
        #expect(none.onTerms(45).paymentTermsDays == 45)
        #expect(none.onTerms(10_000).paymentTermsDays == PaymentTerms.maxDays)
        // The other edits keep the terms: a record rebuilt without them would
        // put every customer back on due-on-receipt the next time it was saved.
        let net = none.onTerms(60)
        #expect(net.marketed(false).paymentTermsDays == 60)
        #expect(net.with(\.phone, "0500").paymentTermsDays == 60)
        #expect(net.replacing(priceList: []).paymentTermsDays == 60)
        #expect(net.replacing(recurring: nil).paymentTermsDays == 60)
        #expect(net.optedIntoWhatsApp(true, how: "asked", at: Date()).paymentTermsDays == 60)
    }

    @Test("an untouched save writes no terms onto a customer that had none, and keeps a typed one as typed")
    func untouchedSave() throws {
        let was: [String: JSONValue] = ["id": .string("C1"), "nameEn": .string("Acme")]
        let client = try #require(Client.decoding(was))
        let saved = Shop.customerRecord(saving: client, over: was, opened: client)
        #expect(saved["paymentTermsDays"] == nil)

        let typed: [String: JSONValue] = ["id": .string("C1"), "nameEn": .string("Acme"),
                                          "paymentTermsDays": .string("30")]
        let t = try #require(Client.decoding(typed))
        #expect(Shop.customerRecord(saving: t, over: typed, opened: t)["paymentTermsDays"] == .string("30"))
        // And taking the terms off sticks: 0 is written, not omitted.
        let off = Shop.customerRecord(saving: t.onTerms(0), over: typed, opened: t)
        #expect(off["paymentTermsDays"] == .number(0))
    }

    @Test("Receivables: a net-30 customer is owed but not overdue on day one")
    func receivablesHonourTerms() async throws {
        let engine = try KhaytEngine()
        let now = Calendar.book.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        let orders: [JSONValue] = [
            .object(["id": .string("GOV"), "date": .string("2026-10-20"), "price": .number(100),
                     "paidAmount": .number(0), "status": .string("completed"), "clientId": .string("M")]),
            .object(["id": .string("WALK"), "date": .string("2026-10-20"), "price": .number(100),
                     "paidAmount": .number(0), "status": .string("completed")]),
        ]
        let clients: [JSONValue] = [
            .object(["id": .string("M"), "nameEn": .string("Ministry"), "paymentTermsDays": .number(30)]),
        ]
        let out = try await engine.receivables(orders: orders, settings: ["currency": .string("SAR")],
                                               clients: clients, currencies: [:], language: "en", now: now)
        let gov = try #require(out.rows.first { $0.id == "GOV" })
        #expect(gov.due == "2026-11-19")
        #expect(gov.days == 0)
        #expect(gov.overdue == false)
        #expect(gov.notYetDue)
        let walk = try #require(out.rows.first { $0.id == "WALK" })
        #expect(walk.days == 10, "no terms: aged exactly as it always was")
        #expect(walk.overdue == true)
        #expect(!walk.notYetDue)
        #expect(out.total == 200, "not yet due is still owed")
    }

    @Test("the invoice prints the terms and the due date for a customer on terms")
    func invoiceSaysDue() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object([
            "id": .string("INV-1"), "date": .string("2026-09-04"), "price": .number(100),
            "paidAmount": .number(0), "status": .string("completed"), "clientId": .string("M"),
            "project": .string("Brackets"),
        ])
        let clients: [JSONValue] = [
            .object(["id": .string("M"), "nameEn": .string("Ministry"), "paymentTermsDays": .number(30)]),
        ]
        func html(_ clients: [JSONValue]) async throws -> String {
            try await engine.invoiceHtml(
                order: order, settings: ["currency": .string("SAR")], clients: clients,
                currencies: ["SAR": .object(["code": .string("SAR"), "symbol": .string("﷼"),
                                             "decimals": .number(2)])],
                language: "en",
                money: ["total": .string("100.00"), "subtotal": .string("100.00"),
                        "subtotalShown": .string("100.00"), "vatAmount": .string("0.00"),
                        "vatRate": .number(0), "shipping": .number(0), "payQrSvg": .string("")],
                sellerFields: [:]).html
        }
        let net30 = try await html(clients)
        #expect(net30.contains("Payment terms"))
        #expect(net30.contains("Net 30"))
        let onReceipt = try await html([.object(["id": .string("M"), "nameEn": .string("Ministry")])])
        #expect(!onReceipt.contains("Payment terms"), "due on receipt prints nothing new")
    }
}
