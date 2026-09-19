import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the shop bought from a supplier, and what it paid.
///
/// ── WHY THE UNIT IS THE FIELD THAT MATTERS ────────────────────────────────
///
/// `lib/supplier-prices.js` exists because the same word — "PLA" — is attached
/// to a spool bought for 75 and, a month later, to a kilogram bought for 22.
/// Comparing those says the shop's PLA got cheaper when it did nothing of the
/// sort. The unit is what tells them apart, so a log written without one is a
/// log that cannot honestly be compared — which is worse than no log at all.
@MainActor
struct SupplierPurchaseTests {

    static func supplier(_ purchases: [JSONValue]) throws -> Supplier {
        try #require(Supplier(row: .object([
            "id": .string("SUP-1"), "name": .string("Tuwaiq Supply"),
            "purchases": .array(purchases),
        ])))
    }

    static func bought(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string("pch-1"), "date": .string("2026-08-22"),
            "amount": .number(340), "item": .string("4 spools PETG"),
            "notes": .string(""), "quantity": .number(4),
            "unit": .string("spool"), "materialType": .string("PETG"),
            "unitPrice": .number(85),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("a purchase reads as what it was, in the unit it was counted in")
    func reading() throws {
        let sup = try Self.supplier([Self.bought()])
        let one = try #require(sup.purchases.first)
        #expect(one.amount == 340)
        #expect(one.quantity == 4)
        #expect(one.unit == "spool")
        #expect(one.materialType == "PETG")
        #expect(one.unitPrice == 85)
    }

    @Test("a purchase the shop gave no unit price for has none, not a division")
    func noUnitPriceIsNil() throws {
        // The amount divided by the quantity is the RULE's to work out, and
        // writing it here would turn a guess into a fact in the shop's book.
        let absent = try Self.supplier([Self.bought(["unitPrice": .null])])
        #expect(absent.purchases.first?.unitPrice == nil)
        let zero = try Self.supplier([Self.bought(["unitPrice": .number(0)])])
        #expect(zero.purchases.first?.unitPrice == nil)
    }

    @Test("what a supplier has cost is its log added up")
    func totalIsTheLog() throws {
        let sup = try Self.supplier([
            Self.bought(["id": .string("a"), "amount": .number(340)]),
            Self.bought(["id": .string("b"), "amount": .number(170.5)]),
        ])
        #expect(sup.purchaseCount == 2)
        #expect(sup.totalSpent == 510.5)
    }

    @Test("a log written before purchases carried ids still reads")
    func idlessRowsStillRead() throws {
        // Two rows with no id must still be two rows on screen, which is the
        // only thing the id is needed for here.
        var without = Self.bought()
        guard case .object(var o) = without else { Issue.record("not an object"); return }
        o["id"] = nil
        without = .object(o)
        let sup = try Self.supplier([without, without])
        #expect(sup.purchases.count == 2)
        #expect(Set(sup.purchases.map(\.id)).count == 2, "two rows collapsed into one")
    }

    @Test("a row says what it was, in what unit, and what the shop wrote on it")
    func theSecondLine() throws {
        let full = try Self.supplier([Self.bought(["notes": .string("Order #1234")])])
        #expect(full.purchases.first?.said == "PETG · 4 spool · Order #1234")

        // Nothing typed but an amount: no second line rather than an empty one.
        let bare = try Self.supplier([.object([
            "id": .string("p"), "amount": .number(50),
            "quantity": .number(0), "unit": .string(""), "materialType": .string(""),
        ])])
        #expect(bare.purchases.first?.said == nil)
    }

    // MARK: - The wiring

    @Test("a purchase is written against the supplier and nowhere else")
    func aPurchaseIsNotAnExpense() throws {
        // It looks like an expense and is not. An expense is what the shop's
        // books say it spent; a supplier purchase is what a PRICE was, kept so
        // the next one can be compared with it. The other app keeps them apart
        // and so does this.
        let shop = try Self.source("Shop.swift")
        guard let from = shop.range(of: "func logPurchase("),
              let to = shop.range(of: "\n    /// Write a supplier down",
                                  range: from.upperBound..<shop.endIndex) else {
            Issue.record("logPurchase has moved — this check has rotted"); return
        }
        let body = shop[from.lowerBound..<to.lowerBound]
        #expect(body.contains("root[\"suppliers\"]"))
        #expect(!body.contains("\"expenses\""), "logging a purchase also books an expense")
        #expect(body.contains("log.insert(.object(written), at: 0)"),
                "the newest purchase is not written at the top, as the other app writes it")
    }

    @Test("the sheet writes a null unit price rather than a worked-out one")
    func theSheetDoesNotInventAPrice() throws {
        let sheet = try Self.source("PurchaseLogSheet.swift")
        #expect(sheet.contains("entry[\"unitPrice\"] = unitPrice > 0 ? .number(unitPrice) : .null"),
                "the sheet fills in a price the shop did not give")
        // It may SAY what the price works out at — that is a help, not a fact.
        #expect(sheet.contains("mac.works_out_at"))
    }

    @Test("both sheets are reachable and both are presented")
    func reachable() throws {
        let card = try Self.source("SupplierSheet.swift")
        #expect(card.contains("shop.loggingPurchaseFor = supplier"), "no way to log a purchase")
        #expect(card.contains("shop.showingHistoryFor = supplier"), "no way to read the log")

        let window = try Self.source("ShopWindow.swift")
        #expect(window.contains("PurchaseLogSheet(shop: shop, supplier: $0)"))
        #expect(window.contains("PurchaseHistorySheet(shop: shop, supplier: $0)"))
    }

    @Test("the units offered are the ones the other app writes, unchanged")
    func sameUnits() throws {
        // They go into the book untranslated on purpose: a unit stored in one
        // language is a unit the other app's price history cannot group by.
        #expect(PurchaseLogSheet.units == ["spool", "kg", "g", "L", "piece", "roll", "box"])
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let js = try String(contentsOf: repo.appending(path: "renderer/inventory.js"),
                            encoding: .utf8)
        #expect(js.contains("['spool','kg','g','L','piece','roll','box']"),
                "the other app's unit list has changed — these two must agree")
    }

    static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }
}
