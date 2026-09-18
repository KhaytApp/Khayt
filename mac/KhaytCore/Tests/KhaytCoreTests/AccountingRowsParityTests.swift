import Foundation
import Testing
@testable import KhaytCore

/// The rows an accountant's CSV is laid out from, against the JavaScript.
///
/// Two apps disagreeing about a VAT figure is a disagreement an auditor finds,
/// so the cases here are the four things the exporter cannot decide for itself:
/// which orders count, the rate, the mode, and whose name goes on the row.
@MainActor
struct AccountingRowsParityTests {

    private func js() throws -> JSModule { try JSModule(["accounting-rows"]) }

    private func check(_ orders: [JSONValue], settings: [String: JSONValue],
                       clients: [JSONValue], tax: AccountingRows.Tax,
                       _ what: String, _ js: JSModule) throws {
        let mine = AccountingRows.invoiceRows(orders: orders, settings: settings,
                                              clients: clients, tax: tax)
        let theirs = try js.value("""
            KhaytAccountingRows.ordersToInvoiceRows(ARG0, {
              settings: ARG1, clients: ARG2, tax: {rate: ARG3, mode: ARG4},
            })
            """, [.array(orders), .object(settings), .array(clients),
                  .number(tax.rate), .string(tax.mode)])
        #expect(.array(mine) == theirs, Comment(rawValue: """
            \(what)
              swift \(mine)
              js    \(theirs)
            """))
    }

    private let vat = AccountingRows.Tax(rate: 15, mode: "inclusive")

    private var book: [JSONValue] {
        [.object(["id": .string("A-1"), "date": .string("2026-09-01"),
                  "status": .string("completed"), "price": .number(1150),
                  "clientId": .string("C-1")]),
         .object(["id": .string("A-2"), "date": .string("2026-09-02"),
                  "status": .string("quote"), "price": .number(500),
                  "clientId": .string("C-1")]),
         .object(["id": .string("A-3"), "status": .string("completed"), "price": .number(0)]),
         .object(["id": .string("A-4"), "status": .string("printing"), "price": .number(75),
                  "clientName": .string("Walk-in")]),
         .object(["id": .string("A-5"), "status": .string("delivered"), "price": .string("240"),
                  "client": .string("Old field")]),
         .object(["id": .string("A-6"), "status": .string("completed"),
                  "price": .number(-10)]),
         .object(["id": .string("A-7"), "status": .string("completed")]),
         .null, .string("x"), .number(1), .bool(false), .array([])]
    }

    private let clients: [JSONValue] = [
        .object(["id": .string("C-1"), "name": .string("Salem")]),
        .object(["id": .string("C-2"), "name": .string("")]),
        .null, .string("x"),
    ]

    @Test("a quote is not an invoice, and an order with no price is not one either")
    func scopeMatches() throws {
        let js = try js()
        try check(book, settings: ["currency": .string("SAR")], clients: clients,
                  tax: vat, "a real book", js)
        try check([], settings: [:], clients: [], tax: vat, "an empty book", js)
    }

    @Test("the customer's name, and the two older fields it falls back to")
    func namesMatch() throws {
        let js = try js()
        let orders: [JSONValue] = [
            .object(["id": .string("a"), "status": .string("completed"), "price": .number(10),
                     "clientId": .string("C-1")]),
            // A client whose name is empty falls through to the order's own.
            .object(["id": .string("b"), "status": .string("completed"), "price": .number(10),
                     "clientId": .string("C-2"), "clientName": .string("On the order")]),
            // A clientId nobody has.
            .object(["id": .string("c"), "status": .string("completed"), "price": .number(10),
                     "clientId": .string("C-9"), "client": .string("Older still")]),
            // Strict equality: a numeric id does not match a text one.
            .object(["id": .string("d"), "status": .string("completed"), "price": .number(10),
                     "clientId": .number(1)]),
            .object(["id": .string("e"), "status": .string("completed"), "price": .number(10),
                     "clientId": .string(""), "clientName": .string("No id at all")]),
            .object(["id": .string("f"), "status": .string("completed"), "price": .number(10)]),
        ]
        try check(orders, settings: [:], clients: clients + [.object(["id": .number(1),
                                                                      "name": .string("Numeric")])],
                  tax: vat, "names", js)
    }

    @Test("the shop's own currency stands in for an order that names none")
    func currencyMatches() throws {
        let js = try js()
        let orders: [JSONValue] = [
            .object(["id": .string("a"), "status": .string("completed"), "price": .number(10)]),
            .object(["id": .string("b"), "status": .string("completed"), "price": .number(10),
                     "currency": .string("USD")]),
            .object(["id": .string("c"), "status": .string("completed"), "price": .number(10),
                     "currency": .string("")]),
            .object(["id": .string("d"), "status": .string("completed"), "price": .number(10),
                     "currency": .null]),
        ]
        for settings: [String: JSONValue] in [["currency": .string("AED")], [:],
                                              ["currency": .string("")], ["currency": .null]] {
            try check(orders, settings: settings, clients: [], tax: vat,
                      "settings \(settings)", js)
        }
    }

    @Test("the rate and the mode are carried onto every row")
    func taxCarriesThrough() throws {
        let js = try js()
        for tax in [AccountingRows.Tax(rate: 15, mode: "inclusive"),
                    .init(rate: 0, mode: "exclusive"),
                    .init(rate: 5.5, mode: ""),
                    .init(rate: 15, mode: "none")] {
            try check(book, settings: [:], clients: clients, tax: tax,
                      "\(tax.rate) \(tax.mode)", js)
        }
    }

    @Test("the rate is the profile's rates added up")
    func taxOfMatches() throws {
        let js = try js()
        let profiles: [JSONValue] = [
            .object(["mode": .string("inclusive"),
                     "rates": .array([.object(["percent": .number(15)])])]),
            .object(["mode": .string("exclusive"),
                     "rates": .array([.object(["percent": .number(10)]),
                                      .object(["percent": .string("5")]),
                                      .object(["percent": .null]),
                                      .object([:])])]),
            .object(["mode": .string("inclusive"), "rates": .array([])]),
            .object(["mode": .string("inclusive")]),
            .object([:]),
        ]
        for profile in profiles {
            let mine = AccountingRows.tax(profile: profile)
            let theirs = try js.value("""
                KhaytAccountingRows.taxOf({}, {
                  profileFromSettings: function () { return ARG0; },
                })
                """, [profile])
            guard case .object(let t) = theirs else { Issue.record("\(profile)"); continue }
            #expect(.number(mine.rate) == t["rate"], Comment(rawValue: "rate of \(profile)"))
            #expect(.string(mine.mode) == (t["mode"] ?? .string("")),
                    Comment(rawValue: "mode of \(profile)"))
        }
    }

    @Test("a profile the original cannot read is a default, not a crash")
    func taxOfSurvivesRubbish() throws {
        // Two shapes make the original throw and take the whole export with
        // it: a profile of `null` (it reads `.rates` off it) and a rates list
        // with a `null` row (it reads `.percent` off that). Neither is worth
        // reproducing, so the port answers what a shop with no tax set up
        // would get.
        let js = try js()
        for profile: JSONValue in [.null,
                                   .object(["mode": .string("inclusive"),
                                            "rates": .array([.null])])] {
            let threw = (try? js.value("""
                KhaytAccountingRows.taxOf({}, {
                  profileFromSettings: function () { return ARG0; },
                })
                """, [profile])) == nil
            #expect(threw, Comment(rawValue: "the original survived \(profile)"))
        }
        // A non-object profile answers the same default a shop with no tax
        // module at all gets, rather than an empty mode nothing reads.
        #expect(AccountingRows.tax(profile: .null) == .init(rate: 0, mode: "inclusive"))
        #expect(AccountingRows.tax(profile: .object(["mode": .string("inclusive"),
                                                     "rates": .array([.null])]))
                == .init(rate: 0, mode: "inclusive"))
        // No tax module at all: zero, inclusive, rather than a wrong figure.
        #expect(AccountingRows.tax(profile: nil) == .init(rate: 0, mode: "inclusive"))
    }

    @Test("no converter means empty base columns, not a wrong figure")
    func baseColumns() throws {
        let orders: [JSONValue] = [.object(["id": .string("a"), "status": .string("completed"),
                                            "price": .number(100), "currency": .string("USD")])]
        let without = AccountingRows.invoiceRows(orders: orders, settings: ["currency": .string("SAR")],
                                                 clients: [], tax: vat)
        guard case .object(let row)? = without.first else { Issue.record("no row"); return }
        #expect(row["baseCurrency"] == .string(""))
        #expect(row["baseAmount"] == nil, "a base figure with nothing to convert with")

        let with = AccountingRows.invoiceRows(orders: orders, settings: ["currency": .string("SAR")],
                                              clients: [], tax: vat,
                                              toBase: { amount, _ in amount * 3.75 })
        guard case .object(let converted)? = with.first else { Issue.record("no row"); return }
        #expect(converted["baseCurrency"] == .string("SAR"))
        #expect(converted["baseAmount"] == .number(375))
    }
}
