import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The catalogue counts each part's quantity, as a job from the product does —
/// and no product already in a book changes price because of it.
///
/// `lib/product-pricing.js` costed a part ×3 as ONE piece: a stand at 19.80 a
/// piece listed at 19.80 / 25.74 while a job taken from it came to
/// 59.40 / 77.22. The rule now counts the quantity. A product saved under the
/// old rule keeps the price it was saved at until the shop opens it, edits
/// what it is priced from and saves — the sheet showing the new figure.
@MainActor
struct CataloguePartQtyTests {

    /// The portrait part (`CataloguePriceFidelityTests`) — every rate on it,
    /// so the job path's `costPart` and the catalogue cost it alike.
    static func part(qty: Int) -> [String: JSONValue] {
        var p = CataloguePriceFidelityTests.portraitPart
        p["qty"] = .number(Double(qty))
        return p
    }

    /// A job taken from `product` the Mac's way: each part costed by
    /// `costPart` through the draft the new-job sheet holds, frozen by
    /// `Shop.partRows` (piece cost × qty), with the product's components and
    /// `assemblyQty`, at its margin.
    static func jobPrice(_ product: [String: JSONValue], engine: KhaytEngine,
                         consumables: [JSONValue]) async throws -> (price: Double, cost: Double) {
        var drafts: [NewJobSheet.Draft] = []
        if case .array(let rows)? = product["parts"] {
            for row in rows {
                var draft = try #require(NewJobSheet.Draft.from(row))
                let input = Shop.costInput(spool: CataloguePriceFidelityTests.spool,
                                           grams: Double(draft.grams) ?? 0, hours: Double(draft.hours) ?? 0,
                                           qty: draft.qty, extra: draft.raw)
                draft.cost = try await engine.costPart(input, inventory: CataloguePriceFidelityTests.shelf,
                                                       settings: [:]).cost
                drafts.append(draft)
            }
        }
        var input: [String: JSONValue] = [
            "parts": .array(Shop.partRows(drafts, spools: [CataloguePriceFidelityTests.spool], unnamed: "Part")),
            "margin": product["defaultMargin"] ?? .number(30),
        ]
        if let c = product["components"] { input["components"] = c }
        if let q = product["assemblyQty"] { input["assemblyQty"] = q }
        let out = try await engine.newOrder(
            input, orders: [], settings: [:], now: Date(),
            tokens: (tracking: Array(repeating: 7, count: 16), quoteApproval: Array(repeating: 9, count: 16)),
            consumables: consumables)
        guard case .object(let order) = out.order, case .number(let price)? = order["price"] else {
            Issue.record("no order"); return (0, 0)
        }
        var cost = 0.0
        if case .array(let parts)? = order["parts"] {
            for case .object(let p) in parts { if case .number(let c)? = p["baseCost"] { cost += c } }
        }
        if case .number(let c)? = order["componentsCost"] { cost += c }
        return (price, cost)
    }

