import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A product's own cost rates: labour once for the product, the machine rates
/// for every part (Turki, Nov 19; Figma Mac file p.18). The shared rule is
/// `lib/product-pricing.js` (#2575); its vectors run here through the engine.
@MainActor
struct ProductRatesTests {

    struct Vectors: Decodable {
        struct Case: Decodable {
            let why: String; let parts: Int; let productRates: Bool
            let labourPerPart: Bool?; let firstPartOverride: [String: JSONValue]?
            /// Per-case settings (packaging) and one part's own figures, by index.
            let settings: [String: JSONValue]?; let partOverride: [String: JSONValue]?
            let want: Want
        }
        struct Want: Decodable { let cost: Double; let labour: Double?; let equalsCalculator: Bool? }
        let settings: [String: JSONValue]
        let rates: [String: JSONValue]
        let part: [String: JSONValue]
        let cases: [Case]
    }

    static func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test/fixtures/catalogue-labour-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test("the shared catalogue-labour vectors, through the engine")
    func vectorsAgree() async throws {
        let v = try Self.vectors()
        #expect(v.cases.count >= 9)
        let engine = try KhaytEngine()
        for c in v.cases {
            var parts: [JSONValue] = []
            for i in 0..<c.parts {
                var p: [String: JSONValue] = ["name": .string("p\(i)")]
                if !c.productRates { for (k, x) in v.rates { p[k] = x } }
                for (k, x) in v.part { p[k] = x }
                if i == 0 { for (k, x) in c.firstPartOverride ?? [:] { p[k] = x } }
                if let o = c.partOverride, case .number(let at)? = o["index"], Int(at) == i {
                    for (k, x) in o where k != "index" { p[k] = x }
                }
                parts.append(.object(p))
            }
            var product: [String: JSONValue] = ["id": .string("P"), "parts": .array(parts)]
            if c.productRates { product["rates"] = .object(v.rates) }
            if c.labourPerPart == true { product["labourPerPart"] = .bool(true) }
            let r = try await engine.priceProduct(.object(product), inventory: [], settings: c.settings ?? v.settings,
                                                  consumables: [])
            #expect(r.cost == c.want.cost, Comment(rawValue: c.why))
        }
    }

    @Test("each rate goes round the sheet: typed, saved, reopened the same")
    func roundTrip() throws {
        var rest: [String: JSONValue] = [:]
        let typed = ["laborRate": "90", "prepTime": "0.25", "postTime": "0.5", "wearRate": "0.75",
                     "powerDraw": "150", "elecRate": "0.18", "failureRate": "10"]
        for (k, t) in typed { ProductRates.set(&rest, k, t) }
        #expect(ProductRates.usesOwn(rest))
        // Saved as the record the book holds, read back as the sheet opens it.
        let product = Product.from(["id": .string("P1"), "name_en": .string("Kit")].merging(rest) { $1 }, keys: [])
        let saved = product.record(keys: [])
        let reopened = Product.from(saved, keys: [])
        for (k, t) in typed {
            #expect(ProductRates.text(reopened.rest, k) == Money.fieldValue(Double(t)), Comment(rawValue: k))
        }
        // Blank is gone, not nought; the rest stay.
        var cleared = reopened.rest
        ProductRates.set(&cleared, "laborRate", "")
        #expect(ProductRates.rates(cleared)["laborRate"] == nil)
        #expect(ProductRates.text(cleared, "prepTime") == Money.fieldValue(0.25))
        // And what the save prices with carries them.
        let fields = Shop.pricingInput(for: Product.from(saved, keys: []), parts: [])
        #expect(fields["rates"] == saved["rates"])
    }

    @Test("a product costed the old way gets the first part's rates, else the shop's")
    func proposed() {
        var a = ProductSheet.PartRow(); a.rates = ["laborRate": "80", "prepTime": "0.1"]
        let b = ProductSheet.PartRow()
        let defaults = ["laborRate": "90", "prepTime": "0.25", "postTime": "0.5"]
        let fromPart = ProductRates.proposed(parts: [b, a], defaults: defaults)
        #expect(fromPart["laborRate"] == .number(80) && fromPart["prepTime"] == .number(0.1))
        #expect(fromPart["postTime"] == .number(0.5), "what the part does not say comes from the shop")
        #expect(ProductRates.proposed(parts: [b], defaults: defaults)["laborRate"] == .number(90))
    }

    @Test("the sheet: the product's own section, never the pending part's, and nothing re-priced by itself")
    func wired() {
        let src = MenuCoverageTests.source("ProductSheet.swift")
        #expect(src.contains("ProductRatesSection(shop: shop, rest: $draft.rest, record: rateRecord)"))
        #expect(src.contains("productRates: ProductRates.pricingFields(draft.rest))"))
        #expect(src.contains("if !ProductRates.usesOwn(draft.rest), !newPart.hasRates { newPart.rates = defaults }"))
        #expect(src.contains("if isNew, !ProductRates.usesOwn(draft.rest) {"), "a new product starts with its own rates")
        #expect(MenuCoverageTests.source("Shop+Settings.swift").contains("ProductRates.pricingFields(product.rest)"))
    }
}
