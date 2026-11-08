import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Connectors on the phone (`Connectors.swift`): the last checks before
/// anything leaves, the keys, and the two consents.
final class ConnectorsTests: XCTestCase {

    private let domains = ["courier.example.com"]

    // MARK: The URL guard

    func testOnlyHttpsToADeclaredHostGoes() throws {
        XCTAssertEqual(try ConnectorRules.guardURL("https://courier.example.com/v1/x?a=1", domains: domains).get().host(),
                       "courier.example.com")
        XCTAssertNotNil(try? ConnectorRules.guardURL("https://Courier.Example.com/", domains: domains).get(),
                        "a host's case is not a different host")
    }

    func testAnyOtherSchemeIsRefused() {
        for url in ["http://courier.example.com/", "javascript:alert(1)", "file:///etc/hosts",
                    "khayt://order/1", "ftp://courier.example.com/", "not a url", ""] {
            guard case .failure(.notHTTPS) = ConnectorRules.guardURL(url, domains: domains) else {
                return XCTFail("\(url) was let through")
            }
        }
    }

    func testAnUndeclaredHostCredentialsOrAPortAreRefused() {
        let cases = ["https://evil.example.org/", "https://courier.example.com.evil.org/",
                     "https://user:pw@courier.example.com/", "https://courier.example.com:8443/",
                     "https://sub.courier.example.com/"]
        for url in cases {
            guard case .failure(.undeclaredHost) = ConnectorRules.guardURL(url, domains: domains) else {
                return XCTFail("\(url) was let through")
            }
        }
    }

    // MARK: What the phone adds

    /// The well-known HMAC-SHA256 vector: key "key", the quick brown fox.
    func testSignatureIsLowercaseHexHmacSha256OfTheBodyBytes() {
        let sig = ConnectorRules.signature(body: Data("The quick brown fox jumps over the lazy dog".utf8), key: "key")
        XCTAssertEqual(sig, "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    }

    func testAuthHeaderIsSchemeSpaceSecretOrTheSecretAlone() {
        XCTAssertEqual(ConnectorRules.authValue(scheme: "Bearer", secret: "abc"), "Bearer abc")
        XCTAssertEqual(ConnectorRules.authValue(scheme: "", secret: "abc"), "abc")
    }

    func testAKeyLivesInItsOwnKeychainItem() {
        XCTAssertEqual(ConnectorRules.keychainName(pluginId: "com.example.ship", secret: "apiKey"),
                       "plugin.com.example.ship.apiKey")
        let id = "test.connector\(UInt32.random(in: 0...UInt32.max))"
        defer { ConnectorKeys.delete(id, "apiKey") }
        XCTAssertFalse(ConnectorKeys.isSet(id, "apiKey"))
        ConnectorKeys.set(id, "apiKey", "s3cret")
        XCTAssertEqual(KeychainHelper.get("plugin.\(id).apiKey"), "s3cret")
        XCTAssertTrue(ConnectorKeys.isSet(id, "apiKey"))
        ConnectorKeys.delete(id, "apiKey")
        XCTAssertFalse(ConnectorKeys.isSet(id, "apiKey"))
    }

    func testOnlyTheSecretsAUrlFillsInAreRead() {
        XCTAssertEqual(ConnectorRules.secretsInURL("https://hooks.slack.com/services/{secret.webhookPath}/{order.id}"),
                       ["webhookPath"])
    }

    // MARK: Paused

    func testAConnectorIsPausedWhenTheManifestAsksForMore() async throws {
        let engine = try KhaytEngine()
        let slack = try Self.sample("slack-notifier")
        let full = try await engine.pluginGrant(slack)
        var narrow = full
        if case .object(var g) = narrow { g["fields"] = .array([]); narrow = .object(g) }

        let wide = try await engine.pluginDiff(granted: narrow, manifest: slack)
        XCTAssertTrue(ConnectorRules.isPaused(granted: narrow, diff: wide))
        let entry: [String: JSONValue] = ["id": .string("app.khayt.samples.slack"), "manifest": slack, "granted": narrow]
        XCTAssertEqual(ConnectorRules.connector(entry: entry, valid: true, diff: wide)?.status, .paused)

        let same = try await engine.pluginDiff(granted: full, manifest: slack)
        XCTAssertFalse(ConnectorRules.isPaused(granted: full, diff: same))
        var granted = entry
        granted["granted"] = full
        XCTAssertEqual(ConnectorRules.connector(entry: granted, valid: true, diff: same)?.status, .active)

        // Never granted is paused; an unreadable manifest is not usable at all.
        XCTAssertTrue(ConnectorRules.isPaused(granted: nil, diff: same))
        XCTAssertEqual(ConnectorRules.connector(entry: granted, valid: false, diff: same)?.status, .invalid)
    }

    /// The sample shop's two connectors: one to press, one waiting on the Mac.
    func testTheSampleShopHasOneActiveAndOnePausedConnector() async throws {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors else { return XCTFail("no sample connectors") }
        var status: [String: Connector.Status] = [:]
        for case .object(let e) in rows {
            let m = try XCTUnwrap(e["manifest"])
            let valid = try await engine.pluginValidate(m)
            guard case .object(let v) = valid else { return XCTFail() }
            let diff = try await engine.pluginDiff(granted: e["granted"] ?? .null, manifest: m)
            let c = try XCTUnwrap(ConnectorRules.connector(entry: e, valid: v["ok"] == .bool(true), diff: diff))
            status[c.id] = c.status
        }
        XCTAssertEqual(status[SampleShop.courierId], .active)
        XCTAssertEqual(status["app.khayt.samples.slack"], .paused)
    }

    /// The courier's POST, built by the shared rule, passes the phone's guard.
    func testTheEngineBuiltRequestPassesTheGuard() async throws {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0],
              let m = e["manifest"] else { return XCTFail() }
        let order: JSONValue = .object(["invoiceNumber": .string("INV-1"), "project": .string("Rack"), "client": .string("Noura")])
        let p = try await engine.pluginPayload(m, trigger: .object(["action": .string("book")]), context: .object(["order": order]))
        guard case .object(let r) = p, case .string(let url)? = r["url"] else { return XCTFail("\(p)") }
        XCTAssertEqual(r["method"], .string("POST"))
        XCTAssertNotNil(try? ConnectorRules.guardURL(url, domains: domains).get())
    }

    // MARK: This phone's confirmation

    func testAConfirmationIsAskedAgainWhenTheGrantChanges() throws {
        let suite = "connectors-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let grant: JSONValue = .object(["version": .string("1.0.0"), "fields": .array([.string("order.number")]),
                                        "domains": .array([.string("courier.example.com")]), "scopes": .array([])])
        let c = Self.connector(granted: grant)
        XCTAssertFalse(ConnectorRules.isConfirmed(c, defaults: defaults))
        ConnectorRules.confirm(c, defaults: defaults)
        XCTAssertTrue(ConnectorRules.isConfirmed(c, defaults: defaults))

