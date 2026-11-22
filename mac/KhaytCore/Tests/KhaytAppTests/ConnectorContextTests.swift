import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the Mac hands the shared payload builder besides the job: the book's
/// settings (an amount due is worked out in the shop's tax mode) and this
/// attempt's clock (`{now…epochMs}`). Without either, lib refuses rather than
/// send a wrong amount or an expiry of 1970. A made-up payment service; nothing
/// leaves this machine.
@MainActor
struct ConnectorContextTests {

    static let manifest: JSONValue = {
        let json = #"""
        {
          "khayt": {"manifest": 1}, "id": "com.example.pay", "name": {"en": "Pay"},
          "publisher": "Example Ltd", "version": "1.0.0", "domains": ["api.example.com"],
          "actions": [
            {"id": "pay", "label": {"en": "Payment link"}, "placement": "order", "kind": "open",
             "url": "https://api.example.com/pay?amount={order.amountDueMinor}&exp={now.plusDays.1.epochMs}"}
          ]
        }
        """#
        return try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }()

    static let job: JSONValue = .object([
        "id": .string("J-1"), "invoiceNumber": .string("1001"), "status": .string("in_progress"),
        "price": .number(115), "qty": .number(1),
    ])

    static func send(settings: JSONValue?, now: Date) async throws -> Shop.ConnectorOutcome {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        let entry = try await engine.pluginConsentedEntry(prev: .null, manifest: manifest)
        return await Shop.connectorSend(entry: entry, actionId: "pay", order: job, customer: nil, settings: settings,
                                        secrets: [:], engine: engine,
                                        post: { _ in Issue.record("an open link posts nothing"); return (200, nil) },
                                        now: now)
    }

    @Test("an amount due and an expiry are built from the shop's settings and this attempt's clock")
    func built() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = try await Self.send(settings: .object(["currency": .string("SAR")]), now: now)
        guard case .open(let url) = outcome else { Issue.record("not built: \(outcome)"); return }
        #expect(url.absoluteString == "https://api.example.com/pay?amount=11500&exp=1800086400000")
    }

    @Test("without the book's settings an amount due is refused, never sent at its pre-tax price")
    func noSettings() async throws {
        let outcome = try await Self.send(settings: nil, now: Date())
        guard case .refused = outcome else { Issue.record("built without settings: \(outcome)"); return }
    }

    @Test("every send on the Mac hands over the book's settings")
    func wired() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        var calls = 0
        for file in ["Shop+ConnectorActions.swift", "Shop+ConnectorRefresh.swift"] {
            let source = try String(contentsOf: dir.appending(path: file), encoding: .utf8)
            for call in source.components(separatedBy: "Self.connectorSend(").dropFirst() {
                calls += 1
                #expect(call.prefix(200).contains(#"settings: root["settings"]"#), Comment(rawValue: "\(file): \(call.prefix(120))"))
            }
        }
        #expect(calls == 3, "a button, an event and a refresh")
    }
}
