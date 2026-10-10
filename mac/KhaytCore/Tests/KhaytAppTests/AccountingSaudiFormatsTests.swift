import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Wafeq and Daftra on the accountant's menu.
///
/// The columns are `lib/accounting-export.js`'s, pinned by the node tests. What
/// this suite pins is the wiring: the menu offers both, and the Mac hands the
/// rule the same sales account, tax name and currency the other app does — read
/// from the same `accountingSync` keys — so one book exports one file.
@MainActor
struct AccountingSaudiFormatsTests {

    static let settings: [String: JSONValue] = [
        "currency": .string("SAR"), "enableVat": .bool(true), "vatRate": .number(15),
        "accountingSync": .object([
            "salesAccount": .string("Sales"), "taxCode": .string("VAT on Sales"),
        ]),
    ]

    static let order = JSONValue.object([
        "id": .string("ORD-7"), "client": .string("Acme"),
        "date": .string("2026-08-01"), "price": .number(115),
        "status": .string("completed"), "paymentStatus": .string("paid"),
    ])

    static let expense = JSONValue.object([
        "id": .string("EXP-1"), "date": .string("2026-08-02"),
        "category": .string("filament"), "amount": .number(57.5), "note": .string("PLA"),
    ])

    static func lines(_ csv: String) -> [String] {
        csv.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: "\r\n")
    }

    @Test("the menu offers Wafeq and Daftra, and not Qoyod")
    func menuOffersThem() {
        let keys = Shop.accountingFormats.map(\.0)
        #expect(keys.contains("wafeq"))
        #expect(keys.contains("daftra"))
        #expect(!keys.contains("qoyod"))
    }

    @Test("Wafeq: net price flagged exc. tax, with the shop's account and tax name")
    func wafeqInvoice() async throws {
        let engine = try KhaytEngine()
        let csv = try await engine.invoiceCsv(
            [Self.order], settings: Self.settings, clients: [], format: "wafeq")
        let l = Self.lines(csv)
        #expect(l[0].hasPrefix("Invoice number,Customer name,Currency,Date,Due date"))
        #expect(l[1] == "ORD-7,Acme,SAR,2026-08-01,2026-08-01,ORD-7,1,100.00,Sales,VAT on Sales,exc. tax")
    }

    @Test("Daftra: an income voucher, DD/MM/YYYY, net amount and the tax name")
    func daftraInvoice() async throws {
        let engine = try KhaytEngine()
        let csv = try await engine.invoiceCsv(
            [Self.order], settings: Self.settings, clients: [], format: "daftra")
        let l = Self.lines(csv)
        #expect(l[0] == "Date,Amount,Currency,Vendor,Description,Taxes,Sub-Account")
        #expect(l[1] == "01/08/2026,100.00,SAR,Acme,ORD-7,VAT on Sales,Sales")
    }

    @Test("expenses carry the shop's currency, which the record itself does not")
    func expensesTakeTheShopCurrency() async throws {
        let engine = try KhaytEngine()
        let wafeq = Self.lines(try await engine.expenseCsv(
            [Self.expense], format: "wafeq", settings: Self.settings))
        #expect(wafeq[1] == "2026-08-02,Cost of Goods Sold,,SAR,57.50,inc. tax,PLA")
        let daftra = Self.lines(try await engine.expenseCsv(
            [Self.expense], format: "daftra", settings: Self.settings))
        #expect(daftra[1] == "02/08/2026,57.50,SAR,Cost of Goods Sold,PLA")
    }

    @Test("both notes exist in English and Arabic")
    func notesAreWords() {
        for key in ["mac.export_wafeq_note", "mac.export_daftra_note"] {
            #expect(Words.own[key]?["en"]?.isEmpty == false)
            #expect(Words.own[key]?["ar"]?.isEmpty == false)
        }
    }
}
