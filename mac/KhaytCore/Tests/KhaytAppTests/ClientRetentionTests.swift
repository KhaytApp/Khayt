import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// The client retention card over the sample shop.
///
/// The rule is `lib/client-retention.js` and `test/client-retention.test.js`
/// pins it against the desktop's original. These are about the crossing and
/// about REACH: a card the sample book cannot fill has only ever been looked
/// at empty, which is how a chart nobody had ever drawn a bar on survived.
@Suite @MainActor struct ClientRetentionTests {

    @Test("the sample shop reaches the card with something to say")
    func sampleReachesTheCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let r = try await engine.clientRetention(
            clients: shop.clientRows, orders: shop.orderRows, today: Shop.today(),
            settings: shop.settingsDict, language: shop.words.language)
        #expect(r.enough)
        #expect(r.windows.map(\.days) == [30, 60, 90])
        #expect(r.returned > 0, "nobody comes back in the sample — the list and the average are never drawn")
        #expect(r.returned < r.clients, "everybody comes back in the sample — a rate under 100% is never drawn")
        #expect(r.windows.contains { $0.rate != nil }, "every window is 'too soon'")
        #expect(r.avgDaysToReturn != nil)
        #expect(!r.top.isEmpty)
        // Names, not ids: the engine resolves them, so the card cannot print
        // a CLIENT- id where a person's name belongs.
        let ids = Set(shop.clientRows.compactMap { row -> String? in
            if case .object(let c) = row, case .string(let id)? = c["id"] { return id }
            return nil
        })
        for regular in r.top {
            #expect(!ids.contains(regular.name), "\(regular.clientId) shown by its id")
        }
    }

    @Test("a window nobody is old enough for crosses as nil, not 0")
    func tooSoonStaysNil() async throws {
        let engine = try KhaytEngine()
        func job(_ id: String, _ client: String, _ date: String) -> JSONValue {
            .object(["id": .string(id), "clientId": .string(client),
                     "date": .string(date), "status": .string("completed")])
        }
        let r = try await engine.clientRetention(
            clients: [], orders: [job("1", "A", "2026-10-01"), job("2", "B", "2026-10-02")],
            today: "2026-10-06", settings: [:], language: "en")
        #expect(r.enough)
        #expect(r.windows.allSatisfy { $0.rate == nil && $0.eligible == 0 })
        #expect(r.avgDaysToReturn == nil)
    }

    @Test("the card, photographed")
    func picture() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let r = try await engine.clientRetention(
            clients: shop.clientRows, orders: shop.orderRows, today: Shop.today(),
            settings: shop.settingsDict, language: shop.words.language)
        let snap = SnapshotTests()
        let card = ClientRetentionCard(shop: shop, report: r)
            .card(rail: Khayt.brand, padding: 14)
            .frame(width: 490).padding(Metric.screen).background(Khayt.ground)
        try snap.render(card, "client-retention", size: CGSize(width: 530, height: 330))
        try snap.renderDark(card, "client-retention-dark", size: CGSize(width: 530, height: 330))
    }
}
