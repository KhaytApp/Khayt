import Foundation
import Testing
@testable import KhaytCore

/// The connector contract runs inside JavaScriptCore — on the Mac and on the
/// phone — exactly as it runs under Node. No `require`, no `global`: the two
/// modules find each other as globals, in bundle order.
struct PluginManifestEngineTests {

    static func at(_ v: JSONValue, _ key: String) -> JSONValue? {
        if case .object(let o) = v { return o[key] }
        return nil
    }

    static func sample(_ name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "plugins/samples/\(name).json")
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    @Test("every shipped sample validates in the engine")
    func samplesValidate() async throws {
        let engine = try KhaytEngine()
        for name in ["slack-notifier", "discord-notifier", "sheets-log"] {
            let r = try await engine.pluginValidate(try Self.sample(name))
            #expect(Self.at(r, "ok") == .bool(true), Comment(rawValue: "\(name): \(r)"))
        }
        let bad = try await engine.pluginValidate(.object(["id": .string("x")]))
        #expect(Self.at(bad, "ok") == .bool(false))
    }

    @Test("the engine builds the same bytes Node does")
    func payloadBytes() async throws {
        let engine = try KhaytEngine()
        let slack = try Self.sample("slack-notifier")
        let order: JSONValue = .object(["invoiceNumber": .string("INV-2026-0003"), "project": .string("Rack"),
                                        "price": .number(10), "currency": .string("SAR"), "client": .string("Noura")])
        let r = try await engine.pluginPayload(slack, trigger: .object(["event": .string("order_created")]),
                                               context: .object(["order": order,
                                                                 "secrets": .object(["webhookPath": .string("T0/B0/X")])]))
        #expect(Self.at(r, "ok") == .bool(true))
        #expect(Self.at(r, "url") == .string("https://hooks.slack.com/services/T0/B0/X"))
        // `node -e` over the same input prints exactly this.
        #expect(Self.at(r, "body") == .string(#"{"text":"New job INV-2026-0003: Rack for Noura (10 SAR)"}"#))
        let perms = try await engine.pluginPermissions(slack)
        #expect(Self.at(perms, "domains") == .array([.string("hooks.slack.com")]))
        let diff = try await engine.pluginDiff(granted: try await engine.pluginGrant(slack), manifest: slack)
        #expect(Self.at(diff, "widened") == .bool(false))
    }
}
