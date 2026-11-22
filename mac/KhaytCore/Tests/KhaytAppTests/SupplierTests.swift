import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's suppliers, and the one field on them that decides anything.
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// A supplier looks like a contact card and is not one. Its price list is what
/// `lib/reorder.js` reads to decide what a drafted purchase order costs, so a
/// form that wrote the list wrongly — or that wrote the whole record back and
/// took the shop's purchase log with it — would either misprice every order the
/// Mac raises or quietly empty a history the other app keeps.
///
/// The last test is the wiring one: it takes what this app would WRITE and
/// hands it to the rule that prices an order, because a form whose output the
/// pricing rule cannot read is a form that does nothing.
@MainActor
struct SupplierTests {

    static func row(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string("sup-1"),
            "name": .string("Tuwaiq Supply"),
            "category": .string("filament"),
            "phone": .string("+966 50 111 2222"),
            "leadDays": .number(7),
            "website": .string("https://tuwaiq.example"),
            "notes": .string("Ask for Salem"),
            "priceList": .array([
                .object(["material": .string("PLA+"), "pricePerKg": .number(85)]),
                .object(["material": .string("PETG"), "pricePerKg": .number(96)]),
            ]),
            "purchases": .array([
                .object(["date": .string("2026-08-01"), "amount": .number(340)]),
                .object(["date": .string("2026-09-01"), "amount": .number(170)]),
            ]),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    // MARK: - Reading one off the book

    @Test("a supplier row reads as what a row and a form need")
    func reading() throws {
        let sup = try #require(Supplier(row: Self.row()))
        #expect(sup.name == "Tuwaiq Supply")
        #expect(sup.category == "filament")
        #expect(sup.leadDays == 7)
        #expect(sup.priceList.count == 2)
        #expect(sup.purchaseCount == 2)
        #expect(sup.totalSpent == 510, "340 and 170 is what this supplier has cost")
    }

    @Test("a lead time of zero is a shop that has never said, not same-day delivery")
    func zeroLeadIsSilence() throws {
        // The other app writes `leadDays: num(...) || null`, so a zero in the
        // book means nothing was typed. Reading it as 0 would draw "0 days",
        // which claims the goods arrive the moment they are ordered.
        let none = try #require(Supplier(row: Self.row(["leadDays": .number(0)])))
        #expect(none.leadDays == nil)
        let absent = try #require(Supplier(row: Self.row(["leadDays": .null])))
        #expect(absent.leadDays == nil)
    }

    @Test("a quote with no material, or no price, is not a quote")
    func halfQuotesAreDropped() throws {
        let sup = try #require(Supplier(row: Self.row(["priceList": .array([
            .object(["material": .string("PLA"), "pricePerKg": .number(85)]),
            .object(["material": .string(""), "pricePerKg": .number(90)]),
            .object(["material": .string("ABS"), "pricePerKg": .number(0)]),
        ])])))
        #expect(sup.priceList.map(\.material) == ["PLA"],
                "a half-written quote reached the pricing rule")
    }

    @Test("a row with no id is not a supplier")
    func idIsRequired() {
        #expect(Supplier(row: .object(["name": .string("Nameless")])) == nil)
    }

    // MARK: - What a save writes

    @Test("a save writes the form's fields and NOTHING else")
    func saveIsAMerge() throws {
        // THE RE-ENCODING TRAP. A Mac product save once wrote a product back
        // from its own form and dropped the part costs off it, re-pricing it
        // at a quarter of what it was worth. A supplier carries `purchases` —
        // the log the other app writes — and this form has never heard of it.
        let sup = try #require(Supplier(row: Self.row()))
        let edits = sup.edits
        #expect(edits["purchases"] == nil, "a save would have rewritten the purchase log")
        #expect(edits["id"] == nil, "a save would have rewritten the id")
        #expect(edits["name"] == .string("Tuwaiq Supply"))
        #expect(edits["leadDays"] == .number(7))
    }

    @Test("clearing the lead time writes null, not the figure that was there")
    func clearedLeadIsNull() throws {
        var sup = try #require(Supplier(row: Self.row()))
        sup.leadDays = nil
        // NULL rather than absent: a merge writes the keys it is given, so an
        // absent one would leave the old 7 sitting in the book while the form
        // showed blank.
        #expect(sup.edits["leadDays"] == .null)
    }

    @Test("a save trims what was typed, and drops the half-written quotes")
    func saveTidies() throws {
        var sup = try #require(Supplier(row: Self.row()))
        sup.name = "  Tuwaiq Supply  "
        sup.priceList = [
            Supplier.Quote(material: " PLA+ ", pricePerKg: 85),
            Supplier.Quote(material: "", pricePerKg: 90),
            Supplier.Quote(material: "ABS", pricePerKg: 0),
        ]
        let edits = sup.edits
        #expect(edits["name"] == .string("Tuwaiq Supply"))
        #expect(edits["priceList"] == .array([
            .object(["material": .string("PLA+"), "pricePerKg": .number(85)]),
        ]), "an empty row somebody added and did not fill in was written down")
    }

    @Test("a category the picker does not have is left alone")
    func unknownCategorySurvives() throws {
        // The other app has never validated this field. Writing it back as
        // `other` because this picker has no option for it would be this app
        // editing a fact it was not asked to edit.
        let sup = try #require(Supplier(row: Self.row(["category": .string("resin")])))
        #expect(sup.edits["category"] == .string("resin"))
    }

    // MARK: - The wiring: a quote written here prices an order drafted here

    @Test("a price recorded on this form is what a drafted order is priced at")
    func quotesReachTheRule() async throws {
        // What the sheet would save, handed to the rule that prices an order.
        // If `edits` spelled the list differently — `prices`, or a figure per
        // gram — every order drafted on the Mac would go on being priced off
        // the spool's own cost and this suite would still be green.
        var sup = try #require(Supplier(row: Self.row()))
        sup.priceList = [Supplier.Quote(material: "PLA+", pricePerKg: 85)]
        guard case .object(var written) = JSONValue.object(sup.edits) else {
            Issue.record("a supplier's edits are not an object"); return
        }
        written["id"] = .string("sup-1")

        let engine = try KhaytEngine()
        let spool: JSONValue = .object([
            "id": .string("sp-1"), "material": .string("PLA+"),
            "cost": .number(200), "spoolWeight": .number(1000),
        ])
        let priced = try await engine.perGramPrice(item: spool, suppliers: [.object(written)])
        #expect(priced.perG == 0.085, "85 a kilo is 0.085 a gram — the quote was not read")
        #expect(priced.supplierId == "sup-1")
        #expect(priced.supplierName == "Tuwaiq Supply")

        // And WITHOUT the quote it falls back to the spool's own cost, which is
        // what the Mac has been doing all along. The difference between the two
        // is what this form buys the shop.
        var quoteless = written
        quoteless["priceList"] = .array([])
        let fallback = try await engine.perGramPrice(item: spool, suppliers: [.object(quoteless)])
        #expect(fallback.perG == 0.2, "200 for a 1,000 g spool is 0.2 a gram")
    }

    // MARK: - The screen

    @Test("the suppliers card is drawn even when there are none")
    func emptyStillDrawsTheCard() throws {
        // A card that appeared only once a supplier existed would leave a shop
        // with no way to write its first one down — which is the gap this
        // whole screen exists to close.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let card = try String(contentsOf: sources.appending(path: "SupplierSheet.swift"),
                              encoding: .utf8)
        #expect(card.contains("sup.empty"), "an empty list says nothing at all")
        #expect(card.contains("Supplier.blank()"), "there is no way to add the first one")

        let floor = try String(contentsOf: sources.appending(path: "ShopFloor.swift"),
                               encoding: .utf8)
        #expect(floor.contains("SuppliersCard(shop: shop)"), "the card is on no screen")

        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"),
                                encoding: .utf8)
        #expect(window.contains("SupplierSheet(shop: shop, supplier: $0)"),
                "the sheet is never presented")
    }

    @Test("a supplier the shop has never spent anything with shows a dash")
    func nothingSpentIsADash() throws {
        let fresh = try #require(Supplier(row: Self.row(["purchases": .array([])])))
        #expect(fresh.totalSpent == 0)
        #expect(fresh.purchaseCount == 0)
    }
}