    @Test("the catalogue and a job from the product agree: qty 1, qty 3, components, assemblyQty")
    func catalogueEqualsJob() async throws {
        let engine = try KhaytEngine()
        let consumables: [JSONValue] = [.object(["id": .string("C2"), "cost": .number(1.5)])]
        let components: JSONValue = .array([.object(["consumableId": .string("C2"), "qtyPerUnit": .number(4)])])
        let shapes: [(String, [String: JSONValue])] = [
            ("qty 1", ["defaultMargin": .number(30), "parts": .array([.object(Self.part(qty: 1))])]),
            ("qty 3", ["defaultMargin": .number(30), "parts": .array([.object(Self.part(qty: 3))])]),
            ("two parts", ["defaultMargin": .number(40),
                           "parts": .array([.object(Self.part(qty: 3)), .object(Self.part(qty: 2))])]),
            ("components", ["defaultMargin": .number(30), "parts": .array([.object(Self.part(qty: 3))]),
                            "components": components]),
            ("assemblyQty 2", ["defaultMargin": .number(35), "parts": .array([.object(Self.part(qty: 3))]),
                               "components": components, "assemblyQty": .number(2)]),
        ]
        for (name, product) in shapes {
            let listed = try await engine.priceProduct(.object(product), inventory: CataloguePriceFidelityTests.shelf,
                                                       settings: [:], consumables: consumables)
            let job = try await Self.jobPrice(product, engine: engine, consumables: consumables)
            #expect(abs(listed.price - job.price) < 0.005,
                    Comment(rawValue: "\(name): catalogue \(listed.price) vs job \(job.price)"))
            #expect(abs(listed.cost - job.cost) < 0.005,
                    Comment(rawValue: "\(name): catalogue cost \(listed.cost) vs job \(job.cost)"))
        }
    }

    /// A product part saved WITHOUT its labour and wear — a part made by an
    /// older build, an import, the sample book's. A job taken from it is costed
    /// by `costPart`, which fills the shop's default for every rate the part
    /// never carried; the catalogue (`lib/product-pricing.js`) used to hold
    /// those at zero, so the product listed at its filament and the job opened
    /// at filament plus 90 an hour. Both go through `KhaytPrintRates.withRates`.
    static let rateless: [String: JSONValue] = [
        "name": .string("Stand"), "material": .string("PLA"),
        "spoolCost": .number(110), "spoolWeight": .number(1000),
        "printWeight": .number(180), "printTime": .number(2), "qty": .number(2),
        "prepTime": .number(0.25), "laborRate": .null,
    ]

    @Test("a part with no labour or wear costs the same in the catalogue and in a job taken from it")
    func ratelessPartAgrees() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        var part = Self.rateless
        part.removeValue(forKey: "laborRate")      // never said: the default
        let product = Product(id: "PROD-rateless", names: ["en": "Stand"], descriptions: [:],
                              margin: 30, group: "", category: "", createdAt: "2026-10-22",
                              rest: ["parts": .array([.object(part)])])
        let drafts = await shop.jobParts(from: product)
        let draft = try #require(drafts.first)
        let listed = try await engine.priceProduct(
            .object(["defaultMargin": .number(30), "parts": .array([.object(part)])]),
            inventory: shop.inventoryRows, settings: shop.settingsDict, consumables: shop.consumableRows)
        #expect(abs(draft.cost * Double(draft.qty) - listed.cost) < 0.005,
                Comment(rawValue: "job \(draft.cost) x \(draft.qty) vs catalogue \(listed.cost)"))
        // And it is the defaults that filled the gap, not zero: 180 g at 0.11
        // is 19.80 a piece, so a catalogue at material alone would say 39.60.
        let rates = try #require(draft.rates)
        #expect(rates.prepTime == 0.25, "the part's own prep time was overridden")
        #expect(rates.laborRate == 90 && rates.wearRate == 0.75)
        #expect(listed.cost > 39.6 + 1, Comment(rawValue: "catalogue \(listed.cost)"))

        // A rate the part DID write down is kept — a null included, which the
        // cost model reads as zero on both paths.
        let saidNull = try await engine.costPart(.object(Self.rateless), inventory: [], settings: [:])
        #expect(saidNull.rates.laborRate == 0)
        let listedNull = try await engine.priceProduct(
            .object(["defaultMargin": .number(30), "parts": .array([.object(Self.rateless)])]),
            inventory: [], settings: [:], consumables: [])
        #expect(abs(saidNull.cost * 2 - listedNull.cost) < 0.005,
                Comment(rawValue: "job \(saidNull.cost) x 2 vs catalogue \(listedNull.cost)"))
    }

    @Test("a part that never named a spool keeps its spool cost through the sheet; one whose spool was removed loses it")
    func recordKeepsUnlinkedSpoolCost() throws {
        let raw: [String: JSONValue] = ["name": .string("Bracket"), "material": .string("PETG"),
                                        "printWeight": .number(200), "printTime": .number(3),
                                        "spoolCost": .number(100), "spoolWeight": .number(750), "qty": .number(1)]
        var row = try #require(ProductSheet.PartRow.from(.object(raw)))
        row.grams = "250"
        guard case .object(let saved) = row.record(spools: []) else { Issue.record("not an object"); return }
        #expect(saved["spoolCost"] == .number(100), "the part's own spool cost was dropped")
        #expect(saved["spoolWeight"] == .number(750))
        #expect(saved["material"] == .string("PETG"))
        #expect(saved["printWeight"] == .number(250))
        // Taking a linked spool off still takes its figures with it.
        var linked = try #require(ProductSheet.PartRow.from(.object(CataloguePriceFidelityTests.portraitPart)))
        linked.spoolId = nil
        guard case .object(let bare) = linked.record(spools: [CataloguePriceFidelityTests.spool]) else {
            Issue.record("not an object"); return
        }
        #expect(bare["spoolCost"] == nil && bare["filamentId"] == nil)
    }

    @Test("the sheet shows an old ×3 product's SAVED price and today's beside it; an up-to-date one says nothing")
    func sheetSaysTheSavedPrice() async throws {
        let engine = try KhaytEngine()
        // Every rate said, and said zero, so the figures are the filament's alone.
        var stand: [String: JSONValue] = ["name": .string("Stand"), "printWeight": .number(180), "printTime": .number(2),
                                          "spoolCost": .number(110), "spoolWeight": .number(1000), "qty": .number(3)]
        for key in ProductSheet.PartRow.rateKeys { stand[key] = .number(0) }
        let live = try await engine.priceProduct(.object(["defaultMargin": .number(30), "parts": .array([.object(stand)])]),
                                                 inventory: [], settings: [:], consumables: [])
        #expect(live.price == 77.22)
        let words = Words()
        await words.load("en", engine: nil)

        // Saved at 25.74 under the one-piece rule, opened and not edited.
        let note = try #require(ProductSheet.savedPriceNote(stored: 25.74, opened: live, live: live, words: words))
        #expect(note == "Saved price kept; today's costs give 77.22", Comment(rawValue: note))
        #expect(ProductSheet.shownPrice(stored: 25.74, opened: live, live: live) == 25.74,
                "the sheet showed a price an untouched save does not write")

        // Up to date: nothing to say, and the price is the price.
        #expect(ProductSheet.savedPriceNote(stored: 77.22, opened: live, live: live, words: words) == nil)
        #expect(ProductSheet.shownPrice(stored: 77.22, opened: live, live: live) == 77.22)

        // Edited: the save re-prices, so the sheet shows what it will write.
        var heavier = stand; heavier["printWeight"] = .number(190)
        let edited = try await engine.priceProduct(.object(["defaultMargin": .number(30), "parts": .array([.object(heavier)])]),
                                                   inventory: [], settings: [:], consumables: [])
        #expect(ProductSheet.savedPriceNote(stored: 25.74, opened: live, live: edited, words: words)
                == "was 25.74 → now \(Money.figure(edited.price))")
        // Edited back to exactly what is stored: nothing moves, nothing said.
        #expect(ProductSheet.savedPriceNote(stored: edited.price, opened: live, live: edited, words: words) == nil)
        #expect(ProductSheet.shownPrice(stored: 25.74, opened: live, live: edited) == edited.price)

        // A new product has nothing saved.
        #expect(ProductSheet.savedPriceNote(stored: nil, opened: nil, live: live, words: words) == nil)
        #expect(ProductSheet.shownPrice(stored: nil, opened: nil, live: live) == 77.22)

        // In Arabic too, in Western digits.
        let arabic = Words()
        await arabic.load("ar", engine: nil)
        #expect(ProductSheet.savedPriceNote(stored: 25.74, opened: live, live: live, words: arabic)
                == "أُبقي السعر المحفوظ؛ تكاليف اليوم تعطي 77.22")

        // Both languages say it, with both figures in.
        for lang in ["en", "ar"] {
            #expect(Words.own["mac.price_kept"]?[lang]?.contains("{now}") == true, Comment(rawValue: lang))
            let wasNow = try #require(Words.own["mac.price_was_now"]?[lang])
            #expect(wasNow.contains("{was}") && wasNow.contains("{now}"), Comment(rawValue: lang))
        }
    }

    @Test("the sheet prices the components with the product's assemblyQty, as the save does")
    func sheetAndSaveAgree() {
        let product = Product.from(["id": .string("P"), "nameEn": .string("P"), "assemblyQty": .number(2),
                                    "components": .array([])], keys: [])
        let input = Shop.pricingInput(for: product, parts: [])
        #expect(input["assemblyQty"] == .number(2), "the save priced one set of components per product")
    }
}

