import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// The alpha.59 pre-release review: a crafted 3MF that must not crash the
/// library, the calculator's bindings, a re-read that must not win a sync,
/// every embedded G-code counted, and a job's components in its own margin.
@MainActor
struct Alpha59ReviewTests {

    static func shop() async -> Shop {
        let s = Shop()
        await s.load(.sample)
        return s
    }

    // MARK: - S1: a crafted plate index

    @Test("a plate index of 1e20, inf, nan or a repeat is skipped, never trapped on")
    func craftedPlateIndex() {
        func plate(_ index: JSONValue) -> JSONValue {
            .object(["index": index, "printTimeMins": .number(10), "filamentGrams": .number(5),
                     "filaments": .array([.object(["id": .string("1"), "grams": .string("inf")])])])
        }
        let parsed: [String: JSONValue] = [
            "printTimeMins": .number(20), "filamentGrams": .number(10),
            "plates": .array([plate(.number(1e20)), plate(.string("inf")), plate(.string("nan")),
                              plate(.number(-3)), plate(.number(1.5)), plate(.number(1)),
                              plate(.number(1)), plate(.number(2))]),
        ]
        let plates = Shop.plates(parsed: parsed)
        #expect(plates.map(\.index) == [1, 2], "only the two good, distinct indices")
        #expect(plates.allSatisfy { $0.filaments.allSatisfy { $0.grams == 0 } }, "\"inf\" grams read as 0")
    }

    @Test("plate figures and names off the book are finite and short")
    func plateFiguresClamped() {
        let long = String(repeating: "x", count: 500)
        let parsed: [String: JSONValue] = [
            "printTimeMins": .number(20), "filamentGrams": .number(10),
            "plates": .array([
                .object(["index": .number(1), "printTimeMins": .number(10), "filamentGrams": .number(5),
                         "name": .string(long)]),
                .object(["index": .number(2), "printTimeMins": .string("1e400"), "filamentGrams": .number(5)]),
            ]),
        ]
        // The second plate's time is not a figure, so they no longer add up
        // to the file's totals and the file is priced whole — but nothing traps.
        #expect(Shop.plates(parsed: parsed).isEmpty)
        #expect(Shop.sane(.string("1e400"), max: 100) == 0)
        #expect(Shop.sane(.number(1e9), max: 100) == 100)
        #expect(Shop.shortText(.string(long), max: 80)?.count == 80)
    }

    // MARK: - S3: consumable quantities

    @Test("a consumable quantity of inf is never written, and the book still encodes")
    func consumableQuantities() throws {
        let uses = Shop.consumableUses(.array([
            .object(["consumableId": .string("A"), "qty": .string("inf")]),
            .object(["consumableId": .string("B"), "qty": .string("1e400")]),
            .object(["consumableId": .string("C"), "qty": .number(1e9)]),
            .object(["consumableId": .string("D"), "qty": .number(2)]),
        ]))
        #expect(uses.map(\.consumableId) == ["C", "D"])
        #expect(uses.first?.qty == 9999)
        let rows = CalculatorModel.consumableRows([("X", .infinity), ("Y", 3), ("Z", 1e12)], shelf: [])
        #expect(rows.count == 2)
        _ = try JSONEncoder().encode(JSONValue.array(rows))
        #expect(CalculatorModel.consumableQty(.infinity) == 1)
        #expect(CalculatorModel.consumableQty(0) == 1)
        #expect(CalculatorModel.consumableQty(1e9) == 9999)
    }

    @Test("a preset rate of 1e20 or inf seeds the fields without trapping")
    func seedRatesNoTrap() {
        let m = CalculatorModel()
        m.resolved = ["laborRate": 1e20, "wearRate": .infinity, "prepTime": 2, "postTime": 0.5]
        m.seedRates()
        #expect(m.rates["prepTime"] == "2")
        #expect(m.rates["postTime"] == "0.5")
        #expect(m.rates["wearRate"] == nil)
        #expect(m.rates["laborRate"] != nil)
    }

    // MARK: - B3: bindings by id

