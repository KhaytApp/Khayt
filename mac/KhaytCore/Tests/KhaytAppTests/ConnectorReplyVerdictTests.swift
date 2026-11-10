import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A 2xx that is really a refusal, and a button's reply that fills nothing it
/// promised (Lamha E2E, Nov 10 2026), on the Mac, through the shared
/// `replyVerdict`. A made-up courier and a stand-in for the network: nothing
/// leaves this machine, and the token is a made-up one.
@MainActor
struct ConnectorReplyVerdictTests {

    static let manifest: JSONValue = {
        let json = #"""
        {
          "khayt": {"manifest": 1}, "id": "com.example.courier", "name": {"en": "Courier"},
          "publisher": "Example Ltd", "version": "1.0.0", "domains": ["api.example.com"],
          "secrets": [{"name": "apiKey", "label": {"en": "API key"}, "kind": "apiKey"}],
          "fields": [{"key": "ref", "label": {"en": "Courier order"}, "type": "text", "attach": "order"}],
          "actions": [
            {"id": "book", "label": {"en": "Book"}, "placement": "order", "kind": "post",
             "url": "https://api.example.com/book", "send": ["order.number", "customer.phone"],
             "auth": {"header": "Authorization", "scheme": "Bearer", "secret": "apiKey"},
             "response": {"fields": {"ref": ["order_id", "data.id"]}}}
          ],
          "events": [{"event": "order_shipped", "url": "https://api.example.com/shipped", "send": ["order.number"]}],
          "scopes": ["fields.write"]
        }
        """#
        return try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }()

    static let job: JSONValue = .object(["id": .string("J-1"), "invoiceNumber": .string("1001"), "rev": .number(1)])

    static func send(_ reply: String, trigger: Shop.ConnectorTrigger = .action("book")) async throws -> Shop.ConnectorOutcome {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        let entry = try await engine.pluginConsentedEntry(prev: .null, manifest: manifest)
        return await Shop.connectorSend(entry: entry, trigger: trigger, order: job, customer: nil, settings: nil,
                                        secrets: ["apiKey": "test-token-not-real"], engine: engine,
                                        post: { _ in (200, Data(reply.utf8)) }, now: Date(), delivery: "dlv_v")
    }

    @Test("a 200 with success:false is the service turning it down, in its own words, and fills nothing")
    func declined() async throws {
        #expect(try await Self.send(#"{"success":false,"msg":"The city field is required.","order_id":9}"#)
                == .declined("The city field is required."))
        #expect(try await Self.send(#"{"status":false}"#) == .declined(""))
    }

    @Test("a button's reply that fills none of its declared fields is not Sent")
    func unconfirmed() async throws {
        #expect(try await Self.send(#"{"success":true}"#) == .unconfirmed(["ref"]))
        #expect(try await Self.send("not json") == .unconfirmed(["ref"]))
    }

    @Test("the second path in the list fills the field when the first is absent")
    func pathList() async throws {
        #expect(try await Self.send(#"{"data":{"id":42}}"#) == .sent(.object(["ref": .string("42")])))
        #expect(try await Self.send(#"{"order_id":7,"data":{"id":42}}"#) == .sent(.object(["ref": .string("7")])))
    }

    @Test("an event with no reply fields stays Sent on a plain 2xx")
    func eventOk() async throws {
        #expect(try await Self.send("{}", trigger: .event("order_shipped")) == .sent(.object([:])))
    }

    @Test("the shop reads the service's words, or that it gave none")
    func words() async throws {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        let entry = try await engine.pluginConsentedEntry(prev: .null, manifest: Self.manifest)
        let said = Shop.declinedText(entry: entry, said: "The city field is required.", words: shop.words)
        #expect(said.contains("Courier") && said.contains("The city field is required."), Comment(rawValue: said))
        #expect(!Shop.declinedText(entry: entry, said: "", words: shop.words).contains("{"))
        #expect(Shop.fieldLabel(entry: entry, key: "ref", words: shop.words) == "Courier order")
    }

    @Test("a declined event is failed and kept, never put back on the retry ladder; a job with no customer is stopped first")
    func wiring() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop+ConnectorActions.swift"), encoding: .utf8)
        let event = try #require(source.range(of: "func sendConnectorEvent(").map { String(source[$0.lowerBound...].prefix(5000)) })
        let declined = try #require(event.range(of: "case .declined"))
        let ladder = try #require(event.range(of: "webhookNext"))
        #expect(declined.lowerBound < ladder.lowerBound, "decided before the backoff ladder is asked")
        #expect(event.contains("failConnectorEvent(item"))
        let press = try #require(source.range(of: "func pressConnector(").map { String(source[$0.lowerBound...].prefix(3200)) })
        #expect(press.contains("pluginUsesCustomer") && press.contains("plg.no_customer"))
    }
}
