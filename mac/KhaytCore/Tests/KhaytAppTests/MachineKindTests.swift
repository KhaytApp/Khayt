import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Khayt was written for filament printers and said so everywhere.
///
/// A machine had a nozzle diameter, an extruder type and a colour count; the
/// thing that wore out was a nozzle. A shop that also runs a resin printer, a
/// UV flatbed or a laser cutter had to record all three as FDM printers, and
/// the app told the laser its nozzle was 0.4 mm.
///
/// `lib/machine-kinds.js` is the vocabulary. These test the crossing and the
/// two decisions it would be easy to re-make in Swift and get wrong.
@MainActor
struct MachineKindTests {

    static func machine(_ id: String, kind: String? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
        if let kind { row["kind"] = .string(kind) }
        return .object(row)
    }

    static func kinds(_ machines: [JSONValue]) async throws -> [String: KhaytEngine.MachineKind] {
        try await KhaytEngine().machineKinds(machines)
    }

    @Test("a machine with no kind crosses back as a filament printer")
    func absentIsFdm() async throws {
        // Not a default: until this existed nothing else could be recorded, so
        // every machine in every existing book genuinely is one.
        let k = try await Self.kinds([Self.machine("M1")])
        #expect(k["M1"]?.kind == "fdm")
        #expect(k["M1"]?.consumable == "filament")
        #expect(k["M1"]?.unit == "g")
    }

    @Test("a kind this build has not learned still comes back as a machine")
    func unknownKindStillDraws() async throws {
        // A newer Khayt writing `kind: "waterjet"` into a synced book must not
        // make a machine vanish from an older one. Wrong is survivable.
        let k = try await Self.kinds([Self.machine("M1", kind: "waterjet")])
        #expect(k["M1"]?.kind == "fdm")
    }

    @Test("each kind says what it eats and what wears out on it")
    func eachKind() async throws {
        let k = try await Self.kinds([
            Self.machine("F", kind: "fdm"), Self.machine("R", kind: "resin"),
            Self.machine("U", kind: "uv"), Self.machine("L", kind: "laser"),
            Self.machine("C", kind: "cnc"),
        ])
        #expect(k["R"]?.consumable == "resin" && k["R"]?.unit == "ml")
        #expect(k["U"]?.consumable == "ink" && k["U"]?.unit == "ml")
        #expect(k["L"]?.consumable == "sheet")
        #expect(k["C"]?.consumable == "stock")
        // A resin printer has two things wearing on two different clocks.
        #expect(k["R"]?.wear.map(\.part) == ["fep", "lcd"])
        #expect(k["F"]?.wear.map(\.part) == ["nozzle"])
    }

    /// The bug this exists to stop.
    @Test("nothing but a filament printer is offered a nozzle, an extruder or colours")
    func noNozzleOnALaser() async throws {
        let k = try await Self.kinds(["fdm", "resin", "uv", "laser", "cnc"].map {
            Self.machine($0, kind: $0)
        })
        for field in ["nozzleDiameter", "extruderType", "maxColors"] {
            #expect(k["fdm"]?.shows(field) == true)
            for kind in ["resin", "uv", "laser", "cnc"] {
                #expect(k[kind]?.shows(field) == false,
                        "a \(kind) would be shown its \(field)")
            }
        }
        // And every kind has a size and a power bill.
        for kind in ["fdm", "resin", "uv", "laser", "cnc"] {
            #expect(k[kind]?.shows("bed") == true)
            #expect(k[kind]?.shows("powerDraw") == true)
        }
    }

    /// The distinction the band draws on.
    @Test("only a filament printer claims a protocol this app actually has")
    func onlyFdmIsPolled() async throws {
        let k = try await Self.kinds(["fdm", "resin", "uv", "laser", "cnc"].map {
            Self.machine($0, kind: $0)
        })
        #expect(k["fdm"]?.polled == true)
        for kind in ["resin", "uv", "laser", "cnc"] {
            #expect(k[kind]?.polled == false,
                    "a \(kind) claiming a protocol would be drawn as a printer that has stopped answering")
        }
    }

    @Test("the picker offers every kind, each with a name this app can say")
    func pickerIsComplete() async throws {
        let engine = try KhaytEngine()
        let choices = try await engine.machineKindChoices()
        #expect(choices.map(\.kind) == ["fdm", "resin", "uv", "laser", "cnc"])

        for words in [Words(), Words()] { _ = words }
        let en = Words(); await en.load("en", engine: engine)
        let ar = Words(); await ar.load("ar", engine: engine)
        for choice in choices {
            for key in [choice.nameKey, choice.consumableKey, choice.unitKey] {
                #expect(en.callIt(key) != key, "\(choice.kind): \(key) has no English")
                #expect(ar.callIt(key) != key, "\(choice.kind): \(key) has no Arabic")
            }
            for wear in choice.wear {
                #expect(en.callIt(wear.label) != wear.label, "\(wear.part) has no English")
                #expect(ar.callIt(wear.label) != wear.label, "\(wear.part) has no Arabic")
                #expect(en.callIt(wear.unit) != wear.unit, "\(wear.unit) has no English")
                #expect(ar.callIt(wear.unit) != wear.unit, "\(wear.unit) has no Arabic")
            }
        }
    }

    /// A screen that cannot ask a machine anything must say which of the two
    /// reasons applies, and the words have to exist in both languages.
    @Test("'no protocol' and 'not answering' are different sentences")
    func twoDifferentSentences() async throws {
        let engine = try KhaytEngine()
        let en = Words(); await en.load("en", engine: engine)
        let ar = Words(); await ar.load("ar", engine: engine)
        for key in ["mac.band_no_protocol", "mac.band_cannot_ask",
                    "mac.band_not_asked", "mac.band_unknown"] {
            #expect(en.callIt(key) != key, "\(key) has no English")
            #expect(ar.callIt(key) != key, "\(key) has no Arabic")
        }
        #expect(en.callIt("mac.band_no_protocol") != en.callIt("mac.band_cannot_ask"),
                "a laser cutter and a printer that has stopped must not read the same")
        #expect(en.callIt("mac.band_not_asked") != en.callIt("mac.band_unknown"))
    }
}

