import CryptoKit
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
        XCTAssertEqual(ConnectorRules.connector(entry: entry, valid: true, diff: wide, reviewed: true)?.status, .paused)

        let same = try await engine.pluginDiff(granted: full, manifest: slack)
        XCTAssertFalse(ConnectorRules.isPaused(granted: full, diff: same))
        var granted = entry
        granted["granted"] = full
        XCTAssertEqual(ConnectorRules.connector(entry: granted, valid: true, diff: same, reviewed: true)?.status, .active)

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
            let c = try XCTUnwrap(ConnectorRules.connector(entry: e, valid: v["ok"] == .bool(true), diff: diff,
                                                            reviewed: SampleShop.isSampleConnector(e)))
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

    // MARK: Reviewed: Khayt's signature, never a stored flag

    /// A manifest signed with a key made here, over the engine's canonical bytes.
    private func signed(_ key: Curve25519.Signing.PrivateKey) async throws -> (manifest: JSONValue, engine: KhaytEngine) {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0],
              case .object(var m)? = e["manifest"] else { throw XCTSkip("no sample") }
        let canonical = try await engine.pluginCanonicalJSON(.object(m))
        let sig = try key.signature(for: Data(canonical.utf8))
        m["signature"] = .string(sig.base64EncodedString())
        // The canonical bytes leave the signature out.
        let again = try await engine.pluginCanonicalJSON(.object(m))
        XCTAssertEqual(again, canonical)
        return (.object(m), engine)
    }

    private func pub(_ key: Curve25519.Signing.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    func testASignatureFromKhaytsKeyIsReviewed() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let (m, engine) = try await signed(key)
        let canonical = try await engine.pluginCanonicalJSON(m)
        guard case .object(let o) = m, case .string(let sig)? = o["signature"] else { return XCTFail() }
        XCTAssertEqual(sig.count, 88)
        XCTAssertTrue(ConnectorRules.isReviewed(manifest: m, canonical: canonical, keys: [("k1", pub(key))]))

        // One field changed after signing: the bytes are not the ones signed.
        var tampered = o
        tampered["publisher"] = .string("Someone else")
        let tamperedBytes = try await engine.pluginCanonicalJSON(.object(tampered))
        XCTAssertFalse(ConnectorRules.isReviewed(manifest: .object(tampered), canonical: tamperedBytes, keys: [("k1", pub(key))]))

        // Another key.
        let other = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(ConnectorRules.isReviewed(manifest: m, canonical: canonical, keys: [("k2", pub(other))]))

        // Two keys, one of them right: enough.
        XCTAssertTrue(ConnectorRules.isReviewed(manifest: m, canonical: canonical,
                                                keys: [("k2", pub(other)), ("bad", "!!"), ("k1", pub(key))]))

        // No keys at all (today's `signingKeys`): nothing verifies.
        XCTAssertFalse(ConnectorRules.isReviewed(manifest: m, canonical: canonical, keys: []))
        XCTAssertTrue(ConnectorRules.signingKeys.isEmpty, "switch to engine.pluginSigningKeys() when Mac PR 2 lands")
    }

    func testABadOrShortSignatureOrKeyIsNotReviewed() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let (m, engine) = try await signed(key)
        let canonical = try await engine.pluginCanonicalJSON(m)
        guard case .object(let o) = m, case .string(let sig)? = o["signature"] else { return XCTFail() }
        let keys = [(id: "k1", key: pub(key))]
        for bad in ["", "not base64 at all", String(sig.dropLast(4)), Data(repeating: 1, count: 32).base64EncodedString(),
                    String(repeating: "A", count: 86) + "=="] {
            var x = o
            x["signature"] = .string(bad)
            XCTAssertFalse(ConnectorRules.isReviewed(manifest: .object(x), canonical: canonical, keys: keys), bad)
        }
        var none = o
        none.removeValue(forKey: "signature")
        XCTAssertFalse(ConnectorRules.isReviewed(manifest: .object(none), canonical: canonical, keys: keys))
        // A key that is not 32 bytes, or not base64.
        XCTAssertFalse(ConnectorRules.isReviewed(manifest: m, canonical: canonical,
                                                 keys: [("short", Data(repeating: 2, count: 16).base64EncodedString()), ("junk", "%%%")]))
    }

    /// A book can say `reviewed: true` (or `devMode`); the phone does not listen.
    func testAStoredReviewedFlagIsIgnored() throws {
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(var e) = rows[0] else { return XCTFail() }
        e["reviewed"] = .bool(true)
        e["devMode"] = .bool(true)
        let diff: JSONValue = .object(["fields": .array([]), "domains": .array([]), "scopes": .array([]), "widened": .bool(false)])
        let c = try XCTUnwrap(ConnectorRules.connector(entry: e, valid: true, diff: diff))
        XCTAssertFalse(c.reviewed)
        XCTAssertEqual(c.status, .notReviewed)
        // And the sample shop's own path: an entry that is not exactly its own is not one.
        XCTAssertFalse(SampleShop.isSampleConnector(e))
    }

    /// Not reviewed: the buttons are off and a tap sends nothing.
    @MainActor
    func testANotReviewedConnectorSendsNothing() async throws {
        let c = Connector(id: "com.example.ship", name: "Ship", publisher: "Example", version: "1.0.0",
                          manifest: .object([:]), granted: .object([:]), status: .notReviewed, reviewed: false,
                          secrets: [], fields: [],
                          actions: [.init(id: "go", label: "Go", placement: "order", kind: "post", url: "https://courier.example.com/")],
                          domains: domains)
        XCTAssertFalse(c.isActive, "the card disables a button unless isActive")
        XCTAssertEqual(ConnectorRules.disabledReason(c), L10n.tr("connectors.not_reviewed"))
        let api = KhaytAPIClient(settings: ConnectionSettings(), withBook: false)
        let outcome = await api.runConnector(c, action: c.actions[0], at: .order("S-1"))
        XCTAssertEqual(outcome, .failed(L10n.tr("connectors.not_reviewed")))
    }

    // MARK: What goes into the engine

    func testAnOpenLinkIsNeverGivenASecret() {
        var asked: [String] = []
        let open = Connector.Action(id: "o", label: "O", placement: "order", kind: "open",
                                    url: "https://courier.example.com/{secret.apiKey}")
        let made = ConnectorRules.context(action: open, order: ["id": .string("1")], customer: nil) { asked.append($0); return "k" }
        guard case .object(let ctx) = made.context else { return XCTFail() }
        XCTAssertNil(ctx["secrets"])
        XCTAssertNil(made.missing)
        XCTAssertEqual(asked, [], "the Keychain is not even read for a link")

        let post = Connector.Action(id: "p", label: "P", placement: "order", kind: "post",
                                    url: "https://courier.example.com/{secret.apiKey}")
        let sent = ConnectorRules.context(action: post, order: nil, customer: nil) { _ in "k" }
        guard case .object(let pctx) = sent.context else { return XCTFail() }
        XCTAssertEqual(pctx["secrets"], .object(["apiKey": .string("k")]))
        XCTAssertEqual(ConnectorRules.context(action: post, order: nil, customer: nil) { _ in nil }.missing, "apiKey")
    }

    /// A reply is read only when the shop granted `fields.write`.
    func testAReplyIsReadOnlyWithFieldsWrite() {
        XCTAssertTrue(ConnectorRules.mayReadReply(granted: .object(["scopes": .array([.string("orders.read"), .string("fields.write")])])))
        XCTAssertFalse(ConnectorRules.mayReadReply(granted: .object(["scopes": .array([.string("orders.read")])])))
        XCTAssertFalse(ConnectorRules.mayReadReply(granted: .object([:])))
        XCTAssertFalse(ConnectorRules.mayReadReply(granted: nil))
    }

    // MARK: Helpers

    static func sample(_ name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "plugins/samples/\(name).json")
        return try JSONValue.parse(Data(contentsOf: url))
    }

    static func connector(id: String = "com.example.ship", granted: JSONValue?) -> Connector {
        Connector(id: id, name: "Ship", publisher: "Example", version: "1.0.0", manifest: .object([:]),
                  granted: granted, status: .active, reviewed: true,
                  secrets: [], fields: [], actions: [], domains: [])
    }
}