/// The book-opening half: in the serialised suite that owns the test folder.
extension LibraryEditPerfTests {

    /// A stand ×3 saved under the one-piece rule: 19.80 cost, 25.74 price.
    static let oldQtyProduct: [String: JSONValue] = [
        "id": .string("PQ3"), "nameEn": .string("Stand"), "defaultMargin": .number(30), "rev": .number(1),
        "baseCost": .number(19.8), "basePrice": .number(25.74), "price": .number(25.74),
        "parts": .array([.object(["name": .string("Stand"), "filamentId": .string("SP1"), "material": .string("PLA"),
                                  "printWeight": .number(180), "printTime": .number(2),
                                  "spoolCost": .number(110), "spoolWeight": .number(1000), "qty": .number(3),
                                  // Every rate said, and said zero: the filament alone.
                                  "wearRate": .number(0), "powerDraw": .number(0), "elecRate": .number(0),
                                  "prepTime": .number(0), "postTime": .number(0), "laborRate": .number(0),
                                  "failureRate": .number(0)])]),
    ]

    /// The spool the stand is printed from, at the price it was costed with —
    /// the sheet re-reads a part's spool cost off the shelf.
    static let standSpool: JSONValue = .object([
        "id": .string("SP1"), "material": .string("PLA"), "cost": .number(110), "weight": .number(1000),
        "spoolWeight": .number(1000),
    ])

