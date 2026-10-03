import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A live web store follows the catalogue — and now it actually does.
///
/// `resetWebStore()` ran on EVERY load, a few lines after `webStoreFollow`, so
/// the republish the follow had just scheduled was cancelled during its 4 s
/// wait and the store was forgotten as live. A change to the book IS a load, so
/// no change ever reached the store on its own. These run the real `load`, with
/// the network stood in for by `webStoreAutoPublish`.
@MainActor
struct WebStoreFollowTests {

    /// Short enough to wait out. Not compared with how long a load takes: on a
    /// loaded CI runner the follow may fire before `load` returns.
    static let delay: Duration = .milliseconds(1500)

    final class Count { var fired = 0; var sent = 0 }

    /// The sample book, read once, its store live, publishes counted.
    static func liveShop(_ count: Count,
                         publish: (@MainActor (Shop) async -> Void)? = nil) async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.webStoreFollowDelay = delay
        shop.webStoreAutoPublish = publish ?? { _ in count.fired += 1 }
        shop.webStoreLive = true
        return shop
    }

    /// Wait until `done`, or give up after `seconds`.
    static func wait(_ seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// What the book was read as before it changed. Any value the load will
    /// not produce stands in for the catalogue as it was.
    static let before: JSONValue = .object(["products": .array([]), "storefront": .null])

    @Test("a change to the book republishes a live store once, after the wait")
    func changeRepublishes() async {
        let count = Count()
        let shop = await Self.liveShop(count)
        shop.webStoreSeen = Self.before
        // The book as changed: re-read, as the app does after any write.
        await shop.load(.sample)
        #expect(shop.webStoreLive == true, "the reload forgot the store was live")
        #expect(shop.webStoreRepublish != nil, "the reload cancelled the follow it had scheduled")
        await Self.wait(5) { count.fired > 0 }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(count.fired == 1)
    }

    @Test("a run of changes inside the wait is one republish")
    func debounced() async {
        let count = Count()
        let shop = await Self.liveShop(count)
        let settings = shop.settingsDict
        for n in 0..<3 {
            shop.webStoreFollow(products: shop.productRows + [.object(["id": .string("NEW\(n)")])],
                                settings: settings)
        }
        await Self.wait(5) { count.fired > 0 }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(count.fired == 1)
    }

    @Test("re-reading the same book is not a change: nothing is published, and the store stays live")
    func reloadAlone() async {
        let count = Count()
        let shop = await Self.liveShop(count)
        await shop.load(.sample)
        #expect(shop.webStoreLive == true)
        try? await Task.sleep(for: Self.delay + .milliseconds(500))
        #expect(count.fired == 0)
    }

    @Test("a different book forgets the last store, and is not compared with it")
    func anotherBook() async {
        let shop = Shop()
        await shop.load(.sample)
        shop.webStoreLive = true
        #expect(!shop.webStoreBookRead(nil), "the same book read again is not another")
        #expect(shop.webStoreLive == true)
        #expect(shop.webStoreBookRead(URL(fileURLWithPath: "/tmp/another-shop/store.json")))
        #expect(shop.webStoreLive == nil)
        #expect(shop.webStoreSeen == nil)
    }

    @Test("a held price still holds: the follow fires, nothing is sent, and the shop is told")
    func heldPriceIsNotSent() async throws {
        let engine = try KhaytEngine()
        let count = Count()
        let shop = Shop()
        await shop.load(.sample)
        let catalog = try await engine.storefrontCatalog(products: shop.productRows, settings: shop.settingsValue,
                                                         lang: "en", withPhotos: false, heroes: [:])
        let published = CatalogPublisher.prices(of: catalog)
        let id = try #require(published.keys.sorted().first)

        // Re-priced by something other than the shop.
        var rows = shop.productRows
        let at = try #require(rows.firstIndex { Shop.recordId($0) == id })
        guard case .object(var p) = rows[at] else { Issue.record("shape"); return }
        p["price"] = .number(9999)
        p.removeValue(forKey: "basePrice")
        rows[at] = .object(p)
        let repriced = try await engine.storefrontCatalog(products: rows, settings: shop.settingsValue,
                                                          lang: "en", withPhotos: false, heroes: [:])
        try #require(CatalogPublisher.prices(of: repriced)[id] != published[id])

        shop.webStoreFollowDelay = Self.delay
        shop.webStoreLive = true
        shop.webStoreAutoPublish = { shop in
            count.fired += 1
            if shop.automaticGate(sending: repriced, sent: 1,
                                  published: .init(live: true, prices: published)) == .send {
                count.sent += 1
            }
        }
        let notices = shop.moveNotices.count
        shop.webStoreSeen = Self.before
        await shop.load(.sample)
        await Self.wait(5) { count.fired > 0 }
        #expect(count.fired == 1)
        #expect(count.sent == 0, "a price nobody set was published")
        #expect(shop.webStorePriceHold.map(\.id) == [id])
        #expect(shop.moveNotices.count == notices + 1)
        #expect(shop.moveNotices.last == shop.words.callIt("mac.ws_prices_held"))
    }

    @Test("the gate: a catalogue whose prices are unchanged is sent; an offline store stops; nothing left empties")
    func gate() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        await shop.load(.sample)
        let catalog = try await engine.storefrontCatalog(products: shop.productRows, settings: shop.settingsValue,
                                                         lang: "en", withPhotos: false, heroes: [:])
        let published = CatalogPublisher.prices(of: catalog)
        // Same prices, one listing fewer (a product hidden or removed): sent.
        var fewer = published
        if let gone = fewer.keys.sorted().first { fewer[gone] = nil }
        #expect(shop.automaticGate(sending: catalog, sent: 3, published: .init(live: true, prices: published)) == .send)
        #expect(shop.automaticGate(sending: catalog, sent: 3, published: .init(live: true, prices: fewer)) == .send)
        #expect(shop.webStorePriceHold.isEmpty)
        #expect(shop.automaticGate(sending: .object(["items": .array([])]), sent: 0,
                                   published: .init(live: true)) == .empty)
        #expect(shop.automaticGate(sending: catalog, sent: 3, published: .init(live: false)) == .stop)
        #expect(shop.webStoreLive == false)
    }
}
