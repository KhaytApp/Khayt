import Foundation
import Testing
import AppKit
import KhaytCore
@testable import KhaytApp

/// The Mac publishes the catalogue to the shop's web store.
///
/// It could not before: only the desktop's Storefront dialog built and sent a
/// catalogue, so a product added on the Mac never reached the store. Every case
/// here that touches the wire runs through the `fetch` seam.
@MainActor
struct WebStoreTests {

    static let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com/",
                                                   shopId: "shop_abc_123",
                                                   storedToken: "__enc__whatever")

    static func reply(_ code: Int, _ body: String = #"{"ok":true}"#) -> (URLRequest) -> (Data, URLResponse) {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                              httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("it PUTs {catalog} to the shop's catalogue route, and nil takes the store offline")
    func theRequest() async throws {
        var seen: URLRequest?
        let catalog: JSONValue = .object(["items": .array([.object(["id": .string("P1")])])])
        try await CatalogPublisher.publish(Self.connection, token: "tok", catalog: catalog) {
            seen = $0; return Self.reply(200)($0)
        }
        let request = try #require(seen)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://cloud.khaytapp.com/v1/shops/shop_abc_123/catalog")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "x-delta-capable") == "1")
        let body = try JSONDecoder().decode([String: JSONValue].self, from: try #require(request.httpBody))
        #expect(body == ["catalog": catalog])

        try await CatalogPublisher.publish(Self.connection, token: "tok", catalog: nil) {
            seen = $0; return Self.reply(200)($0)
        }
        #expect(String(decoding: try #require(seen?.httpBody), as: UTF8.self) == #"{"catalog":null}"#)
    }

    @Test("the service's refusals come back as reasons, not a generic failure")
    func refusals() async {
        for (code, want) in [(400, CatalogPublisher.Failure.empty), (401, .unauthorised),
                             (403, .readOnly), (413, .tooLarge)] {
            await #expect(throws: want) {
                try await CatalogPublisher.publish(Self.connection, token: "tok", catalog: .null,
                                                   fetch: Self.reply(code, "{}"))
            }
        }
    }

    @Test("a 404 means no store is published; a 200 with a catalogue means it is live")
    func status() async throws {
        let off = try await CatalogPublisher.status(Self.connection, token: "tok", fetch: Self.reply(404, "{}"))
        #expect(off.live == false)
        let on = try await CatalogPublisher.status(
            Self.connection, token: "tok",
            fetch: Self.reply(200, #"{"catalog":{"items":[]},"updatedAt":"2026-09-25T10:00:00Z"}"#))
        #expect(on.live)
        #expect(on.at == (try? Date("2026-09-25T10:00:00Z", strategy: .iso8601)))
    }

    @Test("the read-back counts what Khayt Cloud holds: listings and photos")
    func heldCounts() async throws {
        let body = #"{"catalog":{"items":[{"id":"A","photos":[{"src":"x"},{"src":"y"}]},{"id":"B"}]},"updatedAt":"2026-09-25T17:57:36Z"}"#
        let held = try await CatalogPublisher.status(Self.connection, token: "tok", fetch: Self.reply(200, body))
        #expect(held.live)
        #expect(held.items == 2)
        #expect(held.photos == 2)
    }

    @Test("a publish is confirmed by reading the store back, and the answer leads the sheet")
    func confirmedByReadingBack() throws {
        let src = try QuoteSheetStatusTests.source("WebStore.swift")
        let publish = try #require(src.range(of: "func publishWebStore"))
        let after = src[publish.lowerBound...]
        let put = try #require(after.range(of: "CatalogPublisher.publish(connection, token: token, catalog: catalog)"))
        #expect(after[put.upperBound...].contains("CatalogPublisher.status("), "the outcome is not read back after the PUT")
        #expect(src.contains("accessibilityIdentifier(\"webstore-outcome\")"))
    }

    @Test("the shop page link drops a trailing slash")
    func shopPage() {
        #expect(CatalogPublisher.shopPage(Self.connection)?.absoluteString
                == "https://cloud.khaytapp.com/shop/shop_abc_123")
    }

    /// The desktop resizes to these through `KhaytProductImages`; the two apps
    /// send the same picture only while they agree.
    @Test("the picture size matches the shared module's")
    func heroSizeMatchesTheModule() throws {
        let lib = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "lib/product-images.js"), encoding: .utf8)
        #expect(lib.contains("const HERO_MAX_DIM = \(CatalogPublisher.heroMaxDim);"))
        #expect(lib.contains("const HERO_QUALITY = \(CatalogPublisher.heroQuality);"))
    }

    @Test("a large picture is sent at 1000px on its long edge, as a JPEG data URI")
    func heroIsScaled() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1000,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let file = FileManager.default.temporaryDirectory.appending(path: "webstore-\(UUID().uuidString).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let uri = try #require(CatalogPublisher.hero(file, maxDim: 1000, quality: 0.82))
        #expect(uri.hasPrefix("data:image/jpeg;base64,"))
        let data = try #require(Data(base64Encoded: String(uri.dropFirst("data:image/jpeg;base64,".count))))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 1000)
        #expect(image.pixelsHigh == 500)
        #expect(CatalogPublisher.hero(file.appending(path: "missing"), maxDim: 1000, quality: 0.82) == nil)
    }

    @Test("the catalogue is built by the shared module: price, name, and a hero over the thumbnail")
    func theCatalogue() async throws {
        let engine = try KhaytEngine()
        let thumb = "data:image/jpeg;base64," + String(repeating: "A", count: 100)
        let hero = "data:image/jpeg;base64," + String(repeating: "B", count: 4000)
        let product: JSONValue = .object([
            "id": .string("P1"), "nameEn": .string("Dragon"), "nameAr": .string("تنين"),
            "price": .number(35),
            "images": .array([.object(["id": .string("I1"), "thumbnail": .string(thumb),
                                       "path": .string("P1-I1.jpeg"), "kind": .string("render")])]),
        ])
        let unnamed: JSONValue = .object(["id": .string("P2")])
        let settings: JSONValue = .object(["contentLangs": .array([.string("en"), .string("ar")]),
                                           "currency": .string("SAR"), "bizEn": .string("Athar")])

        #expect(try await engine.storefrontCount(products: [product, unnamed], settings: settings, lang: "en") == 1)
        #expect(try await engine.storefrontHeroPaths(products: [product, unnamed], settings: settings, lang: "en")
                == ["P1-I1.jpeg"])

        let built = try await engine.storefrontCatalog(products: [product, unnamed], settings: settings, lang: "en",
                                                       withPhotos: true, heroes: ["P1-I1.jpeg": .string(hero)])
        guard case .object(let o) = built, case .array(let items)? = o["items"],
              case .object(let item)? = items.first else { Issue.record("no items"); return }
        #expect(items.count == 1)
        #expect(o["shopName"] == .string("Athar"))
        #expect(item["price"] == .string("35"))
        #expect(item["name"] == .string("Dragon"))
        guard case .array(let photos)? = item["photos"], case .object(let first)? = photos.first else {
            Issue.record("no photos"); return
        }
        #expect(first["src"] == .string(hero))

        let bare = try await engine.storefrontCatalog(products: [product], settings: settings, lang: "en",
                                                      withPhotos: false, heroes: [:])
        guard case .object(let b) = bare, case .array(let bareItems)? = b["items"],
              case .object(let bareItem)? = bareItems.first else { Issue.record("no items"); return }
        #expect(bareItem["photos"] == nil)
    }

    @Test("a shop with no cloud is not told anything about a web store")
    func noCloudSaysNothing() async {
        let shop = Shop()
        await shop.load(.sample)
        await shop.refreshWebStore()
        #expect(shop.webStoreLive == nil)
        #expect(shop.webStoreSaid == nil)
    }

    @Test("the catalogue screen offers it, and a live store follows the catalogue")
    func wired() throws {
        let catalogue = try QuoteSheetStatusTests.source("Catalogue.swift")
        #expect(catalogue.contains("WebStoreSheet(shop: shop)"))
        // The new shell draws no toolbar: the button has to be in its strip.
        let strip = try QuoteSheetStatusTests.source("ScreenActions.swift")
        #expect(strip.contains("shop.showingWebStore = true"))
        #expect(strip.contains("shop.showingOnlineOrders = true"))
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("webStoreFollow(products: productRows"))
        #expect(shop.contains("await self.refreshWebStore()"))
    }
    @Test("an automatic publish checks the store is still live, empties it rather than leave deleted products up, and a book change forgets the last store")
    func automaticGuards() throws {
        let src = try QuoteSheetStatusTests.source("WebStore.swift")
        #expect(src.contains("if automatic {"))
        #expect(src.contains("guard now.live else"))
        #expect(src.contains("mac.ws_emptied"))
        #expect(src.contains("cloudRoleCanWrite"), "a viewer's Mac follows a store it cannot publish")
        #expect(src.contains("self.source.build?.storeURL == book"))
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("resetWebStore()"))
    }

    @Test("the read-back asks past the service's 60-second cache")
    func readBackIsNotCached() async throws {
        var seen: URLRequest?
        _ = try await CatalogPublisher.status(Self.connection, token: "tok") { seen = $0; return Self.reply(404, "{}")($0) }
        #expect(seen?.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    }


    @Test("undoing a delete restores the record and does not delete it again")
    func undoDoesNotDeleteAgain() throws {
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        for name in ["deleteSupplier", "deleteProduct", "deleteSpool"] {
            #expect(!shop.contains("Task { await shop.\(name)(id) }"), "\(name)'s undo deletes the record again")
        }
        #expect(shop.contains("registerConsumableUndo(gone.was)"), "a consumable's undo cannot bring back a deleted row")
    }


    @Test("store settings: read from the book, clamped like the desktop, and nothing else in settings.storefront is touched")
    func storeSettingsRoundTrip() {
        let settings: [String: JSONValue] = ["storefront": .object([
            "note": .string("Riyadh pickup"), "depositPct": .number(20),
            "shipping": .array([.object(["label": .string("Courier"), "price": .number(25)])]),
            "prices": .object(["P1": .string("40")]),
        ])]
        var draft = StorefrontDraft(settings)
        #expect(draft.note == "Riyadh pickup")
        #expect(draft.depositPct == "20")
        #expect(draft.shipping.map(\.label) == ["Courier"])

        draft.depositPct = "150"
        draft.shipping.append(.init(label: "  ", price: "5"))
        draft.promos = [.init(code: "eid", fixed: false, value: "10"), .init(code: "ZERO", value: "0")]
        guard case .object(var sf)? = settings["storefront"] else { return }
        draft.apply(to: &sf)
        #expect(sf["depositPct"] == .number(100))
        guard case .array(let ship)? = sf["shipping"], case .array(let promos)? = sf["promos"] else {
            Issue.record("lists missing"); return
        }
        #expect(ship.count == 1, "a method with no name is kept")
        #expect(promos.count == 1, "a code worth nothing is kept")
        if case .object(let p)? = promos.first { #expect(p["code"] == .string("EID")) }
        #expect(sf["prices"] == .object(["P1": .string("40")]), "the per-product overrides were touched")
    }

    @Test("a product's web store switch is `storefrontHidden`, and absent means listed")
    func productSwitch() {
        var product = Product.from(["id": .string("P1"), "nameEn": .string("Lamp")], keys: [])
        #expect(product.onWebStore)
        product.onWebStore = false
        #expect(product.rest["storefrontHidden"] == .bool(true))
        product.onWebStore = true
        #expect(product.rest["storefrontHidden"] == nil)
    }

    @Test("the review comes from the shared module, and the product sheet has the switch and a category")
    func reviewAndSheet() async throws {
        let engine = try KhaytEngine()
        let settings: JSONValue = .object(["contentLangs": .array([.string("en"), .string("ar")])])
        let review = try await engine.storefrontReview(
            products: [.object(["id": .string("T"), "nameEn": .string("Turtle_Articulated")]),
                       .object(["id": .string("H"), "nameEn": .string("Hidden"), "storefrontHidden": .bool(true)])],
            settings: settings, lang: "en")
        #expect(review.hidden == 1)
        #expect(review.listings.first?.issues.contains("file_name") == true)
        let sheet = try QuoteSheetStatusTests.source("ProductSheet.swift")
        #expect(sheet.contains("$draft.onWebStore"))
        #expect(sheet.contains("$draft.category"))
        let words = try QuoteSheetStatusTests.source("Words.swift")
        for issue in ["no_price", "no_photo", "no_description", "no_category", "second_language", "file_name"] {
            #expect(words.contains("\"mac.ws_issue_\(issue)\""), "\(issue) has no words")
        }
    }


    @Test("the lock heartbeat gives the book up when another app has taken it")
    func heartbeatYields() throws {
        let src = try QuoteSheetStatusTests.source("StoreLock.swift")
        #expect(src.contains("static func beat(_ record: Record, for build: StoreReader.Build) -> Record?"))
        #expect(src.contains("current.pid == record.pid"))
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("mac.lock_lost"))
    }

    @Test("changes sent to the cloud are masked first, like the whole book")
    func deltasMasked() throws {
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        #expect(shop.contains("changesToSend(local: try await engine.storeForCloud(mine)"))
    }

}