    static func diskProduct(_ url: URL, _ id: String) throws -> [String: JSONValue]? {
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        for row in Shop.rows(root, "products") {
            if case .object(let o) = row, o["id"] == .string(id) { return o }
        }
        return nil
    }

    /// Open the product on its sheet and press Save, with `edit` applied first.
    static func saveFromSheet(_ shop: Shop, _ id: String,
                              edit: (inout ProductSheet.Opened) -> Void = { _ in }) async throws {
        let opened = try #require(await shop.productForEditing(id))
        var sheet = ProductSheet.opening(opened)
        edit(&sheet)
        let sent = ProductSheet.payload(sheet, spools: shop.spools, reclaimsTax: shop.reclaimsTax)
        await shop.saveProduct(sent.product, parts: sent.parts, tiers: sent.tiers, docs: sent.docs,
                               opened: opened)
        #expect(shop.moveProblem == nil, Comment(rawValue: shop.moveProblem ?? ""))
    }

    @Test("a qty-3 product priced under the old rule keeps its price through load, reload and an untouched save")
    func oldPriceSurvives() async throws {
        var book = PerfBook.synthesize(models: 5)
        book["products"] = .array([.object(Self.oldQtyProduct)])
        book["inventory"] = .array([Self.standSpool])
        try await withPerfBook(book) { shop, url in
            // Opening the book wrote nothing to it.
            #expect(try Self.diskProduct(url, "PQ3") == Self.oldQtyProduct, "loading the book re-priced the product")
            await shop.load(shop.source)
            #expect(try Self.diskProduct(url, "PQ3") == Self.oldQtyProduct, "a reload re-priced the product")
            // The spool-size repair has nothing to offer for it.
            #expect(Shop.spoolRepairCount(products: shop.productRows, sizes: shop.spoolSizes) == 0)

            // Opened and saved with nothing changed: the stored price stands.
            try await Self.saveFromSheet(shop, "PQ3")
            var saved = try #require(try Self.diskProduct(url, "PQ3"))
            #expect(saved["price"] == .number(25.74), Comment(rawValue: "untouched save priced it at \(String(describing: saved["price"]))"))
            #expect(saved["basePrice"] == .number(25.74))
            #expect(saved["baseCost"] == .number(19.8))

            // A name edit is not a price edit.
            try await Self.saveFromSheet(shop, "PQ3") { $0.draft.names["en"] = "Tall stand" }
            saved = try #require(try Self.diskProduct(url, "PQ3"))
            #expect(saved["nameEn"] == .string("Tall stand"))
            #expect(saved["price"] == .number(25.74), "renaming the product moved its price")

            // Editing what it is priced FROM prices it — all three pieces.
            try await Self.saveFromSheet(shop, "PQ3") { $0.parts[0].grams = "190" }
            saved = try #require(try Self.diskProduct(url, "PQ3"))
            #expect(saved["baseCost"] == .number(62.7), Comment(rawValue: "190 g × 0.11 × 3, got \(String(describing: saved["baseCost"]))"))
            #expect(saved["price"] == .number(81.51), Comment(rawValue: "\(String(describing: saved["price"]))"))
        }
    }