/// What an inventory item is counted in.
///
/// Every quantity on every screen was written `"\(Int(x)) g"` because grams
/// were the only thing anything could be recorded in. A bottle of resin said
/// "500 g" and a stack of plywood said "6 g".
@MainActor
struct InventoryUnitTests {

    static func item(_ id: String, unit: String? = nil,
                     cost: Double? = nil, held: Double? = nil,
                     left: Double? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["id": .string(id), "material": .string(id)]
        if let unit { row["unit"] = .string(unit) }
        if let cost { row["cost"] = .number(cost) }
        if let held { row["spoolWeight"] = .number(held) }
        if let left { row["weight"] = .number(left) }
        return .object(row)
    }

    static func units(_ items: [JSONValue],
                      settings: [String: JSONValue] = [:]) async throws -> [String: KhaytEngine.InventoryUnit] {
        try await KhaytEngine().inventoryUnits(items, settings: settings)
    }

    @Test("an item with no unit crosses back as grams")
    func absentIsGrams() async throws {
        let u = try await Self.units([Self.item("A")])
        #expect(u["A"]?.unit == "g")
        #expect(u["A"]?.measure == "mass")
        #expect(u["A"]?.low == 200, "and at exactly the threshold it always had")
    }

    /// The one place the gram assumption was load bearing rather than cosmetic.
    @Test("a price is quoted per kilo, per litre or per sheet — never all three")
    func theDenominator() async throws {
        let u = try await Self.units([
            Self.item("spool", unit: "g", cost: 75, held: 1000),
            Self.item("bottle", unit: "ml", cost: 180, held: 500),
            Self.item("ply", unit: "sheet", cost: 240, held: 10),
        ])
        #expect(u["spool"]?.rate == 75)
        #expect(u["spool"]?.rateKey == "unit.per_kg")
        // 180 for half a litre is 360 a litre. The old `costPerKilo` answered
        // 360 too, and called it a kilo.
        #expect(u["bottle"]?.rate == 360)
        #expect(u["bottle"]?.rateKey == "unit.per_L")
        #expect(u["ply"]?.rate == 24)
        #expect(u["ply"]?.rateKey == "unit.per_sheet")
    }