        // The same grant, listed in another order, is the same grant.
        let reordered: JSONValue = .object(["scopes": .array([]), "domains": .array([.string("courier.example.com")]),
                                            "fields": .array([.string("order.number")]), "version": .string("1.0.0")])
        XCTAssertTrue(ConnectorRules.isConfirmed(Self.connector(granted: reordered), defaults: defaults))

        for change in [("version", JSONValue.string("1.1.0")),
                       ("fields", .array([.string("order.number"), .string("customer.phone")])),
                       ("domains", .array([.string("courier.example.com"), .string("api.example.com")]))] {
            guard case .object(var g) = grant else { return XCTFail() }
            g[change.0] = change.1
            XCTAssertFalse(ConnectorRules.isConfirmed(Self.connector(granted: .object(g)), defaults: defaults),
                           "a new \(change.0) asks again")
        }
        XCTAssertFalse(ConnectorRules.isConfirmed(Self.connector(granted: nil), defaults: defaults),
                       "nothing granted is never confirmed")

        ConnectorRules.forgetConfirmations(defaults: defaults)
        XCTAssertFalse(ConnectorRules.isConfirmed(c, defaults: defaults))
    }

    // MARK: Unpair

    @MainActor
    func testUnpairDeletesTheKeysAndTheConfirmations() throws {
        let id = "test.unpair\(UInt32.random(in: 0...UInt32.max))"
        ConnectorKeys.set(id, "apiKey", "one")
        ConnectorKeys.set(id, "signingKey", "two")
        let c = Self.connector(id: id, granted: .object(["version": .string("1.0.0")]))
        ConnectorRules.confirm(c)
        XCTAssertTrue(ConnectorRules.isConfirmed(c))

        ConnectionSettings().unpair()

        XCTAssertFalse(ConnectorKeys.isSet(id, "apiKey"))
        XCTAssertFalse(ConnectorKeys.isSet(id, "signingKey"))
        XCTAssertFalse(ConnectorRules.isConfirmed(c))
    }

    /// And Unpair keeps calling it.
    func testUnpairStillCallsTheConnectorSweep() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Services/ConnectionSettings.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "    func unpair() {"))
        let end = try XCTUnwrap(text[start.upperBound...].range(of: "\n    }\n"))
        XCTAssertTrue(text[start.lowerBound..<end.upperBound].contains("ConnectorTraces.forget()"))
    }

    // MARK: Plain words

    func testEverySendableFieldHasPlainWords() async throws {
        // Every key in lib/plugin-manifest.js SENDABLE_FIELDS has a name on the consent screen.
        let lib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "lib/plugin-manifest.js")
        let text = try String(contentsOf: lib, encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"^\s*'((?:order|customer)\.[A-Za-z]+)':\s*\{ from:"#, options: .anchorsMatchLines)
        let keys = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        XCTAssertEqual(keys.count, 17)
        for k in keys {
            XCTAssertNotEqual(ConnectorRules.fieldName(k, in: nil), k, "\(k) has no words")
        }
    }

    // MARK: Helpers

    static func sample(_ name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "plugins/samples/\(name).json")
        return try JSONValue.parse(Data(contentsOf: url))
    }

    static func connector(id: String = "com.example.ship", granted: JSONValue?) -> Connector {
        Connector(id: id, name: "Ship", publisher: "Example", version: "1.0.0", manifest: .object([:]),
                  granted: granted, status: .active, reviewed: false, devMode: false,
                  secrets: [], fields: [], actions: [], domains: [])
    }
}
