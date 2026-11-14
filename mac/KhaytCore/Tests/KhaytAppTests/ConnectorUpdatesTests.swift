import Foundation
import Testing
import CryptoKit
import KhaytCore
@testable import KhaytApp

/// Connector updates on the Mac (`Shop+ConnectorUpdates.swift`): what the row
/// and the badge say about a check's state, the update sheet in the shared
/// order, and the trust — an index nobody signed fetches nothing, a manifest
/// is taken only when its bytes match the index AND Khayt signed it, and an
/// update never writes any settings but its own two keys.
@MainActor
struct ConnectorUpdatesTests {

    static let lamhaId = "app.khayt.samples.lamha"

    static func lamha() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: ConnectorInstallTests.sample("lamha-shipping"))
    }

    /// Lamha 9.0.0, asking for more: a second host that is sent the job
    /// number (already agreed for app.lamha.sa, so a "new place") and the
    /// customer's phone. Unsigned: the sheet reads what is asked, not trust.
    static func widened() throws -> JSONValue {
        guard case .object(var m) = try lamha() else { throw CocoaError(.fileReadCorruptFile) }
        m["version"] = .string("9.0.0")
        m["domains"] = .array([.string("app.lamha.sa"), .string("track.lamha.example")])
        guard case .array(var actions)? = m["actions"] else { throw CocoaError(.fileReadCorruptFile) }
        actions.append(.object([
            "id": .string("track"), "label": .object(["en": .string("Track")]), "placement": .string("order"),
            "kind": .string("post"), "url": .string("https://track.lamha.example/v1/track"),
            "body": .object(["format": .string("json-template"),
                             "template": .object(["n": .string("{order.number}"), "p": .string("{customer.phone}")])]),
        ]))
        m["actions"] = .array(actions)
        m.removeValue(forKey: "signature")
        return .object(m)
    }

    /// The sample shop with Lamha installed and `connectorUpdates` as given.
    static func shop(updates: [String: JSONValue]?) async throws -> Shop {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        var settings = shop.settingsDict
        settings["plugins"] = try await Shop.withConsented(try lamha(), in: .array([]), engine: engine)
        if let updates { settings["connectorUpdates"] = .object(["connectors": .object([lamhaId: .object(updates)])]) }
        shop.settingsValue = .object(settings)
        return shop
    }

    @Test("a waiting update: the steel badge, Review update, and the count on Integrations")
    func waiting() async throws {
        let pending: [String: JSONValue] = ["pending": .object([
            "version": .string("9.0.0"), "manifest": try Self.widened(), "offeredAt": .string("2026-11-14T10:00:00Z")])]
        let shop = try await Self.shop(updates: pending)
        let row = try #require(await shop.connectorRows().first)
        #expect(row.update.waiting == "9.0.0")
        #expect(row.update.revertTo == nil && row.update.withdrawn == nil)
        await shop.refreshConnectorUpdatesWaiting(switchedOn: true)
        #expect(shop.connectorUpdatesWaiting == 1)
        // Switched off, there is no count to show.
        await shop.refreshConnectorUpdatesWaiting(switchedOn: false)
        #expect(shop.connectorUpdatesWaiting == 0)
    }

    @Test("a pending version the entry already has is not waiting")
    func notNewer() async throws {
        let lamha = try Self.lamha()
        let version = Shop.plainString(Shop.object(lamha)["version"]) ?? ""
        let shop = try await Self.shop(updates: ["pending": .object([
            "version": .string(version), "manifest": lamha, "offeredAt": .string("2026-11-14T10:00:00Z")])])
        let row = try #require(await shop.connectorRows().first)
        #expect(row.update.waiting == nil)
        #expect(await shop.connectorUpdateReview(Self.lamhaId) == nil)
    }

    @Test("the sheet: what is new first, host by host, tagged; what was agreed after")
    func sheet() async throws {
        let shop = try await Self.shop(updates: ["pending": .object([
            "version": .string("9.0.0"), "manifest": try Self.widened(), "offeredAt": .string("2026-11-14T10:00:00Z")])])
        let review = try #require(await shop.connectorUpdateReview(Self.lamhaId))
        #expect(review.sheet.asksMore)
        #expect(review.sheet.to == "9.0.0")
        #expect(review.reviewed == false, "the test manifest carries no signature")
        let fresh = try #require(review.sheet.fresh.first { $0.host == "track.lamha.example" })
        #expect(fresh.items.map(\.key) == ["customer.phone", "order.number"] || fresh.items.map(\.key) == ["order.number", "customer.phone"])
        #expect(Set(fresh.items.compactMap(\.tag)) == ["new_place"], "both were agreed for app.lamha.sa")
        #expect(review.sheet.agreed.map(\.host) == ["app.lamha.sa"])
        // Every line has a word, never a raw key.
        for item in fresh.items {
            let name = shop.connectorUpdateItemName(item, manifest: review.manifest)
            #expect(!name.isEmpty && !name.contains("plg."))
        }
    }

    @Test("after an update: the note and Revert; a withdrawn previous says why there is none")
    func afterUpdate() async throws {
        let lamha = try Self.lamha()
        let shop = try await Self.shop(updates: [
            "previous": .object(["version": .string("1.0.0"), "manifest": lamha, "granted": .object([:])]),
            "updatedFrom": .string("1.0.0"), "updatedAt": .string("2026-11-11T09:00:00Z")])
        var row = try #require(await shop.connectorRows().first)
        #expect(row.update.revertTo == "1.0.0" && row.update.updatedFrom == "1.0.0")
        #expect(row.update.revertWithdrawn == nil)

        let gone = try await Self.shop(updates: ["previousWithdrawn": .string("1.0.0"), "updatedFrom": .string("1.0.0")])
        row = try #require(await gone.connectorRows().first)
        #expect(row.update.revertTo == nil)
        #expect(row.update.revertWithdrawn == "1.0.0")
    }

    @Test("a withdrawn version: paused, with Khayt's reason, and the shop's switch kept")
    func withdrawn() async throws {
        let version = Shop.plainString(Shop.object(try Self.lamha())["version"]) ?? ""
        let shop = try await Self.shop(updates: ["revoked": .object([
            "version": .string(version), "reason": .string("Sends to the wrong address."),
            "at": .string("2026-11-14T10:00:00Z"), "wasEnabled": .bool(true)])])
        let row = try #require(await shop.connectorRows().first)
        #expect(row.update.withdrawn == .init(version: version, reason: "Sends to the wrong address."))
        #expect(row.update.switchedOn == true)
    }

    @Test("an index nobody signed fetches no manifest at all")
    func unsignedIndex() async throws {
        let shop = try await Self.shop(updates: nil)
        let engine = try #require(shop.engine)
        let index: JSONValue = .object([
            "khayt": .string("index"), "format": .number(1), "serial": .number(99),
            "issuedAt": .string("2026-11-14T00:00:00Z"), "expiresAt": .string("2026-12-20T00:00:00Z"),
            "connectors": .array([.object([
                "id": .string(Self.lamhaId), "kind": .string("connector"), "version": .string("9.0.0"),
                "url": .string("https://khaytapp.com/connectors/lamha-9.0.0.json"),
                "sha256": .string(String(repeating: "0", count: 64)), "size": .number(100)])]),
            "signature": .object(["keyId": .string("khayt-2026-11"), "sig": .string(Data(count: 64).base64EncodedString())]),
        ])
        let asked = Asked()
        shop.connectorFetch = { url, _ in
            await asked.add(url)
            return try JSONEncoder().encode(index)
        }
        let prepared = try #require(await shop.prepareConnectorCheck(engine: engine))
        #expect(Shop.object(prepared.ctx)["signedBy"] == .null)
        #expect(prepared.fetched == .object([:]))
        #expect(await asked.urls == [Shop.connectorIndexURL], "only the index was fetched")
    }

    @Test("a manifest is taken only when its bytes match the index and Khayt signed it")
    func manifestTrust() async throws {
        let shop = try await Self.shop(updates: nil)
        let engine = try #require(shop.engine)
        let bytes = try ConnectorInstallTests.sample("lamha-shipping")
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(await shop.verifiedConnectorManifest(bytes, sha256: sha, engine: engine) != nil)
        #expect(await shop.verifiedConnectorManifest(bytes, sha256: sha.uppercased(), engine: engine) != nil)
        #expect(await shop.verifiedConnectorManifest(bytes, sha256: String(repeating: "a", count: 64), engine: engine) == nil)
        // The right hash of bytes Khayt did not sign.
        let unsigned = try JSONEncoder().encode(try Self.widened())
        let usha = SHA256.hash(data: unsigned).map { String(format: "%02x", $0) }.joined()
        #expect(await shop.verifiedConnectorManifest(unsigned, sha256: usha, engine: engine) == nil)
        // Over the hand-install limit.
        let big = Data(repeating: 0x20, count: Shop.connectorManifestMaxBytes + 1)
        let bsha = SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined()
        #expect(await shop.verifiedConnectorManifest(big, sha256: bsha, engine: engine) == nil)
    }

    @Test("an update writes plugins and connectorUpdates, and nothing else of the settings")
    func writesOnlyItsOwn() {
        let before: [String: JSONValue] = ["bizEn": .string("Athar"), "plugins": .array([]),
                                           "connectorUpdates": .object(["serial": .number(1)])]
        let next: [String: JSONValue] = ["bizEn": .string("Someone else"), "plugins": .array([.object([:])]),
                                         "vatRate": .number(0)]
        let out = Shop.withConnectorState(before, from: next)
        #expect(out["bizEn"] == .string("Athar"))
        #expect(out["vatRate"] == nil)
        #expect(out["plugins"] == .array([.object([:])]))
        #expect(out["connectorUpdates"] == nil, "a key the lib dropped is dropped")
    }

    @Test("the check is off unless both switches are on")
    func switchedOff() {
        #expect(!ConnectorUpdatesSwitch.isOn(environment: [:], defaults: UserDefaults(suiteName: "cu-\(UUID())")!))
        #expect(!ConnectorUpdatesSwitch.isOn(environment: ["KHAYT_CONNECTOR_UPDATES": "1"],
                                             defaults: UserDefaults(suiteName: "cu-\(UUID())")!))
        #expect(ConnectorUpdatesSwitch.isOn(environment: ["KHAYT_CONNECTORS": "1", "KHAYT_CONNECTOR_UPDATES": "1"],
                                            defaults: UserDefaults(suiteName: "cu-\(UUID())")!))
    }
}

private actor Asked {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}

/// The update sheet as drawn, beside Figma 70:284 (light) and 72:478 (dark). Only with KHAYT_SNAPSHOT_DIR set; nothing is asserted
/// about pixels.
@Suite @MainActor struct ConnectorUpdateSheetSnapshotTests {
    @Test("the update sheet and its lists render in light and dark")
    func sheet() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = try await ConnectorUpdatesTests.shop(updates: ["pending": .object([
            "version": .string("9.0.0"), "manifest": try ConnectorUpdatesTests.widened(),
            "offeredAt": .string("2026-11-14T10:00:00Z")])])
        let review = try #require(await shop.connectorUpdateReview(ConnectorUpdatesTests.lamhaId))
        let snap = SnapshotTests()
        // The lists the sheet scrolls: a whole-sheet render leaves a
        // ScrollView's contents blank, which is all the ink check would see.
        let lists = ConnectorUpdateLists(shop: shop, review: review).padding(20).frame(width: 480, alignment: .top)
        let lsize = CGSize(width: 480, height: 900)
        try snap.render(lists.background(Khayt.ground), "81-connector-update-lists", size: lsize)
        try snap.renderDark(lists, "81-connector-update-lists-dark", size: lsize)
    }
}
