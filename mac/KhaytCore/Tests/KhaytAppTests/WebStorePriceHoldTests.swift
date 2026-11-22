import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A live web store follows the catalogue — but never into a price the shop
/// did not set. A spool re-sized, a record merged by sync or a repair could
/// each re-price the catalogue, and the store published whatever it found.
@MainActor
struct WebStorePriceHoldTests {

    static func catalog(_ root: [String: JSONValue], engine: KhaytEngine) async throws -> JSONValue {
        try await engine.storefrontCatalog(products: Shop.rows(root, "products"),
                                     settings: .object(Shop.settings(root)), lang: "en",
                                     withPhotos: false, heroes: [:])
    }

    @Test("prices compare as prices: 50, \"50\" and \"50.0\" are one; none is none")
    func priceText() {
        #expect(CatalogPublisher.priceText(.number(50)) == "50")
        #expect(CatalogPublisher.priceText(.string("50.0")) == "50")
        #expect(CatalogPublisher.priceText(.string(" 13.74 ")) == "13.74")
        #expect(CatalogPublisher.priceText(.number(13.74)) == CatalogPublisher.priceText(.string("13.74")))
        #expect(CatalogPublisher.priceText(.string("")) == nil)
        #expect(CatalogPublisher.priceText(nil) == nil)
    }

    @Test("a re-price nobody saved is held; one the shop saved follows; adding or removing a product is not a re-price")
    func rule() {
        let published = ["A": "50", "B": "20", "C": "9"]
        let sending = ["A": "13.74", "B": "20", "D": "5"]
        #expect(CatalogPublisher.heldPrices(sending: sending, published: published, explicit: [:]) == ["A"])
        #expect(CatalogPublisher.heldPrices(sending: sending, published: published, explicit: ["A": "13.74"]).isEmpty)
        // Saved at one price, then moved again by something else: held.
        #expect(CatalogPublisher.heldPrices(sending: sending, published: published, explicit: ["A": "48"]) == ["A"])
    }

    @Test("the sample book, re-costed on a re-sized spool: an automatic publish holds every changed price")
    func repairWouldBeHeld() async throws {
        let engine = try KhaytEngine()
        let (root, sizes, ids) = try SpoolSizeRepairTests.resizedSample()
        let plan = await SpoolSizeRepairTests.plan(root, sizes: sizes, engine: engine)
        var repaired = root
        _ = Shop.applySpoolRepair(plan, to: &repaired)

        let before = try await Self.catalog(root, engine: engine)
        let after = try await Self.catalog(repaired, engine: engine)
        let published = CatalogPublisher.prices(of: before)
        let sending = CatalogPublisher.prices(of: after)
        try #require(!published.isEmpty, "the sample lists nothing on its store")
        let moved = plan.filter { $0.priceWas != $0.priceNow }.map(\.id).filter { published[$0] != nil }
        try #require(!moved.isEmpty)
        #expect(CatalogPublisher.heldPrices(sending: sending, published: published, explicit: [:]) == moved.sorted())
        // Everything else is untouched.
        for (id, price) in published where !ids.contains(id) { #expect(sending[id] == price) }

        // The shop's side: held, said once, and nothing sent.
        let shop = Shop()
        await shop.load(.sample)
        let notices = shop.moveNotices.count
        #expect(shop.holdUnsetPrices(sending: after, published: .init(live: true, prices: published)))
        #expect(shop.webStorePriceHold.map(\.id) == moved.sorted())
        #expect(shop.webStoreSaid == shop.words.callIt("mac.ws_prices_held"))
        #expect(shop.moveNotices.count == notices + 1)
        #expect(shop.holdUnsetPrices(sending: after, published: .init(live: true, prices: published)))
        #expect(shop.moveNotices.count == notices + 1, "the same held prices were announced twice")
        // The same catalogue with nothing re-priced: nothing held.
        #expect(!shop.holdUnsetPrices(sending: before, published: .init(live: true, prices: published)))
    }

    @Test("a price saved in the product sheet still follows to a live store")
    func explicitSaveFollows() async throws {
        let engine = try KhaytEngine()
        let url = try #require(Bundle.module.url(forResource: "sample-shop", withExtension: "json"))
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        let before = try await Self.catalog(root, engine: engine)
        let published = CatalogPublisher.prices(of: before)
        let id = try #require(published.keys.sorted().first)

        // The sheet saved a new price.
        var saved = root
        var rows = Shop.rows(saved, "products")
        let at = try #require(rows.firstIndex { Shop.recordId($0) == id })
        guard case .object(var p) = rows[at] else { Issue.record("shape"); return }
        p["price"] = .number(123.5)
        rows[at] = .object(p)
        saved["products"] = .array(rows)
        let after = try await Self.catalog(saved, engine: engine)

        let shop = Shop()
        await shop.load(.sample)
        // `noteExplicitPrice` reads the book as loaded; what the sheet saved is
        // stood in for here, read by the same mirror of the module's rule.
        shop.webStoreExplicitPrices[id] = CatalogPublisher.priceText(p["price"])
        #expect(!shop.holdUnsetPrices(sending: after, published: .init(live: true, prices: published)))
        #expect(shop.webStorePriceHold.isEmpty)
    }

    @Test("the mirror of the module's listed-price rule agrees with the catalogue it builds")
    func explicitMirrorMatchesModule() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        await shop.load(.sample)
        let catalog = try await engine.storefrontCatalog(products: shop.productRows, settings: shop.settingsValue,
                                                   lang: "en", withPhotos: false, heroes: [:])
        let listed = CatalogPublisher.prices(of: catalog)
        try #require(!listed.isEmpty)
        for (id, price) in listed {
            shop.noteExplicitPrice(id)
            #expect(shop.webStoreExplicitPrices[id] == price, "\(id): \(String(describing: shop.webStoreExplicitPrices[id])) vs \(price)")
        }
    }

    @Test("the hold is wired: an automatic publish checks it, the sheet lists it, the catalogue says it, a save marks its price")
    func wired() throws {
        let src = try QuoteSheetStatusTests.source("WebStore.swift")
        #expect(src.contains("if holdUnsetPrices(sending: catalog, published: now) { return .held }"))
        #expect(src.contains("case .stop, .held: return"))
        #expect(src.contains("ForEach(shop.webStorePricesHeld)"))
        let catalogue = try QuoteSheetStatusTests.source("Catalogue.swift")
        #expect(catalogue.contains("PriceHoldBanner(shop: shop)"))
        #expect(try QuoteSheetStatusTests.source("BannerParts.swift").contains("shop.webStorePricesHeld.isEmpty"))
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("noteExplicitPrice(product.id)"))
        #expect(shop.contains("for id in done { noteExplicitPrice(id) }"))
    }
}
