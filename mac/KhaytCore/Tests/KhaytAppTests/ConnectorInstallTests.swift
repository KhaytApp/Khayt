import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Installing a connector on the Mac: only a manifest Khayt signed is offered,
/// the consent sheet names every field and where it goes, the stored entry is
/// granted exactly what was shown, and the keys stay in this Mac's Keychain —
/// named as the phone names its own — never in the book.
@MainActor
struct ConnectorInstallTests {

    static func sample(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "plugins/samples/\(name).json")
        return try Data(contentsOf: url)
    }

    static func shop() async -> Shop {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        shop.connectorSecrets = ConnectorMemorySecrets()
        return shop
    }

    @Test("a signed sample is offered, with every field it sends labelled and where it goes")
    func offered() async throws {
        let shop = await Self.shop()
        #expect(await shop.offerConnector(try Self.sample("lamha-shipping")) == nil)
        let offer = try #require(shop.connectorOffer)
        #expect(offer.manifestId == "app.khayt.samples.lamha")
        #expect(offer.reviewedBy == "khayt-2026-11")
        #expect(offer.rows.map(\.host) == ["app.lamha.sa"])
        let fields = offer.rows[0].fields
        // A book field in Khayt's words, a setting and an own field by the
        // manifest's label — each with the kind of data it is.
        #expect(fields.contains("\(shop.words.callIt("plg.f.customer.phone")) (\(shop.words.callIt("plg.cat.contact.phone")))"))
        #expect(fields.contains { $0.hasPrefix("Sender phone (") })
        #expect(fields.contains { $0.hasPrefix("City (for shipping) (") })
        #expect(!fields.contains { $0.contains("plg.") || $0.contains("config.") || $0.contains("field.") })
        #expect(offer.scopes == ["fields.write"])
    }

    @Test("a changed byte, or not a connector at all, is refused before anything is shown")
    func refused() async throws {
        let shop = await Self.shop()
        var m = try JSONDecoder().decode(JSONValue.self, from: Self.sample("slack-notifier"))
        if case .object(var o) = m { o["version"] = .string("9.9.9"); m = .object(o) }
        #expect(await shop.offerConnector(try JSONEncoder().encode(m)) == shop.words.callIt("plg.err_unreviewed"))
        #expect(await shop.offerConnector(Data("{\"id\":1}".utf8)) == shop.words.callIt("plg.err_invalid"))
        #expect(await shop.offerConnector(Data("not json".utf8)) == shop.words.callIt("plg.err_invalid"))
        #expect(shop.connectorOffer == nil)
    }

    @Test("the stored entry is granted what was shown, and a reinstall keeps its settings and switch")
    func stored() async throws {
        let engine = try KhaytEngine()
        let lamha = try JSONDecoder().decode(JSONValue.self, from: Self.sample("lamha-shipping"))
        let once = try await Shop.withConsented(lamha, in: .array([]), engine: engine)
        guard case .array(let rows) = once, rows.count == 1 else { Issue.record("one entry"); return }
        let check = try await engine.pluginCheckEntry(rows[0])
        #expect(Shop.object(check)["ok"] == .bool(true) && Shop.object(check)["paused"] == .bool(false))
        #expect(Shop.object(Shop.object(rows[0])["granted"])["scopes"] == .array([.string("fields.write")]))
        #expect(Shop.object(rows[0])["secrets"] == nil)

        // The shop filled in a setting and switched it off; installing again keeps both.
        var e = Shop.object(rows[0])
        e["config"] = .object(["senderName": .string("Athar")]); e["enabled"] = .bool(false)
        let again = try await Shop.withConsented(lamha, in: .array([.object(e), .object(["id": .string("other")])]), engine: engine)
        guard case .array(let after) = again else { return }
        #expect(after.count == 2)
        let kept = Shop.object(after[0])
        #expect(Shop.object(kept["config"])["senderName"] == .string("Athar"))
        #expect(kept["enabled"] == .bool(false))
    }

    @Test("the sample shop installs nothing")
    func sampleRefuses() async throws {
        let shop = await Self.shop()
        _ = await shop.offerConnector(try Self.sample("sheets-log"))
        #expect(shop.connectorOffer != nil)
        _ = await shop.installOfferedConnector()
        #expect(shop.connectorEntries.isEmpty)
    }

    @Test("keys: only declared ones are kept, on this device, under the phone's names, and go with the connector")
    func keys() async throws {
        let shop = await Self.shop()
        let engine = try #require(shop.engine)
        let lamha = try JSONDecoder().decode(JSONValue.self, from: Self.sample("lamha-shipping"))
        let plugins = try await Shop.withConsented(lamha, in: .array([]), engine: engine)
        var settings = shop.settingsDict
        settings["plugins"] = plugins
        shop.settingsValue = .object(settings)

        var row = try #require(await shop.connectorRows().first)
        #expect(row.state == "on" && row.keysMissing)
        #expect(row.secrets.map(\.label) == ["Lamha API token"])

        #expect(await shop.saveConnectorKeys("app.khayt.samples.lamha", ["apiToken": " t-1 ", "stolen": "x"]))
        #expect(await shop.connectorSecrets.value(pluginId: "app.khayt.samples.lamha", name: "apiToken") == "t-1")
        #expect(await shop.connectorSecrets.value(pluginId: "app.khayt.samples.lamha", name: "stolen") == nil)
        row = try #require(await shop.connectorRows().first)
        #expect(!row.keysMissing)
        // Never in the book.
        #expect(!String(decoding: try JSONValue.encode(shop.settingsValue), as: UTF8.self).contains("t-1"))
        // The phone names its copy the same way (ConnectorRules.keychainName).
        #expect(ConnectorKeychain.account(pluginId: "app.khayt.samples.lamha", name: "apiToken")
                == "plugin.app.khayt.samples.lamha.apiToken")

        await shop.connectorSecrets.removeAll(pluginId: "app.khayt.samples.lamha",
                                              names: Shop.connectorSecretsDeclared(lamha).map(\.name))
        #expect(await shop.connectorSecrets.value(pluginId: "app.khayt.samples.lamha", name: "apiToken") == nil)
    }

    @Test("an entry whose manifest is not signed by Khayt shows as not reviewed, and is never on")
    func unreviewedEntry() async throws {
        let shop = await Self.shop()
        let engine = try #require(shop.engine)
        var m = try JSONDecoder().decode(JSONValue.self, from: Self.sample("slack-notifier"))
        let plugins = try await Shop.withConsented(m, in: .array([]), engine: engine)
        // A book edited elsewhere: the description changed, the signature did not.
        guard case .array(var rows) = plugins, case .object(var e) = rows[0], case .object(var o) = e["manifest"] else { return }
        o["description"] = .object(["en": .string("Sends everything everywhere")]); m = .object(o)
        e["manifest"] = m; rows[0] = .object(e)
        var settings = shop.settingsDict
        settings["plugins"] = .array(rows)
        shop.settingsValue = .object(settings)
        #expect(try #require(await shop.connectorRows().first).state == "unreviewed")
    }
}