    @Test("a line's binding survives its removal and a fill that shrinks the list")
    func bindingsById() async throws {
        let shop = await Self.shop()
        let m = CalculatorModel(grams: "100", hours: "2")
        m.addFilament(spools: shop.spools)
        m.addFilament(spools: shop.spools)
        let third = m.lines[2].id
        let grams = m.gramsBinding(third)
        let spool = m.spoolBinding(third)
        grams.wrappedValue = "40"
        #expect(m.lines[2].grams == "40")
        m.removeFilament(third)
        #expect(grams.wrappedValue == "", "a removed line reads empty")
        grams.wrappedValue = "99"          // dropped, not a trap
        spool.wrappedValue = "nothing"
        #expect(m.lines.count == 2)

        // From a model with one colour: three lines become one.
        m.addFilament(spools: shop.spools)
        let gone = m.lines.last!.id
        let vase = try #require(shop.files.first { $0.id == "PF-sample-vase" })
        m.fill(from: vase, plate: nil, grams: 52, hours: 3.5, shop: shop)
        #expect(m.lines.count == 1)
        #expect(m.gramsBinding(gone).wrappedValue == "")
        m.gramsBinding(gone).wrappedValue = "5"
        #expect(m.gramsValue == 52)

        let c = m.lines.first!.id
        m.addConsumable(shop.consumables)
        let line = m.consumableLines[0].id
        let qty = m.consumableQtyBinding(line)
        qty.wrappedValue = .infinity
        #expect(m.consumableLines[0].qty == 1)
        m.removeConsumable(line)
        qty.wrappedValue = 4
        #expect(m.consumableBinding(line).wrappedValue == nil)
        _ = c
    }

    // MARK: - U1: a typed total is not charged twice

    @Test("adding a colour splits the weight already typed, so the total does not grow")
    func addingAColourSplits() async throws {
        let shop = await Self.shop()
        let m = CalculatorModel(grams: "180", hours: "4")
        m.lines[0].spoolId = shop.spools.first?.id
        m.addFilament(spools: shop.spools)
        #expect(m.lines.count == 2)
        #expect(m.gramsValue == 180, "split, not added: \(m.lines.map(\.grams))")
        #expect(m.splitFrom == 180)
        m.gramsBinding(m.lines[1].id).wrappedValue = "60"
        #expect(m.splitFrom == nil, "the note goes once the shop types")
        // A third colour opens empty: the split was the first one's job.
        m.addFilament(spools: shop.spools)
        #expect(m.lines[2].grams == "")
    }

    // MARK: - B4: a re-read is not an edit

    @Test("re-reading a model's slicer figures leaves rev and updatedAt alone; a first read stamps")
    func reReadDoesNotStamp() {
        var root: [String: JSONValue] = ["printFiles": .array([
            .object(["id": .string("A"), "rev": .number(7), "updatedAt": .string("2026-09-01T00:00:00.000Z"),
                     "parsed": .object(["printTimeMins": .number(60), "filamentGrams": .number(20),
                                        "platesRead": .bool(true)]),
                     "colors": .array([.object(["hex": .string("#000000"), "grams": .number(5)])])]),
            .object(["id": .string("B"), "rev": .number(3), "updatedAt": .string("2026-09-01T00:00:00.000Z")]),
        ])]
        let found: [String: [String: JSONValue]] = [
            "A": ["printTimeMins": .number(120), "filamentGrams": .number(40), "platesRead": .number(2),
                  "filaments": .array([.object(["id": .string("1"), "color": .string("#000000"), "grams": .number(40)])])],
            "B": ["printTimeMins": .number(30), "filamentGrams": .number(9), "platesRead": .number(2)],
        ]
        Shop.applySlicerFigures(found, extOf: ["A": "3mf", "B": "3mf"], to: &root)
        guard case .array(let rows)? = root["printFiles"], case .object(let a) = rows[0],
              case .object(let b) = rows[1], case .object(let pa)? = a["parsed"] else {
            Issue.record("rows"); return
        }
        #expect(a["rev"] == .number(7))
        #expect(a["updatedAt"] == .string("2026-09-01T00:00:00.000Z"))
        #expect(pa["printTimeMins"] == .number(120), "the derived figures are still written")
        if case .array(let colours)? = a["colors"], case .object(let c0) = colours[0] {
            #expect(c0["grams"] == .number(40))
        } else { Issue.record("colours") }
        #expect(b["rev"] == .number(4), "a first read is new facts, and is sent")
    }

    // MARK: - B6: every embedded G-code

