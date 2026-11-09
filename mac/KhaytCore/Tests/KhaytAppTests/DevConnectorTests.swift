import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Developer mode: a `.khaytplugin` nobody signed, loaded on this Mac only.
/// It is kept out of the book (so it never syncs), runs only with both
/// switches on, never shadows a connector the shop installed, and its events
/// are heard but never queued in the book. Made-up hosts and ids throughout.
@MainActor
struct DevConnectorTests {

    /// A defaults suite of its own, with connectors and developer mode as asked.
    static func defaults(connectors: Bool = true, dev: Bool = true) -> UserDefaults {
        let name = "DevConnectorTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set(connectors, forKey: "KhaytConnectors")
        d.set(dev, forKey: DevConnectors.modeKey)
        return d
    }

    /// Khayt's Discord sample, signature removed and renamed: what a developer
    /// has on their desk before anyone reviews it.
    static func unsigned(id: String = "dev.example.notifier") throws -> Data {
        var m = try JSONDecoder().decode(JSONValue.self, from: ConnectorInstallTests.sample("discord-notifier"))
        guard case .object(var o) = m else { throw CocoaError(.coderReadCorrupt) }
        o.removeValue(forKey: "signature")
        o["id"] = .string(id)
        m = .object(o)
        return try JSONEncoder().encode(m)
    }

    static func shop(_ d: UserDefaults) async -> Shop {
        let shop = await ConnectorInstallTests.shop()
        shop.devConnectorDefaults = d
        return shop
    }

    static let noEnv: [String: String] = [:]

    @Test("developer mode needs connectors on too, and its entries run only while it is on")
    func switches() throws {
        let entry: JSONValue = .object(["id": .string("dev.a")])
        let d = Self.defaults()
        DevConnectors.save(.array([entry]), defaults: d)
        #expect(DevConnectors.running(besides: [], environment: Self.noEnv, defaults: d) == [entry])
        d.set(false, forKey: DevConnectors.modeKey)
        #expect(DevConnectors.running(besides: [], environment: Self.noEnv, defaults: d).isEmpty)
        #expect(DevConnectors.entries(defaults: d) == [entry], "turning developer mode off lost the entries")
        let noConnectors = Self.defaults(connectors: false, dev: true)
        DevConnectors.save(.array([entry]), defaults: noConnectors)
        #expect(!DevConnectors.isOn(environment: Self.noEnv, defaults: noConnectors))
        #expect(DevConnectors.running(besides: [], environment: Self.noEnv, defaults: noConnectors).isEmpty)
    }

    @Test("the shop's own connector wins over a dev one with the same id")
    func shopWins() throws {
        let d = Self.defaults()
        DevConnectors.save(.array([.object(["id": .string("same")]), .object(["id": .string("mine")])]), defaults: d)
        let book: [JSONValue] = [.object(["id": .string("same"), "enabled": .bool(true)])]
        let settings = DevConnectors.withDev(["plugins": .array(book)], environment: Self.noEnv, defaults: d)
        #expect(settings["plugins"] == .array(book + [.object(["id": .string("mine")])]))
        // Nothing running: the settings come back exactly as given.
        let off = Self.defaults(dev: false)
        DevConnectors.save(.array([.object(["id": .string("mine")])]), defaults: off)
        #expect(DevConnectors.withDev(["plugins": .array(book)], environment: Self.noEnv, defaults: off) == ["plugins": .array(book)])
    }

    @Test("an unsigned .khaytplugin installs into this Mac's dev list, never the book")
    func installs() async throws {
        let d = Self.defaults()
        let shop = await Self.shop(d)
        let bookBefore = shop.connectorEntries
        #expect(await shop.offerConnector(try Self.unsigned(), dev: true) == nil)
        let offer = try #require(shop.connectorOffer)
        #expect(offer.dev && offer.reviewedBy == nil)
        #expect(!offer.rows.isEmpty, "the consent sheet must still show what it sends")

        _ = await shop.installOfferedConnector()
        #expect(shop.connectorEntries == bookBefore, "a dev connector reached the book, which syncs")
        #expect(DevConnectors.entries(defaults: d).compactMap { Shop.plainString(Shop.object($0)["id"]) } == ["dev.example.notifier"])
        let rows = await shop.connectorRows()
        let row = try #require(rows.first { $0.id == "dev.example.notifier" })
        #expect(row.dev && row.state == "on")
        #expect(await shop.liveConnectors().contains { Shop.object($0)["id"] == .string("dev.example.notifier") })

        // Developer mode off: kept, shown as not run, and not live.
        d.set(false, forKey: DevConnectors.modeKey)
        #expect(await shop.connectorRows().first { $0.id == "dev.example.notifier" }?.state == "unreviewed")
        #expect(await shop.liveConnectors().isEmpty)

        // Removed from the dev list, still never from the book.
        d.set(true, forKey: DevConnectors.modeKey)
        await shop.removeConnector("dev.example.notifier")
        #expect(DevConnectors.entries(defaults: d).isEmpty)
        #expect(shop.connectorEntries == bookBefore)
    }

    @Test("without developer mode an unsigned file is refused as before")
    func refused() async throws {
        let off = await Self.shop(Self.defaults(dev: false))
        #expect(await off.offerConnector(try Self.unsigned(), dev: true) == off.words.callIt("plg.err_unreviewed"))
        #expect(await off.offerConnector(try Self.unsigned(), dev: false) == off.words.callIt("plg.err_unreviewed"))
        #expect(off.connectorOffer == nil)

    }

    @Test("a running dev connector hears a move's event, and its event is never queued in the book")
    func events() async throws {
        let d = Self.defaults()
        let shop = await Self.shop(d)
        _ = await shop.offerConnector(try Self.unsigned(), dev: true)
        _ = await shop.installOfferedConnector()
        let engine = try #require(shop.engine)
        let owed = try await engine.webhookDeliveries(
            order: ConnectorEventTests.order, effects: [WebhookEffect(kind: "webhook", event: "order_shipped", newStatus: nil)],
            settings: DevConnectors.withDev([:], environment: Self.noEnv, defaults: d), shopName: "Studio", clientName: "",
            currency: "SAR", at: "2026-11-09T10:00:00Z", nowMs: 1_800_000_000_000)
        #expect(owed.map(\.connector) == ["dev.example.notifier"])
        #expect(shop.isDevConnector("dev.example.notifier"))

        let source = try Self.source("Shop+ConnectorActions.swift")
        let settle = try #require(source.range(of: "private func settleConnectorEvent("))
        #expect(source[settle.upperBound...].prefix(500).contains("if isDevConnector(item.id) { return }"),
                "a dev connector's event would be queued in the book")
    }

    @Test("every move that works out its deliveries hears this Mac's dev connectors")
    func everyCallSite() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        var calls = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appending(path: name), encoding: .utf8)
            var rest = text[...]
            while let r = rest.range(of: "engine.webhookDeliveries(") {
                calls += 1
                let call = rest[r.upperBound...].prefix(260)
                let settings = call.range(of: "settings: ").map { call[$0.upperBound...] } ?? ""
                #expect(settings.hasPrefix("DevConnectors.withDev("), Comment(rawValue: "\(name): \(call.prefix(120))"))
                rest = rest[r.upperBound...]
            }
        }
        #expect(calls >= 8, "the call sites moved; this guard no longer sees them")
    }

    static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }
}
