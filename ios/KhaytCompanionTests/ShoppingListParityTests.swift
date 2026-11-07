import XCTest
import JavaScriptCore
import KhaytCore
@testable import KhaytCompanion

/**
 * The phone's shopping list against the shop's own.
 *
 * `ReorderRules` is a Swift port of `lib/reorder.js` `shoppingList` and
 * `shoppingListText`, with the low-stock rule the Mac hands it
 * (`KhaytOrderDeduction.isLowStock`, through `lib/inventory-units.js`). Every
 * answer here is asked of the REAL JavaScript, loaded out of `lib/` into
 * JavaScriptCore with the Mac's own call (`KhaytEngine.shoppingList`), and the
 * Swift must give the same one. Change the rule and this fails.
 *
 * The fixtures: nothing low; several suppliers; a spool with no supplier; a
 * supplier id that names nobody; exactly at the reorder point and one gram
 * above; the shop's threshold and each unit's default; a price list that
 * outranks the spool's own supplier; values stored as strings, nulls and
 * blanks; rows that are not records; a price list the JavaScript throws on.
 */
final class ShoppingListParityTests: XCTestCase {

    private var js: JSContext!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        for file in ["lib/inventory-units.js", "lib/order-deduction.js", "lib/reorder.js"] {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            ctx.evaluateScript(source)
            XCTAssertNil(thrown, "\(file) did not load: \(thrown ?? "")")
        }
        js = ctx
    }

    // MARK: - Asking the JavaScript

    private func text(_ v: JSONValue) -> String {
        String(data: try! JSONEncoder().encode(v), encoding: .utf8)!
    }

    private func ask(_ expression: String) throws -> JSONValue {
        let out = try XCTUnwrap(js.evaluateScript("JSON.stringify(\(expression))")?.toString(), expression)
        return try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
    }

    /// The Mac's call, word for word (`KhaytEngine.shoppingList`).
    private func rule(_ inventory: [JSONValue], _ suppliers: [JSONValue], _ settings: [String: JSONValue],
                      noSupplier: String = "No supplier set", title: String = "Shopping list — Shop") throws -> JSONValue {
        try ask("""
        (function () {
          var groups = KhaytReorder.shoppingList(\(text(.array(inventory))), \(text(.array(suppliers))), {
            isLow: function (s) { return KhaytOrderDeduction.isLowStock(s, \(text(.object(settings)))); },
            noSupplier: \(text(.string(noSupplier))),
          });
          return { groups: groups, text: KhaytReorder.shoppingListText(groups, \(text(.string(title)))) };
        })()
        """)
    }

    /// The Swift's answer, in the JavaScript's shape.
    private func swift(_ inventory: [JSONValue], _ suppliers: [JSONValue], _ settings: [String: JSONValue],
                       noSupplier: String = "No supplier set", title: String = "Shopping list — Shop") -> JSONValue {
        let groups = ReorderRules.shoppingList(inventory: inventory, suppliers: suppliers, settings: settings,
                                               noSupplier: noSupplier)
        return .object([
            "groups": .array(groups.map { g in
                .object(["supplier": .string(g.supplier), "items": .array(g.items.map { i in
                    .object(["id": .string(i.id), "name": .string(i.name), "have": .number(i.have),
                             "buy": .number(i.buy), "color": .string(i.color)])
                })])
            }),
            "text": .string(ReorderRules.shoppingListText(groups, title: title)),
        ])
    }

    private func same(_ inventory: [JSONValue], _ suppliers: [JSONValue], settings: [String: JSONValue] = [:],
                      noSupplier: String = "No supplier set", _ what: String,
                      file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        let r = try rule(inventory, suppliers, settings, noSupplier: noSupplier)
        XCTAssertEqual(swift(inventory, suppliers, settings, noSupplier: noSupplier), r, what, file: file, line: line)
        return r
    }

    private func groups(_ v: JSONValue) -> [String] {
        guard case .object(let o) = v, case .array(let g)? = o["groups"] else { return [] }
        return g.compactMap { if case .object(let x) = $0, case .string(let s)? = x["supplier"] { return s }; return nil }
    }

    // MARK: - Fixtures

    private func spool(_ id: String, _ material: JSONValue?, weight: JSONValue?, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "color": .string("#112233")]
        if let material { o["material"] = material }
        if let weight { o["weight"] = weight }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    private func seller(_ id: JSONValue, _ name: JSONValue?, _ prices: [(String, JSONValue)]) -> JSONValue {
        var o: [String: JSONValue] = ["id": id,
                                      "priceList": .array(prices.map { .object(["material": .string($0.0), "pricePerKg": $0.1]) })]
        if let name { o["name"] = name }
        return .object(o)
    }

    private var suppliers: [JSONValue] {
        [
            seller(.string("S1"), .string("Filament House"), [("PLA", .number(80)), ("PETG", .string("95"))]),
            seller(.string("S2"), .string("Cheap Plastics"), [("PLA Black", .number(60)), ("PLA-CF", .number(150))]),
            seller(.string("S3"), .string("Resin Co"), []),
            seller(.string("S4"), .string("Ábaco Filamentos"), [("TPU 95A", .number(0)), ("ASA", .null)]),
            seller(.number(7), .string("Numbered"), []),
            seller(.string("S5"), nil, []),
            .null,
            .string("not a supplier"),
        ]
    }

    // MARK: - The list

    func testNothingLowIsAnEmptyList() throws {
        let shelf = [spool("a", .string("PLA"), weight: .number(900)),
                     spool("b", .string("PETG"), weight: .number(201))]
        let r = try same(shelf, suppliers, "nothing low")
        XCTAssertEqual(groups(r), [])
        XCTAssertTrue(ReorderRules.shoppingList(inventory: shelf, suppliers: suppliers, settings: [:],
                                                noSupplier: "x").isEmpty)
    }

    func testSeveralSuppliersAndNone() throws {
        let shelf: [JSONValue] = [
            // Priced by name: the PLA price lists. The same family in two
            // lists, and the cheaper of the closest wins.
            spool("p1", .string("PLA"), weight: .number(150)),
            // Whole words outrank the family: PLA-CF by Cheap Plastics.
            spool("p2", .string("pla_cf"), weight: .number(40), ["reorderQty": .number(500)]),
            // PETG priced by a string price.
            spool("p3", .string("PETG"), weight: .string("120")),
            // Its own supplier, no price list for resin.
            spool("r1", .string("Resin"), weight: .number(80), ["supplierId": .string("S3")]),
            // A supplier id that names nobody: no supplier.
            spool("r2", .string("Resin"), weight: .number(10), ["supplierId": .string("S-gone")]),
            // No supplier at all, no material.
            spool("x1", nil, weight: .number(0)),
            // A price list entry at 0 and one null price do not price.
            spool("t1", .string("TPU 95A"), weight: .number(50), ["supplierId": .number(7)]),
            spool("a1", .string("ASA"), weight: .number(50), ["supplierId": .string("S5")]),
            // A price list outranks the spool's own supplier.
            spool("p4", .string("PLA Black"), weight: .number(3), ["supplierId": .string("S3"), "color": .null]),
            // Not low.
            spool("ok", .string("PLA"), weight: .number(800), ["supplierId": .string("S3")]),
        ]
        let r = try same(shelf, suppliers, noSupplier: "لا يوجد مورّد", "several suppliers")
        XCTAssertEqual(Set(groups(r)), ["Cheap Plastics", "Filament House", "Resin Co", "Numbered", "لا يوجد مورّد"])
    }

    func testAtTheReorderPointAndOneGramAbove() throws {
        let shelf: [JSONValue] = [
            spool("own-at", .string("PLA"), weight: .number(300), ["reorderPoint": .number(300)]),
            spool("own-above", .string("PLA"), weight: .number(301), ["reorderPoint": .number(300)]),
            spool("own-string", .string("PLA"), weight: .number(250), ["reorderPoint": .string("250")]),
            spool("own-blank", .string("PLA"), weight: .number(250), ["reorderPoint": .string("")]),
            spool("own-null", .string("PLA"), weight: .number(200), ["reorderPoint": .null]),
            spool("own-zero", .string("PLA"), weight: .number(0), ["reorderPoint": .number(0)]),
            spool("default-at", .string("PETG"), weight: .number(200)),
            spool("default-above", .string("PETG"), weight: .number(201)),
            spool("fraction", .string("PETG"), weight: .number(199.5), ["reorderQty": .number(749.5)]),
            spool("bad-weight", .string("PETG"), weight: .string("lots")),
        ]
        for threshold: JSONValue? in [nil, .number(250), .string("250"), .string(""), .null, .number(-1)] {
            var settings: [String: JSONValue] = [:]
            if let threshold { settings["lowStockThreshold"] = threshold }
            _ = try same(shelf, suppliers, settings: settings, "threshold \(String(describing: threshold))")
        }
        // The shop's threshold is grams only; ml and sheets keep their own.
        let units: [JSONValue] = [
            spool("ml-at", .string("Resin"), weight: .number(150), ["unit": .string("ml")]),
            spool("ml-above", .string("Resin"), weight: .number(151), ["unit": .string(" ML ")]),
            spool("sheet", .string("Ply"), weight: .number(2), ["unit": .string("sheet")]),
            spool("sheet-above", .string("Ply"), weight: .number(2.5), ["unit": .string("sheet")]),
            spool("unknown-unit", .string("PLA"), weight: .number(400), ["unit": .string("spools")]),
        ]
        for settings: [String: JSONValue] in [[:], ["lowStockThreshold": .number(500)]] {
            _ = try same(units, suppliers, settings: settings, "units \(settings)")
        }
    }

    func testOddRecordsAndOddPriceLists() throws {
        let shelf: [JSONValue] = [
            .null, .string("a row that is not a record"), .number(0),
            // (A material that is not a string is listed as the JavaScript's
            // own value, not a string; the phone's rows are strings, so that
            // case is not compared.)
            spool("n", .string("PETG"), weight: .null, ["id": .number(17), "reorderQty": .string("2000")]),
            spool("q", .string("PLA"), weight: .number(5), ["id": .null, "reorderQty": .number(0)]),
            spool("arr", .string("PLA"), weight: .array([.string("9")])),
        ]
        _ = try same(shelf, suppliers, "odd records")
        // A price list that is neither a list nor a string makes the
        // JavaScript throw; the list then falls back to the spool's own.
        var broken = suppliers
        broken.insert(.object(["id": .string("B"), "name": .string("Broken"), "priceList": .object(["PLA": .number(1)])]), at: 0)
        let low = [spool("p", .string("PLA"), weight: .number(5), ["supplierId": .string("S3")]),
                   spool("q", .string("PLA"), weight: .number(5))]
        let r = try same(low, broken, "a price list the rule throws on")
        XCTAssertEqual(groups(r), ["No supplier set", "Resin Co"])
        // A price list as a string walks as letters, and prices nothing.
        let stringy: [JSONValue] = [.object(["id": .string("T"), "name": .string("Stringy"), "priceList": .string("PLA")])]
        _ = try same(low, stringy, "a price list that is a string")
    }

    func testTheTextIsTheOtherAppsText() throws {
        let shelf = [spool("p1", .string("PLA"), weight: .number(150.4)),
                     spool("r1", .string("Resin"), weight: .number(80), ["supplierId": .string("S3"), "reorderQty": .number(2000)])]
        let r = try rule(shelf, suppliers, [:])
        guard case .object(let o) = r, case .string(let t)? = o["text"] else { return XCTFail("no text") }
        XCTAssertEqual(t, "Shopping list — Shop\n\nFilament House\n  • PLA   150 g → 1000 g\n\nResin Co\n  • Resin   80 g → 2000 g\n")
    }

    // MARK: - The pieces

    func testSupplierPriceForMatchesTheRule() throws {
        for material in ["PLA", "pla", "PLA Black", "PLA-CF", "pla cf black", "PETG", "PCTG", "TPU 95A", "ASA", "Resin", "",
                         "Silk PLA+", "ábaco"] {
            let r = try ask("KhaytReorder.supplierPriceFor(\(text(.array(suppliers))), \(text(.string(material))))")
            let s = try ReorderRules.supplierPriceFor(suppliers, material: .string(material))
            if case .object(let o) = r {
                let q = try XCTUnwrap(s, material)
                XCTAssertEqual(o["supplierName"], .string(q.supplierName), material)
                XCTAssertEqual(o["supplierId"], q.supplierId, material)
                XCTAssertEqual(o["pricePerKg"], .number(q.pricePerKg), material)
            } else {
                XCTAssertNil(s, material)
            }
        }
    }

    func testIsLowStockMatchesTheRule() throws {
        let items: [[String: JSONValue]] = [
            [:], ["weight": .number(200)], ["weight": .number(200.01)], ["weight": .string(" 12 ")],
            ["weight": .number(100), "reorderPoint": .number(50)], ["weight": .number(100), "reorderPoint": .string("abc")],
            ["weight": .number(140), "unit": .string("ml")], ["weight": .number(1), "unit": .string("sheet"), "reorderPoint": .string("")],
            ["weight": .bool(true)], ["weight": .array([])],
        ]
        for settings: [String: JSONValue] in [[:], ["lowStockThreshold": .number(100)], ["lowStockThreshold": .string("x")]] {
            for item in items {
                let r = try ask("KhaytOrderDeduction.isLowStock(\(text(.object(item))), \(text(.object(settings))))")
                XCTAssertEqual(r, .bool(ReorderRules.isLowStock(item, settings: settings)), "\(item) \(settings)")
            }
        }
    }

    /// The sample shop's list: three suppliers, as the demo promises.
    func testTheSampleShopHasThreeSuppliersToBuyFrom() throws {
        let store = SampleShop.book()
        let list = ShopShoppingList(store: store, shopName: "Sample Print Shop")
        XCTAssertEqual(list.groups.map(\.supplier), ["Bambu Lab Store", "Elegoo Official", "Filament Depot"])
        guard case .object(let settings)? = store["settings"], case .array(let inv)? = store["inventory"],
              case .array(let sup)? = store["suppliers"] else { return XCTFail("no book") }
        _ = try same(inv, sup, settings: settings, "the sample shop")
    }
}