    /// A part with its own spool cost and no spool on the shelf — typed in the
    /// other app, or imported — with rates of its own.
    static let unlinkedProduct: [String: JSONValue] = [
        "id": .string("PNS"), "nameEn": .string("Bracket"), "defaultMargin": .number(30), "rev": .number(1),
        "baseCost": .number(20), "basePrice": .number(26), "price": .number(26),
        "parts": .array([.object(["name": .string("Bracket"), "material": .string("PETG"),
                                  "printWeight": .number(200), "printTime": .number(3),
                                  "spoolCost": .number(100), "spoolWeight": .number(1000),
                                  "supportWeight": .number(0), "qty": .number(1),
                                  "laborRate": .number(0), "failureRate": .number(0),
                                  "wearRate": .number(0), "powerDraw": .number(0), "elecRate": .number(0),
                                  "prepTime": .number(0), "postTime": .number(0)])]),
    ]

    @Test("a part with its own spool cost and no spool keeps it: untouched save is a no-op, a grams edit prices with it")
    func unlinkedPartKeepsItsSpoolCost() async throws {
        var book = PerfBook.synthesize(models: 5)
        book["products"] = .array([.object(Self.unlinkedProduct)])
        try await withPerfBook(book) { shop, url in
            try await Self.saveFromSheet(shop, "PNS")
            let untouched = try #require(try Self.diskProduct(url, "PNS"))
            let changed = Set(untouched.keys).union(Self.unlinkedProduct.keys)
                // Every save stamps the record; that is a save, not an edit.
                .subtracting(["rev", "updatedAt"])
                .filter { untouched[$0] != Self.unlinkedProduct[$0] }.sorted()
            #expect(changed.isEmpty, Comment(rawValue: "an untouched save changed \(changed): \(changed.map { "\($0)=\(String(describing: untouched[$0]))" })"))

            try await Self.saveFromSheet(shop, "PNS") { $0.parts[0].grams = "250" }
            let saved = try #require(try Self.diskProduct(url, "PNS"))
            // 250 g at 100 a kilo is 25.00; plus 30% is 32.50.
            #expect(saved["baseCost"] == .number(25), Comment(rawValue: "\(String(describing: saved["baseCost"]))"))
            #expect(saved["price"] == .number(32.5), Comment(rawValue: "\(String(describing: saved["price"]))"))
            guard case .array(let parts)? = saved["parts"], case .object(let part)? = parts.first else {
                Issue.record("no part"); return
            }
            #expect(part["printWeight"] == .number(250))
            for key in ["spoolCost", "spoolWeight", "material", "laborRate", "failureRate"] {
                #expect(part[key] == Self.unlinkedProduct.partField(key), Comment(rawValue: "\(key) was dropped or changed"))
            }
        }
    }

    @Test("the catalogue's per-hour figure reads the qty-3 product's real cost, beside its stored price")
    func perHourShowsTheLoss() async throws {
        var book = PerfBook.synthesize(models: 5)
        book["products"] = .array([.object(Self.oldQtyProduct)])
        try await withPerfBook(book) { shop, url in
            let engine = try KhaytEngine()
            let report = try await engine.profitPerHour(
                products: shop.productRows, orders: [], expenses: [], inventory: [], consumables: [],
                settings: [:], clients: [], language: "en")
            let row = try #require(report.rows.first { $0.productId == "PQ3" })
            #expect(row.price == 25.74)
            #expect(row.cost == 59.4, Comment(rawValue: "cost \(String(describing: row.cost))"))
            #expect((row.profit ?? 0) < 0, "a loss read as a margin")
            #expect(try Self.diskProduct(url, "PQ3") == Self.oldQtyProduct, "reporting on it wrote to it")
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    /// A field of the first part, for comparing a saved part with the one it was.
    func partField(_ key: String) -> JSONValue? {
        guard case .array(let parts)? = self["parts"], case .object(let p)? = parts.first else { return nil }
        return p[key]
    }
}