    @Test("an item with no record of what it held has no rate, rather than a climbing one")
    func noRateWithoutTheOriginal() async throws {
        let u = try await Self.units([Self.item("old", unit: "g", cost: 75, left: 300)])
        #expect(u["old"]?.rate == nil,
                "a rate from what is LEFT climbs as the item empties, worst just before reorder")
    }

    @Test("low means something different per unit")
    func lowPerUnit() async throws {
        let u = try await Self.units([
            Self.item("spool", unit: "g"), Self.item("bottle", unit: "ml"),
            Self.item("ply", unit: "sheet"),
        ])
        #expect(u["spool"]?.low == 200)
        #expect(u["bottle"]?.low == 150)
        #expect(u["ply"]?.low == 2, "200 sheets is not low stock, it is a warehouse")
    }

    @Test("the shop's own threshold is a gram figure and reaches only grams")
    func shopThresholdIsGrams() async throws {
        let u = try await Self.units([
            Self.item("spool", unit: "g"), Self.item("ply", unit: "sheet"),
        ], settings: ["lowStockThreshold": .number(500)])
        #expect(u["spool"]?.low == 500)
        #expect(u["ply"]?.low == 2, "a shop that types 500 means grams, not sheets")
    }

    @Test("half a sheet is a real thing to have left; half a gram is not")
    func decimals() async throws {
        let u = try await Self.units([Self.item("g", unit: "g"), Self.item("s", unit: "sheet")])
        #expect(u["g"]?.decimals == 0)
        #expect(u["s"]?.decimals == 1)
    }

    @Test("every unit has both its words, in both languages")
    func everyWord() async throws {
        let engine = try KhaytEngine()
        let choices = try await engine.inventoryUnitChoices()
        #expect(choices.map(\.unit) == ["g", "ml", "sheet"])
        let en = Words(); await en.load("en", engine: engine)
        let ar = Words(); await ar.load("ar", engine: engine)
        for choice in choices {
            for key in [choice.unitKey, choice.rateKey, "inv.unit_\(choice.unit)"] {
                #expect(en.callIt(key) != key, "\(choice.unit): \(key) has no English")
                #expect(ar.callIt(key) != key, "\(choice.unit): \(key) has no Arabic")
            }
        }
        // The word after a quantity and the word after a slash are not the
        // same word: "6 sheets", but "24.00 / sheet".
        let sheet = try #require(choices.first { $0.unit == "sheet" })
        #expect(en.callIt(sheet.unitKey) != en.callIt(sheet.rateKey))
    }

    @Test("a quantity is written in the unit the item is counted in")
    func quantitiesAreSaidRight() async throws {
        let engine = try KhaytEngine()
        let words = Words(); await words.load("en", engine: engine)
        let u = try await Self.units([
            Self.item("g", unit: "g"), Self.item("ml", unit: "ml"), Self.item("s", unit: "sheet"),
        ])
        #expect(Quantity.say(940, u["g"], words) == "940 g")
        #expect(Quantity.say(340, u["ml"], words) == "340 ml")
        #expect(Quantity.say(6, u["s"], words) == "6 sheets")
        #expect(Quantity.say(2.5, u["s"], words) == "2.5 sheets", "half a sheet survives")
        #expect(Quantity.say(940, nil, words).hasSuffix(words.callIt("common.grams")),
                "before the book loads, a quantity is grams — which every old one is")
    }
}

/// Every place that writes a shelf quantity has to ask what it is counted in.
///
/// Three did not, and each was found by looking at a different screen: the
/// dashboard's attention panel reported "2 g" for two sheets of acrylic, the
/// colour studio reported "6 g" for six sheets of plywood, and a spool picked
/// out of a list read "Birch ply · 6g · Rack by the laser".
///
/// The rule is one line — ask the item — and the failure is silent, because a
/// gram after a number always looks like a unit.
@MainActor
struct EveryQuantityAsksItsUnitTests {

    @Test("the sample shelf is not all grams, so a hardcoded gram is visibly wrong")
    func theShelfIsMixed() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let units = Set(shop.spools.compactMap { shop.unit(of: $0)?.unit })
        #expect(units.count >= 3, "one unit on the shelf hides every bug of this kind")
    }

    /// The spool label is what a picker shows when somebody chooses what to
    /// print from, and it is the one that would put "6g" on a stack of ply.
    @Test("a spool's own label is written in the item's unit")
    func labelUsesTheUnit() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let sheets = try #require(shop.spools.first { shop.unit(of: $0)?.unit == "sheet" })
        let said = sheets.label(shop.words, unit: shop.unit(of: sheets))
        #expect(!said.contains(shop.words.callIt("common.grams")),
                "a stack of plywood is labelled in grams: \(said)")
        #expect(said.contains(shop.words.callIt("unit.sheet")), "label reads: \(said)")

        // And a filament spool is still exactly what it was.
        let spool = try #require(shop.spools.first { shop.unit(of: $0)?.unit == "g" })
        #expect(spool.label(shop.words, unit: shop.unit(of: spool))
            .contains(shop.words.callIt("common.grams")))
    }
}
