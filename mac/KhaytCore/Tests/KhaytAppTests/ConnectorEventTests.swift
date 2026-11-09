import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A connector listening to a job's events, against Khayt's signed Discord
/// sample and a stand-in for the network: no request leaves this machine and
/// the webhook path is made up.
@MainActor
struct ConnectorEventTests {

    static func discord(enabled: Bool = true) async throws -> (engine: KhaytEngine, entry: JSONValue) {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: try ConnectorInstallTests.sample("discord-notifier"))
        guard case .object(var e) = try await engine.pluginConsentedEntry(prev: .null, manifest: manifest) else {
            throw CocoaError(.coderReadCorrupt)
        }
        e["enabled"] = .bool(enabled)
        return (engine, .object(e))
    }

    static let order: JSONValue = .object([
        "id": .string("J-7"), "invoiceNumber": .string("1007"), "title": .string("Bracket"),
        "carrier": .string("SMSA"), "trackingNumber": .string("TRK1"), "rev": .number(2),
    ])

    final class Sent: @unchecked Sendable { var posts: [Connectors.Post] = [] }

    @Test("a move's deliveries name each connector listening, even with the shop's webhooks off")
    func targets() async throws {
        let (engine, entry) = try await Self.discord()
        let settings: [String: JSONValue] = ["plugins": .array([entry]), "webhooks": .object(["enabled": .bool(false)])]
        let owed = try await engine.webhookDeliveries(
            order: Self.order, effects: [WebhookEffect(kind: "webhook", event: "order_shipped", newStatus: nil)],
            settings: settings, shopName: "Studio", clientName: "", currency: "SAR",
            at: "2026-11-09T10:00:00Z", nowMs: 1_800_000_000_000)
        #expect(owed.count == 1)
        #expect(owed.first?.connector == "app.khayt.samples.discord")
        #expect(owed.first?.orderId == "J-7")
        #expect(owed.first?.event == "order_shipped")

        // Not an event it listens to, or switched off: nothing.
        let other = try await engine.webhookDeliveries(
            order: Self.order, effects: [WebhookEffect(kind: "webhook", event: "payment_received", newStatus: nil)],
            settings: settings, shopName: "Studio", clientName: "", currency: "SAR",
            at: "2026-11-09T10:00:00Z", nowMs: 1_800_000_000_000)
        #expect(other.isEmpty)
        let (_, off) = try await Self.discord(enabled: false)
        let none = try await engine.webhookDeliveries(
            order: Self.order, effects: [WebhookEffect(kind: "webhook", event: "order_shipped", newStatus: nil)],
            settings: ["plugins": .array([off])], shopName: "Studio", clientName: "", currency: "SAR",
            at: "2026-11-09T10:00:00Z", nowMs: 1_800_000_000_000)
        #expect(none.isEmpty, "a switched-off connector was sent an event")
    }

    @Test("an event sends the connector's own request, named and with the delivery id kept")
    func send() async throws {
        let (engine, entry) = try await Self.discord()
        let sent = Sent()
        let outcome = await Shop.connectorSend(
            entry: entry, trigger: .event("order_shipped"), order: Self.order, customer: nil,
            secrets: ["webhookPath": "123/made-up"], engine: engine,
            post: { p in sent.posts.append(p); return (204, Data(#"{"id":"x"}"#.utf8)) },
            now: Date(), delivery: "dlv_11111111-2222-4333-8444-555555555555")
        #expect(outcome == .sent(.object([:])), "an event's answer was read into the book")
        let post = try #require(sent.posts.first)
        #expect(post.url.absoluteString == "https://discord.com/api/webhooks/123/made-up")
        #expect(post.headers.contains(Connectors.Header("X-Khayt-Event", "order_shipped")))
        #expect(post.headers.contains(Connectors.Header("X-Khayt-Delivery", "dlv_11111111-2222-4333-8444-555555555555")))
        let body = try JSONDecoder().decode(JSONValue.self, from: post.body)
        #expect(Shop.object(body)["content"] == .string("Shipped 1007 with SMSA (TRK1)"))
    }

    @Test("a failed event says its status, so the webhook ladder can decide; a missing key is refused")
    func failures() async throws {
        let (engine, entry) = try await Self.discord()
        let down = await Shop.connectorSend(entry: entry, trigger: .event("order_shipped"), order: Self.order, customer: nil,
                                            secrets: ["webhookPath": "1/x"], engine: engine,
                                            post: { _ in (503, nil) }, now: Date(), delivery: "dlv_a")
        #expect(down == .failed("HTTP 503", status: 503))
        let next = try await engine.webhookNext(status: 503, attempt: 1)
        #expect(next.retry && next.afterMs == 30_000)
        let gone = try await engine.webhookNext(status: 410, attempt: 1)
        #expect(!gone.retry)

        let tried = Sent()
        let noKey = await Shop.connectorSend(entry: entry, trigger: .event("order_shipped"), order: Self.order, customer: nil,
                                             secrets: [:], engine: engine,
                                             post: { p in tried.posts.append(p); return (200, nil) }, now: Date(), delivery: "dlv_b")
        guard case .refused = noKey else { Issue.record("sent without its webhook path: \(noKey)"); return }
        #expect(tried.posts.isEmpty)
    }

    @Test("a queued event reads back as it was written, attempt and all")
    func queued() async throws {
        let (engine, _) = try await Self.discord()
        let item = ConnectorQueued(delivery: "dlv_q", id: "app.khayt.samples.discord", event: "order_shipped",
                                   orderId: "J-7", attempt: 2)
        let list = try await engine.pluginQueued(.array([]), item: item.json, nextAttemptAt: "2026-11-09T10:00:30Z")
        let due = try await engine.pluginDue(list, nowMs: 1_900_000_000_000)
        #expect(due.compactMap(ConnectorQueued.init) == [item])
        #expect(try await engine.pluginDue(list, nowMs: 0).isEmpty)
        #expect(try await engine.pluginUnqueued(list, delivery: "dlv_q") == .array([]))
    }
}
