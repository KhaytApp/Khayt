import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the shop sells, and what it costs.
///
/// Not the print library — that is the files. This is the catalogue, and on
/// this book it feeds the storefront, which is why the price shown has to be
/// the one `lib/product-price.js` computes rather than whatever number is
/// nearest to hand.
///
/// The first fixture is this shop's own product record: the King Abdulaziz
/// portrait, `basePrice: 46.69` with `priceRound: {step: 5, mode: "up"}`.
@MainActor
struct CatalogueTests {

    static func product(_ fields: [String: JSONValue]) -> JSONValue {
        var row = fields
        row["id"] = row["id"] ?? .string("PROD-1")
        return .object(row)
    }

    // MARK: - The price, and why

    @Test("the real product rounds up to its step")
    func realProduct() async throws {
        let price = try await KhaytEngine().productPrice(
            Self.product(["basePrice": .number(46.69),
                          "priceRound": .object(["step": .number(5), "mode": .string("up")])]),
            basePrice: 46.69)
        #expect(price.base == 46.69)
        #expect(price.final == 50)
        #expect(price.source == "rounded")
    }

    @Test("a typed price of ZERO is a price, not an absent one")
    func zeroOverride() async throws {
        // A giveaway, a sample, a part priced inside a bundle. Treating 0 as
        // absent would silently re-price free items at cost plus margin — the
        // module says so, and it is the kind of thing a Swift `?? ` would undo.
        let price = try await KhaytEngine().productPrice(
            Self.product(["priceOverride": .number(0),
                          "priceRound": .object(["step": .number(5), "mode": .string("up")])]),
            basePrice: 100)
        #expect(price.final == 0)
        #expect(price.source == "override", "an override beats rounding")
    }

    @Test("no rounding set leaves the calculated figure alone")
    func noRounding() async throws {
        let price = try await KhaytEngine().productPrice(Self.product([:]), basePrice: 46.69)
        #expect(price.final == 46.69)
        #expect(price.source == "base")
    }

