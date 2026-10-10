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

    /// NOTHING HERE WAITS ON THE WALL CLOCK. Each test awaits the republish
    /// task itself (`webStoreRepublish`), which ends when the follow has fired
    /// or given up — so a 3-vCPU runner under load is slower, never wrong. A
    /// wall-clock deadline ("fired within 5 s") failed on CI after 871 s of a
    /// starved main actor, with the republish still queued behind it.
    ///
    /// The wait itself is kept short but real: a debounce of zero would let a
    /// task that should have been cancelled race the next change.
    static let delay: Duration = .milliseconds(20)

    /// Every load in this suite on ONE day. The sample book is rebased to the
    /// day it is read on, and a test that loads it twice straddled midnight
    /// on a starved CI runner (the two loads 15+ minutes apart): the second
    /// book's dates had moved, so "the same book" was a changed one and a
    /// republish was scheduled. All three failing runs began 23:29–23:42 UTC
    /// and ran past 00:00 (Oct 2026). Locally the suite takes a second.
    static let day = Date(timeIntervalSince1970: 1_788_000_000)

    final class Count { var fired = 0; var sent = 0 }

    /// The sample book, read once, its store live, publishes counted.
    static func liveShop(_ count: Count,
                         publish: (@MainActor (Shop) async -> Void)? = nil) async -> Shop {
        let shop = Shop()
        await shop.load(.sample, asOf: Self.day)
        shop.webStoreFollowDelay = delay
        shop.webStoreAutoPublish = publish ?? { _ in count.fired += 1 }
        shop.webStoreLive = true
        return shop
    }

    /// The follow scheduled by the last change, run to its end.
    static func settle(_ shop: Shop) async {
        await shop.webStoreRepublish?.value
    }

    /// What the book was read as before it changed. Any value the load will
    /// not produce stands in for the catalogue as it was.
    static let before: JSONValue = .object(["products": .array([]), "storefront": .null])

    @Test("a change to the book republishes a live store once, after the wait")
    func changeRepublishes() async throws {
        let count = Count()
        let shop = await Self.liveShop(count)
        shop.webStoreSeen = Self.before
        // The book as changed: re-read, as the app does after any write.
        await shop.load(.sample, asOf: Self.day)
        #expect(shop.webStoreLive == true, "the reload forgot the store was live")
        let follow = try #require(shop.webStoreRepublish, "the reload scheduled no follow")
        #expect(!follow.isCancelled, "the reload cancelled the follow it had scheduled")
        await follow.value
        #expect(count.fired == 1)
    }

    @Test("a run of changes inside the wait is one republish")
    func debounced() async {
        let count = Count()
        let shop = await Self.liveShop(count)
        let settings = shop.settingsDict
        var follows: [Task<Void, Never>] = []
        for n in 0..<3 {
            shop.webStoreFollow(products: shop.productRows + [.object(["id": .string("NEW\(n)")])],
                                settings: settings)
            if let follow = shop.webStoreRepublish { follows.append(follow) }
        }
        #expect(follows.count == 3)
        // Every one of them run to its end, the cancelled ones included, so
        // none can fire after the count is read.
        for follow in follows { await follow.value }
        let superseded = follows.dropLast().filter { $0.isCancelled }.count
        #expect(superseded == 2, "an earlier change was not superseded")
        #expect(count.fired == 1)
    }

    @Test("re-reading the same book is not a change: nothing is published, and the store stays live")
    func reloadAlone() async {
        let count = Count()
        let shop = await Self.liveShop(count)
        await shop.load(.sample, asOf: Self.day)
        #expect(shop.webStoreLive == true)
        // Nothing was scheduled at all — not merely nothing fired yet.
        #expect(shop.webStoreRepublish == nil, "a re-read of the same book scheduled a republish")
        await Self.settle(shop)
        #expect(count.fired == 0)
    }

    @Test("the cause of the CI flake, pinned: the sample read a day later IS a changed catalogue")
    func sampleAcrossMidnight() async {
        let count = Count()
        let shop = await Self.liveShop(count)
        await shop.load(.sample, asOf: Self.day.addingTimeInterval(86_400))
        #expect(shop.webStoreRepublish != nil,
                "if this stops scheduling, the day pin above is no longer what keeps reloadAlone steady")
        shop.webStoreRepublish?.cancel()
    }

    @Test("a different book forgets the last store, and is not compared with it")
    func anotherBook() async {
        let shop = Shop()
        await shop.load(.sample, asOf: Self.day)
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
        await shop.load(.sample, asOf: Self.day)
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
        await shop.load(.sample, asOf: Self.day)
        try #require(shop.webStoreRepublish != nil, "the change scheduled no follow")
        await Self.settle(shop)
        #expect(count.fired == 1)
        #expect(count.sent == 0, "a price nobody set was published")
        #expect(shop.webStorePriceHold.map(\.id) == [id])
        #expect(shop.moveNotices.count == notices + 1)
        #expect(shop.moveNotices.last == shop.words.callIt("mac.ws_prices_held"))
    }

    @Test("an automatic publish does not cancel itself; a publish somebody presses replaces the waiting one")
    func automaticDoesNotCancelItself() async throws {
        final class Seen { var cancelledInside: Bool? }
        let seen = Seen()
        let count = Count()
        let shop = await Self.liveShop(count) { shop in
            count.fired += 1
            // The real entry point, from inside the follow's own task. It used
            // to cancel `webStoreRepublish` — itself — so every request after
            // that line ran cancelled and the store was never sent.
            await shop.publishWebStore(automatic: true)
            seen.cancelledInside = Task.isCancelled
        }
        shop.webStoreFollow(products: shop.productRows + [.object(["id": .string("NEW")])],
                            settings: shop.settingsDict)
        await Self.settle(shop)
        #expect(count.fired == 1)
        #expect(seen.cancelledInside == false, "the automatic publish cancelled its own task")

        // Pressed: the follow waiting behind it is not needed any more.
        shop.webStoreFollowDelay = .seconds(3600)
        shop.webStoreFollow(products: shop.productRows + [.object(["id": .string("NEWER")])],
                            settings: shop.settingsDict)
        let waiting = try #require(shop.webStoreRepublish)
        await shop.publishWebStore()
        await waiting.value
        #expect(waiting.isCancelled)
        #expect(count.fired == 1)

        let src = try QuoteSheetStatusTests.source("WebStore.swift")
        #expect(src.contains("if !automatic { webStoreRepublish?.cancel() }"))
    }

    @Test("the gate: a catalogue whose prices are unchanged is sent; an offline store stops; nothing left empties")
    func gate() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        await shop.load(.sample, asOf: Self.day)
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

    @Test("an automatic publish that finds nothing to list keeps the store up and tells the shop")
    func emptyIsHeldNotUnpublished() async throws {
        let shop = Shop()
        await shop.load(.sample, asOf: Self.day)
        shop.webStoreLive = true
        shop.holdEmptyStore()
        #expect(shop.webStoreLive == true, "an automatic publish took the store offline")
        #expect(shop.webStoreProblem)
        #expect(shop.webStoreSaid == shop.words.callIt("mac.ws_empty_held"))
        #expect(shop.moveNotices.contains(shop.words.callIt("mac.ws_empty_held")))
        // Once, not on every edit that follows.
        let count = shop.moveNotices.count
        shop.holdEmptyStore()
        #expect(shop.moveNotices.count == count)
    }
}
