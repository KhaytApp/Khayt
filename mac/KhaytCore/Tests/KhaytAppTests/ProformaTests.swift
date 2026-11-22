import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A proforma: a job's paper as a request for payment before the work is
/// invoiced, as the desktop's "Generate Proforma" gives one. It is not a tax
/// invoice — no ZATCA QR, the job's id for a number — and drawing one must
/// never number the job, because VAT is due on an issued invoice.
@MainActor
struct ProformaTests {

    @Test("the paper is titled and watermarked as a proforma, with no QR and the job's id")
    func thePaper() async throws {
        var paper = InvoiceTests.paper(order: ["invoiceNumber": .string("INV-2026-0042"),
                                               "invoiceNum": .string("INV-2026-0042")])
        let invoice = try await InvoiceTests.build(paper)
        #expect(invoice.html.contains("alt=\"ZATCA\""), "the invoice of a registered shop has its QR")
        paper.proforma = true
        let proforma = try await InvoiceTests.build(paper)
        #expect(!proforma.html.contains("alt=\"ZATCA\""), "a proforma is not a tax invoice")
        #expect(!proforma.html.contains("qr-box"))
        #expect(proforma.html.contains("proforma-watermark"))
        #expect(proforma.html.contains("PROFORMA"))
        #expect(!proforma.html.contains("INV-2026-0042"), "it names the job, never an invoice number")
    }

    @Test("offered on accepted, priced, unfinished work only")
    func whenOffered() throws {
        func job(_ status: String, price: Double = 100) throws -> Order {
            try JSONDecoder().decode(Order.self, from: JSONEncoder().encode([
                "id": JSONValue.string("J"), "date": .string("2026-10-01"), "status": .string(status),
                "project": .string("P"), "client": .string("Acme"), "price": .number(price),
                "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
                "printTime": .number(1), "priority": .bool(false), "notes": .string(""),
            ] as [String: JSONValue]))
        }
        for s in ["pending", "printing", "on_hold"] { #expect(Shop.offersProforma(try job(s)), "\(s)") }
        for s in ["quote", "completed", "cancelled"] { #expect(!Shop.offersProforma(try job(s)), "\(s)") }
        #expect(!Shop.offersProforma(try job("pending", price: 0)), "nothing to ask for")
    }

    @Test("drawing a proforma numbers nothing, even on a job still owed an invoice number")
    func numbersNothing() async throws {
        let shop = await MacConventionsTests.sample()
        let before = shop.orderRows
        #expect(shop.orders.contains(where: Shop.offersProforma), "the sample has work a proforma is for")
        for job in shop.orders where Shop.offersProforma(job) {
            switch await shop.invoiceDocument(for: job.id, proforma: true) {
            case .paper(let doc, let number):
                #expect(number == job.id)
                #expect(doc.html.contains("proforma-watermark"))
            case .refused(let why):
                Issue.record("a proforma was refused: \(why)")
            }
        }
        #expect(shop.orderRows == before, "no job was changed by drawing its proforma")
    }
}
