import Foundation
import Testing
@testable import KhaytCore

/// What a product is made of, against the JavaScript it came from.
///
/// These three facts leave the app: a storefront quotes delivery dates off the
/// print hours and gives the weight to a courier. A port that disagreed would
/// not be a wrong screen, it would be a wrong promise to somebody's customer.
@MainActor
struct CatalogueSpecsParityTests {

    private func js() throws -> JSModule { try JSModule(["product-specs"]) }

    private func theirs(_ js: JSModule, _ product: JSONValue) throws -> CatalogueSpecs.Specs {
        guard case .object(let o) = try js.value(
            "globalThis.KhaytProductSpecs.productSpecs(ARG0)", [product])
        else { return CatalogueSpecs.Specs(printHours: nil, weightGrams: nil, material: "«?»") }
        func num(_ v: JSONValue?) -> Double? { if case .number(let n)? = v { return n }; return nil }
        var material = "«not a string»"
        if case .string(let s)? = o["material"] { material = s }
        return CatalogueSpecs.Specs(printHours: num(o["printHours"]),
                                    weightGrams: num(o["weightGrams"]),
                                    material: material)
    }

    private func check(_ product: JSONValue, _ what: String, _ js: JSModule) throws {
        // Both sides hoisted: a `try` inside the comment's interpolation lands
        // in the macro's non-throwing autoclosure and will not compile.
        let mine = CatalogueSpecs.specs(of: product)
        let theirs = try theirs(js, product)
        #expect(mine == theirs,
                Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    private func part(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
    private func product(_ parts: [JSONValue]) -> JSONValue { .object(["parts": .array(parts)]) }

    @Test("a real multi-part product")
    func realProduct() throws {
        let js = try js()
        try check(product([
            part(["material": .string("PETG"), "printWeight": .number(180.5),
                  "supportWeight": .number(12), "printTime": .number(4.25), "qty": .number(2)]),
            part(["material": .string("TPU"), "printWeight": .number(40),
                  "printTime": .number(1.5), "qty": .number(1)]),
        ]), "a lamp", js)
    }

    @Test("a product with nothing in it answers nothing, not zero")
    func emptyIsNull() throws {
        let js = try js()
        for p in [product([]), .object([:]), .object(["parts": .null]),
                  .object(["parts": .string("x")]), .object(["parts": .object([:])]),
                  .null, .string("x"), .number(1), .array([])] {
            try check(p, "empty \(p)", js)
        }
        // Said outright: a product with no parts is not one that prints
        // instantly, and a consumer deciding whether it can quote a date has
        // to tell those apart.
        #expect(CatalogueSpecs.specs(of: product([])).printHours == nil)
        #expect(CatalogueSpecs.specs(of: product([])).weightGrams == nil)
    }

    @Test("a part with no quantity counts once, and a zero quantity does too")
    func quantityFallsBackToOne() throws {
        let js = try js()
        for qty in [JSONValue.null, .number(0), .number(-1), .number(1), .number(3),
                    .number(2.5), .string("2"), .string(""), .bool(true), .array([]),
                    .object([:])] {
            try check(product([part(["printWeight": .number(10), "printTime": .number(1),
                                     "qty": qty])]), "qty \(qty)", js)
        }
    }

    @Test("prep and post time are not print time")
    func onlyPrintTimeCounts() throws {
        // Counting them here would add finishing twice: `lead-time` already
        // publishes it as handlingDays, and every quoted date would drift
        // later — silently, in the direction that loses work.
        let js = try js()
        let p = product([part(["printTime": .number(2), "prepTime": .number(5),
                               "postTime": .number(9), "qty": .number(1)])])
        try check(p, "prep and post present", js)
        #expect(CatalogueSpecs.specs(of: p).printHours == 2)
    }

    @Test("materials are distinct, in the order the shop listed them")
    func materialOrderHolds() throws {
        // "PETG, TPU" is what somebody packing it reads. A set alone reorders.
        let js = try js()
        try check(product([
            part(["material": .string("TPU")]), part(["material": .string("PETG")]),
            part(["material": .string("TPU")]), part(["material": .string("  PETG  ")]),
            part(["material": .string("")]), part(["material": .string("   ")]),
            part([:]), part(["material": .null]),
        ]), "repeats and blanks", js)
        let said = CatalogueSpecs.specs(of: product([
            part(["material": .string("TPU")]), part(["material": .string("PETG")]),
            part(["material": .string("TPU")])])).material
        #expect(said == "TPU, PETG", Comment(rawValue: said))
    }

    @Test("a material that is not a string")
    func oddMaterials() throws {
        let js = try js()
        try check(product([part(["material": .number(7)]), part(["material": .bool(true)]),
                           part(["material": .array([.string("a"), .string("b")])]),
                           part(["material": .object([:])])]), "odd materials", js)
    }

    @Test("weights and times that are not numbers")
    func oddFigures() throws {
        let js = try js()
        // `Awkward.numbers` includes `greatestFiniteMagnitude`, which two
        // parts sum past into infinity — and JSON cannot carry that, so the
        // bridge has always delivered null. The port has to agree.
        for value in Awkward.notNumbers + Awkward.numbers.map({ JSONValue.number($0) }) {
            try check(product([part(["printWeight": value, "printTime": value,
                                     "supportWeight": value, "qty": .number(2)])]),
                      "every figure = \(value)", js)
        }
    }

    @Test("the rounding lands on the same digit")
    func roundingMatches() throws {
        // Four places for hours because a 12-minute part is 0.2 h and must not
        // round to nothing; two for grams. Both are `Math.round`, whose halves
        // go UP rather than away from zero.
        let js = try js()
        for hours in [0.00005, 0.000049, 0.00015, 0.2, 1.00005, 2.67895, 1.0 / 3.0,
                      8.325, 1e-7, 1e-5, 123456.98765] {
            try check(product([part(["printTime": .number(hours), "qty": .number(1)])]),
                      "hours \(hours)", js)
        }
        for grams in [0.005, 0.0049, 0.015, 2.675, 1.005, 180.555, 1e-3, 1.0 / 3.0] {
            try check(product([part(["printWeight": .number(grams), "qty": .number(1)])]),
                      "grams \(grams)", js)
        }
    }

    @Test("a part that is not an object")
    func degenerateParts() throws {
        let js = try js()
        try check(product([.null, .string("x"), .number(3), .array([]), .bool(true),
                           part(["printTime": .number(1), "printWeight": .number(5)])]),
                  "a mix of nonsense and one real part", js)
    }
}