    /// Driven through the real products, not through hand-built rows.
    ///
    /// It used to construct a `CatalogueRow` with the fields it wanted and check
    /// the Swift that read them, which proved only that the test and the Swift
    /// agreed — and they would have gone on agreeing if `describe` in the module
    /// had changed its mind. The reason now comes from the module, so the test
    /// has to come from a product.
    @Test("why a price is what it is comes from the module, for real products")
    func priceReason() async throws {
        let engine = try KhaytEngine()
        let round = JSONValue.object(["step": .number(5), "mode": .string("up")])
        let rows = try await engine.catalogue([
            // Rounded, and it moved: 46.69 → 50.
            Self.product(["id": .string("moved"), "basePrice": .number(46.69),
                          "priceRound": round]),
            // Rounded, and it did not move. Saying "rounded" of an identical
            // figure is noise, and the module is where that is decided.
            Self.product(["id": .string("unmoved"), "basePrice": .number(50),
                          "priceRound": round]),
            // A typed price beats everything, rounding included.
            Self.product(["id": .string("typed"), "basePrice": .number(46.69),
                          "priceOverride": .number(41), "priceRound": round]),
            // Nothing set at all.
            Self.product(["id": .string("plain"), "basePrice": .number(46.69)]),
        ], language: "en", settings: [:])

        let reason = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.reason) })
        #expect(reason["moved"] == "pe.price_is_rounded")
        #expect(reason["unmoved"] == "pe.price_is_base")
        #expect(reason["typed"] == "pe.price_is_override")
        #expect(reason["plain"] == "pe.price_is_base")
        // And the screen shows what the row carries, rather than deciding again.
        for row in rows { #expect(Catalogue.reason(row) == row.reason) }
    }

    /// Every key the module can choose must be a key this app can say. A reason
    /// that reaches the screen untranslated reads as `pe.price_is_rounded`.
    @Test("every reason the module returns is a word this app knows")
    func everyReasonIsTranslated() async throws {
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        for key in ["pe.price_is_base", "pe.price_is_rounded", "pe.price_is_override"] {
            #expect(words.callIt(key) != key, "\(key) reaches the screen as its own key")
        }
    }

    /// The reason a price is what it is has to READ, not just resolve.
    ///
    /// "Rounded from" is a prefix in all nine languages, and this screen showed
    /// it with nothing after it — nineteen catalogue rows naming a figure they
    /// never printed. `everyReasonIsTranslated` above passed throughout: the key
    /// resolved to a word, and the word was half a sentence.
    ///
    /// So the test is not "is it translated" but "does it name the number".
    @Test("a rounded price says which figure it was rounded from")
    func roundedNamesTheBasePrice() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        let round = JSONValue.object(["step": .number(5), "mode": .string("up")])
        let rows = try await engine.catalogue([
            Self.product(["id": .string("moved"), "basePrice": .number(46.69),
                          "priceRound": round]),
            Self.product(["id": .string("unmoved"), "basePrice": .number(50),
                          "priceRound": round]),
            Self.product(["id": .string("typed"), "basePrice": .number(46.69),
                          "priceOverride": .number(41), "priceRound": round]),
        ], language: "en", settings: [:])
        let line = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, Catalogue.reasonLine($0, words, currency: "SAR"))
        })

        // 46.69 rounded up to a step of 5 is 50, and the row must say where the
        // 50 came from.
        #expect(line["moved"]?.contains("46.69") == true,
                "a rounded price does not name the calculated figure: \(line["moved"] ?? "")")
        #expect(line["moved"]?.hasPrefix(words.callIt("pe.price_is_rounded")) == true)

        // The other two are whole sentences already. Appending a figure to
        // "Your own price" would print the price twice.
        #expect(line["unmoved"] == words.callIt("pe.price_is_base"))
        #expect(line["typed"] == words.callIt("pe.price_is_override"))
    }

    // MARK: - What its parts add up to

    @Test("hours, grams and the materials come from the parts")
    func specs() async throws {
        let specs = try await KhaytEngine().productSpecs(Self.product(["parts": .array([
            .object(["printWeight": .number(120), "supportWeight": .number(5),
                     "printTime": .number(2.5), "qty": .number(2), "material": .string("PLA")]),
            .object(["printWeight": .number(10), "qty": .number(1), "material": .string("PETG")]),
        ])]))
        #expect(specs.weightGrams == 260)
        #expect(specs.printHours == 5)
        // Distinct, in the order the shop listed them: "PLA, PETG" is what
        // somebody packing it needs to read.
        #expect(specs.material == "PLA, PETG")
    }

    @Test("a product with no parts has no specs rather than zeroes")
    func noParts() async throws {
        let specs = try await KhaytEngine().productSpecs(Self.product([:]))
        #expect(specs.weightGrams == nil)
        #expect(specs.printHours == nil)
        #expect(specs.material == "")
    }

    // MARK: - The row

    @Test("the name is read in the shop's language, like everywhere else")
    func nameIsLocalised() async throws {
        // Same rule as the customers table, and for the same reason — one book
        // must not be shown two answers about what something is called.
        let rows = try await KhaytEngine().catalogue([
            Self.product(["nameEn": .string("Portrait of King Abdulaziz"),
                          "nameAr": .string("صورة الملك عبدالعزيز")]),
        ], language: "ar", settings: ["contentLangs": .array([.string("ar"), .string("en")])])
        #expect(rows.first?.name == "صورة الملك عبدالعزيز")
    }

    @Test("one crossing gives the name, the price and the specs together")
    func oneCrossing() async throws {
        let rows = try await KhaytEngine().catalogue([
            Self.product(["nameEn": .string("Kings"), "basePrice": .number(46.69),
                          "defaultMargin": .number(30),
                          "priceRound": .object(["step": .number(5), "mode": .string("up")]),
                          "parts": .array([.object(["printWeight": .number(100),
                                                    "qty": .number(1),
                                                    "material": .string("PLA+")])])]),
        ], language: "en", settings: [:])
        guard let row = rows.first else { Issue.record("no row"); return }
        #expect(row.name == "Kings")
        #expect(row.final == 50)
        #expect(row.margin == 30)
        #expect(row.weightGrams == 100)
        #expect(row.material == "PLA+")
        #expect(row.parts == 1)
    }

    @Test("a missing margin sorts as absent, not as zero")
    func missingMarginSorts() {
        // A product with no margin set is not the cheapest.
        let none = KhaytEngine.CatalogueRow(
            id: "A", name: "A", description: "", base: 0, final: 0, source: "base",
            reason: "pe.price_is_base", margin: nil, printHours: nil, weightGrams: nil,
            material: "", parts: 0)
        let zero = KhaytEngine.CatalogueRow(
            id: "B", name: "B", description: "", base: 0, final: 0, source: "base",
            reason: "pe.price_is_base", margin: 0, printHours: nil, weightGrams: 0,
            material: "", parts: 0)
        #expect(none.marginSort < zero.marginSort)
        #expect(none.weightSort < zero.weightSort)
    }
}
