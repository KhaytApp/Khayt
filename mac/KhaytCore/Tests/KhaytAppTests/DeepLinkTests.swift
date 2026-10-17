import Foundation
import Testing
import KhaytCore
import KhaytWidgetData
@testable import KhaytApp

/// A desktop widget's row opening the app (`DeepLink.swift`): the four shapes
/// are read, everything else is refused, and following one only navigates —
/// through the same gate as ⌘K.
@MainActor
@Suite(.serialized)
struct DeepLinkTests {

    @Test("each link survives the trip through a URL, odd ids included")
    func roundTrip() {
        for link: ShopWidgetSnapshot.Link in [.machine("M-1"), .job("ORD-01011"), .spool("sp 7/ä"),
                                             .screen("board"), .screen("jobs:pending")] {
            #expect(ShopWidgetSnapshot.Link(link.url) == link, "\(link.url)")
        }
    }

    @Test("anything that is not exactly one of ours is refused")
    func refusesTheRest() {
        for text in ["https://khayt.app/job/1", "khayt://job/", "khayt://job", "khayt://job/a/b",
                     "khayt://delete/ORD-1", "khayt://job/1?then=delete", "khayt://job/1#x",
                     "khayt://user:pw@job/1", "khayt://job:80/1", "file:///Users/x/model.3mf",
                     "khayt://job/" + String(repeating: "a", count: 201), "khayt://job/a%0Ab"] {
            if let url = URL(string: text) {
                #expect(ShopWidgetSnapshot.Link(url) == nil, "\(text) was taken")
            }
        }
    }

    @Test("following a link opens the record's screen, and an id the book lacks does nothing")
    func followsOnlyWhatTheBookHas() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first)
        #expect(shop.follow(.job(job.id)))
        #expect(shop.shelf == .jobs(nil))
        #expect(shop.selection == job.id)

        shop.shelf = .dashboard
        #expect(!shop.follow(.job("ORD-NOT-HERE")))
        #expect(!shop.follow(.machine("nope")))
        #expect(!shop.follow(.spool("nope")))
        #expect(!shop.follow(.screen("no-such-screen")))
        #expect(shop.shelf == .dashboard, "a refused link must not move the window")

        let machine = try #require(shop.machines.first)
        #expect(shop.follow(.machine(machine.id)))
        #expect(shop.shelf == .machines)
        let spool = try #require(shop.spools.first)
        #expect(shop.follow(.spool(spool.id)))
        #expect(shop.shelf == .inventory)
        #expect(shop.follow(.screen("board")))
        #expect(shop.shelf == .board)
    }

    @Test("every link a widget draws is one the app can follow")
    func widgetLinksAreFollowable() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let snap = WidgetFeed.compose(shop, now: Date())
        var links: [ShopWidgetSnapshot.Link] = snap.printing.map { .machine($0.id) }
        links += (snap.upNext ?? []).map { .job($0.id) }
        links += (snap.lowSpools ?? []).map { .spool($0.id) }
        links += ["machines", "dashboard", "inventory", "board"].map { .screen($0) }
        #expect(links.count > 4)
        for link in links {
            #expect(shop.follow(link), "\(link.url) leads nowhere")
        }
    }

    @Test("a link handed over long before its window began is not followed")
    func staleLinkIsDropped() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // The window was already open: never stale.
        #expect(!Shop.isStale(arrivedAt: t0.addingTimeInterval(-3600), windowOpenedAt: nil))
        // The link that launched the app arrives as the window's task begins.
        #expect(!Shop.isStale(arrivedAt: t0.addingTimeInterval(-1), windowOpenedAt: t0))
        #expect(!Shop.isStale(arrivedAt: t0.addingTimeInterval(2), windowOpenedAt: t0))
        // Clicked with the window closed, the window reopened an hour later.
        #expect(Shop.isStale(arrivedAt: t0.addingTimeInterval(-3600), windowOpenedAt: t0))

        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first)
        shop.shelf = .dashboard
        Shop.openedLinks = [.job(job.id)]
        Shop.openedLinksArrived = Date().addingTimeInterval(-3600)
        shop.takeOpenedLinks(windowOpenedAt: Date())
        #expect(Shop.openedLinks.isEmpty, "a stale link is discarded, not kept for later")
        #expect(shop.shelf == .dashboard, "a stale link must not move the window")

        Shop.openedLinks = [.job(job.id)]
        shop.takeOpenedLinks(windowOpenedAt: Date())
        #expect(Shop.openedLinks.isEmpty)
        #expect(shop.shelf == .jobs(nil), "a fresh link is followed")
        #expect(shop.selection == job.id)
    }
}