    @Test("a 3MF with two embedded G-codes and no slice_info is their sum, as model-intake says")
    func severalGcodes() async throws {
        let g = { (t: String, w: String, filler: Int) in
            "; BambuStudio 02.02\n; total estimated time: \(t)\n; total filament weight [g] : \(w)\n; filament_type = PLA\n"
                + String(repeating: "G1 X1 Y1\n", count: filler)
        }
        let url = try SlicerFiguresTests().zip([
            "Metadata/plate_1.gcode": g("1h 0m 0s", "10", 30_000),
            "Metadata/plate_2.gcode": g("0h 30m 0s", "5.5", 30_000),
            "3D/3dmodel.model": "<model/>",
        ])
        let parsed = try #require(await SlicerFigures.read(url, engine: try KhaytEngine()))
        #expect(parsed["printTimeMins"] == .number(90))
        #expect(parsed["filamentGrams"] == .number(15.5))
    }

    // MARK: - B2: a job's components in its own margin

    @Test("the ledger's margin counts the components the job was priced with")
    func ledgerMarginWithComponents() throws {
        let json = #"{"id":"J1","status":"completed","price":100,"costBasis":40,"componentsCost":15,"parts":[]}"#
        let order = try JSONDecoder().decode(Order.self, from: Data(json.utf8))
        #expect(order.componentsCost == 15)
        let money = Shop.ledgerMoney(order)
        #expect(money.marginMoney == 45)
        let odd = try JSONDecoder().decode(Order.self, from: Data(
            #"{"id":"J2","price":100,"costBasis":40,"componentsCost":"x"}"#.utf8))
        #expect(odd.componentsCost == 0, "a stray value is no cost, and the job still reads")
    }

    @Test("the sheet's count of assemblies prices and saves the components")
    func assemblyCount() async throws {
        let shop = await Self.shop()
        var product = Product(id: "PROD-1", names: ["en": "Dallah stand"], descriptions: [:],
                              margin: 35, group: "", category: "", createdAt: "2026-09-01", rest: [:])
        product.rest["components"] = .array([.object(["consumableId": .string("CONS-07"), "qtyPerUnit": .number(4)])])
        product.rest["assemblyQty"] = .number(1)
        let one = await shop.jobComponentsCost(of: product)
        let three = await shop.jobComponentsCost(of: product, assemblyQty: 3)
        #expect(one > 0)
        #expect(abs(three - one * 3) < 1e-9)
        let input = shop.newJobInput(parts: [], project: "x", clientId: nil, margin: 30, discountPct: 0,
                                     shippingCost: 0, deposit: 0, rush: false, asQuote: false,
                                     fromProduct: product, assemblyQty: 3)
        #expect(input["assemblyQty"] == .number(3))
        product.rest["assemblyQty"] = .string("1e400")
        #expect(Shop.assemblyQty(of: product) == 1)
    }

    // MARK: - U6 / U7: names on screen

    @Test("a catalogue name that repeats its brand loses the repeat")
    func catalogueNames() throws {
        let hits = try JSONDecoder().decode([KhaytEngine.FilamentHit].self, from: Data(#"""
        [{"brand":"123-3D","name":"123-3D Filament PLA","material":"PLA","colours":[],"unmatched":[]},
         {"brand":"Bambu Lab","name":"PLA Matte","material":"PLA","colours":[],"unmatched":[]},
         {"brand":"Bambu Lab","name":"PLA Basic","material":"PLA","colours":[],"unmatched":[]}]
        """#.utf8))
        #expect(SpoolSheet.catalogueName(hits[0], underBrand: false) == "123-3D Filament PLA")
        #expect(SpoolSheet.catalogueName(hits[0], underBrand: true) == "Filament PLA")
        #expect(SpoolSheet.catalogueName(hits[1], underBrand: false) == "Bambu Lab PLA Matte")
        let groups = SpoolSheet.catalogueGroups(hits)
        #expect(groups.map(\.brand) == ["123-3D", "Bambu Lab"])
        #expect(groups[1].hits.count == 2)
    }

    @Test("an as-sliced filament says its slot and its material")
    func slotLabels() async {
        let shop = await Self.shop()
        let w = shop.words
        let label = LibraryInspector.slotLabel(.init(slot: "2", material: "PLA", hex: nil, grams: 1), words: w)
        #expect(label.contains("PLA") && label.contains("·"))
        #expect(LibraryInspector.slotLabel(.init(slot: "", material: "", hex: nil, grams: 1), words: w)
                == w.callIt("mac.filament"))
    }
}
