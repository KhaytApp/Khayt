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
                                  "spoolCost": .number(110), "spoolWeight": .number(1000), "qty": .number(3)])]),
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
