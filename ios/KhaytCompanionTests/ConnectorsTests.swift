import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Connectors on the phone (`Connectors.swift`): the last checks before
/// anything leaves, the keys, and the two consents.
final class ConnectorsTests: XCTestCase {

    private let domains = ["courier.example.com"]

    // MARK: The phone's keys

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
        let entry = Self.entry(slack, granted: narrow)

        let paused = try await engine.pluginCheckEntry(.object(entry))
        XCTAssertEqual(ConnectorRules.connector(entry: entry, check: paused, reviewed: true)?.status, .paused)

        var granted = entry
        granted["granted"] = full
        let fine = try await engine.pluginCheckEntry(.object(granted))
        XCTAssertEqual(ConnectorRules.connector(entry: granted, check: fine, reviewed: true)?.status, .active)
        // Signed and granted, but not reviewed: still nothing.
        XCTAssertEqual(ConnectorRules.connector(entry: granted, check: fine, reviewed: false)?.status, .notReviewed)
        // Turned off on the Mac.
        var off = granted
        off["enabled"] = .bool(false)
        let offCheck = try await engine.pluginCheckEntry(.object(off))
        XCTAssertEqual(ConnectorRules.connector(entry: off, check: offCheck, reviewed: true)?.status, .off)
        // No check at all is not a working connector.
        XCTAssertEqual(ConnectorRules.connector(entry: granted, check: nil, reviewed: true)?.status, .invalid)
    }

    /// A grant wider than the signed manifest, or a stray key, is refused
    /// by the shared check: the connector is invalid, not merely paused.
    func testAnEntryTheSharedCheckRefusesIsInvalid() async throws {
        let engine = try KhaytEngine()
        let slack = try Self.sample("slack-notifier")
        let full = try await engine.pluginGrant(slack)
        guard case .object(var g) = full else { return XCTFail() }
        g["domains"] = .array([.string("hooks.slack.com"), .string("evil.example.org")])
        let wider = Self.entry(slack, granted: .object(g))
        let check = try await engine.pluginCheckEntry(.object(wider))
        XCTAssertEqual(ConnectorRules.connector(entry: wider, check: check, reviewed: true)?.status, .invalid)

        var flagged = Self.entry(slack, granted: full)
        flagged["reviewed"] = .bool(true)
        let flaggedCheck = try await engine.pluginCheckEntry(.object(flagged))
        XCTAssertEqual(ConnectorRules.connector(entry: flagged, check: flaggedCheck, reviewed: true)?.status, .invalid)
    }

    /// The sample shop's two connectors: one to press, one waiting on the Mac.
    func testTheSampleShopHasOneActiveAndOnePausedConnector() async throws {
        let engine = try KhaytEngine()
        let keys = await ConnectorRules.signingKeys(engine)
        guard case .array(let rows) = SampleShop.sampleConnectors else { return XCTFail("no sample connectors") }
        var status: [String: Connector.Status] = [:]
        var signed: [String: Bool] = [:]
        for case .object(let e) in rows {
            let m = try XCTUnwrap(e["manifest"])
            let check = try await engine.pluginCheckEntry(.object(e))
            let canonical = try await engine.pluginCanonicalJSON(m)
            let real = Connectors.reviewedBy(manifest: m, canonical: canonical, keys: keys) != nil
            let c = try XCTUnwrap(ConnectorRules.connector(entry: e, check: check,
                                                            reviewed: real || SampleShop.isSampleConnector(e)))
            status[c.id] = c.status
            signed[c.id] = real
        }
        XCTAssertEqual(status[SampleShop.courierId], .active)
        XCTAssertEqual(status["app.khayt.samples.slack"], .paused)
        // The Slack one is reviewed by Khayt's real signature, not the bypass;
        // the bypass covers the courier alone.
        XCTAssertEqual(signed["app.khayt.samples.slack"], true)
        XCTAssertEqual(signed[SampleShop.courierId], false)
        guard case .object(let slackEntry) = rows[1] else { return XCTFail() }
        XCTAssertFalse(SampleShop.isSampleConnector(slackEntry))
        // And it is the shipped sample, byte for byte as JSON.
        XCTAssertEqual(slackEntry["manifest"], try Self.sample("slack-notifier"))
    }

    // MARK: The request, through the shared code

    /// The courier's sample manifest with a signing key on "book", so every
    /// header the shared code adds can be seen.
    private func signedCourier() throws -> JSONValue {
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0],
              case .object(var m)? = e["manifest"], case .array(var actions)? = m["actions"],
              case .object(var book) = actions[0], case .array(var secrets)? = m["secrets"] else { throw XCTSkip("no sample") }
        secrets.append(.object(["name": .string("signingKey"), "label": .object(["en": .string("Signing key")]),
                                "kind": .string("signingKey")]))
        book["signWith"] = .string("signingKey")
        actions[0] = .object(book)
        m["actions"] = .array(actions)
        m["secrets"] = .array(secrets)
        return .object(m)
    }

    private static let book = Connector.Action(id: "book", label: "Book", placement: "order", kind: "post",
                                               url: "https://courier.example.com/v1/pickups")

    func testATapReadsOnlyTheSecretsItsActionNeeds() throws {
        let m = try signedCourier()
        XCTAssertEqual(ConnectorRules.secretNames(for: Self.book, manifest: m), ["apiKey", "signingKey"])
        let slack = Connector.Action(id: "x", label: "X", placement: "order", kind: "post",
                                     url: "https://hooks.slack.com/services/{secret.webhookPath}")
        XCTAssertEqual(ConnectorRules.secretNames(for: slack, manifest: .object([:])), ["webhookPath"])
        let open = Connector.Action(id: "track", label: "T", placement: "order", kind: "open",
                                    url: "https://courier.example.com/{secret.apiKey}")
        XCTAssertEqual(ConnectorRules.secretNames(for: open, manifest: m), [], "a link needs no key")
    }

    /// A POST goes out with the shared headers: the auth header, the three
    /// signature headers and the delivery id, from `KhaytCore.Connectors`.
    func testAPostCarriesTheSharedHeaders() async throws {
        let engine = try KhaytEngine()
        let m = try signedCourier()
        let order: JSONValue = .object(["invoiceNumber": .string("INV-1"), "project": .string("Rack"), "client": .string("Noura")])
        let payload = try await engine.pluginPayload(m, trigger: .object(["action": .string("book")]),
                                                     context: .object(["order": order]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prepared = try ConnectorRules.prepare(payload: payload, manifest: m, action: Self.book,
                                                  secrets: ["apiKey": "k1", "signingKey": "s1"], delivery: "dlv_test", now: now)
        guard case .post(let post) = prepared else { return XCTFail("\(prepared)") }
        XCTAssertEqual(post.url.absoluteString, "https://courier.example.com/v1/pickups")
        let h = Dictionary(post.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(h["Authorization"], "Bearer k1")
        XCTAssertEqual(h["X-Khayt-Event"], "book", "a press is named by its action id")
        XCTAssertEqual(h["X-Khayt-Delivery"], "dlv_test")
        XCTAssertEqual(h["X-Khayt-Timestamp"], "1800000000")
        XCTAssertEqual(h["X-Khayt-Signature"]?.count, 64)
        XCTAssertEqual(h["X-Khayt-Signature-V2"]?.count, 64)
        // The same request the Mac would build from the same payload.
        let mac = try Connectors.post(from: payload, manifest: m, event: "book",
                                      secrets: ["apiKey": "k1", "signingKey": "s1"], delivery: "dlv_test", now: now)
        XCTAssertEqual(post, mac)

        XCTAssertThrowsError(try ConnectorRules.prepare(payload: payload, manifest: m, action: Self.book,
                                                        secrets: ["apiKey": "k1"], delivery: "d", now: now)) {
            XCTAssertEqual($0 as? Connectors.Refusal, .missingSecret("signingKey"))
        }
    }

    /// The shared check refuses another host and a user name; the phone adds
    /// a port, which the shared check does not look at.
    func testAnUndeclaredHostAUserOrAPortIsRefused() throws {
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0],
              let m = e["manifest"] else { return XCTFail() }
        func post(_ url: String) -> JSONValue {
            .object(["ok": .bool(true), "method": .string("POST"), "url": .string(url), "body": .string("{}"),
                     "auth": .null, "signWith": .null])
        }
        func open(_ url: String) -> JSONValue {
            .object(["ok": .bool(true), "method": .string("OPEN"), "url": .string(url)])
        }
        let track = Connector.Action(id: "track", label: "T", placement: "order", kind: "open", url: "")
        XCTAssertNoThrow(try ConnectorRules.prepare(payload: post("https://courier.example.com/x"), manifest: m,
                                                    action: Self.book, secrets: [:], delivery: "d", now: Date()))
        XCTAssertEqual(try ConnectorRules.prepare(payload: open("https://courier.example.com/t?a=1"), manifest: m,
                                                  action: track, secrets: [:], delivery: "d", now: Date()),
                       .open(URL(string: "https://courier.example.com/t?a=1")!))
        for url in ["https://evil.example.org/x", "https://sub.courier.example.com/x", "http://courier.example.com/x",
                    "https://user:pw@courier.example.com/x", "https://courier.example.com:8443/x"] {
            XCTAssertThrowsError(try ConnectorRules.prepare(payload: post(url), manifest: m, action: Self.book,
                                                            secrets: [:], delivery: "d", now: Date()), url)
            XCTAssertThrowsError(try ConnectorRules.prepare(payload: open(url), manifest: m, action: track,
                                                            secrets: [:], delivery: "d", now: Date()), url)
        }
        // A port the shared check lets through on its own: the phone's gap check is still needed.
        XCTAssertNoThrow(try Connectors.post(from: post("https://courier.example.com:8443/x"), manifest: m, event: "book",
                                             secrets: [:], delivery: "d", now: Date()),
                         "the shared check now refuses a port: drop ConnectorRules.refusePort")
    }

    // MARK: The customer as the book keeps it

    /// The editors save `nameEn`/`nameAr` and an `addresses[]` book; the
    /// phone hands the customer record over as it is, and the shared rule
    /// reads those.
    func testACustomerWithAnArabicNameOnlyAndAnAddressBookIsSent() async throws {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0],
              let m = e["manifest"] else { return XCTFail() }
        let customer: [String: JSONValue] = [
            "id": .string("C-9"), "nameAr": .string("نورة العتيبي"), "phone": .string("+966500000000"),
            "addresses": .array([.object(["label": .string("Home"), "address": .string("")]),
                                 .object(["label": .string("Work"), "address": .string("King Fahd Rd, Riyadh")])]),
        ]
        let order: [String: JSONValue] = ["id": .string("J-1"), "invoiceNumber": .string("INV-9"), "project": .string("Rack")]
        let made = ConnectorRules.context(action: Self.book, order: order, customer: customer) { _ in nil }
        let payload = try await engine.pluginPayload(m, trigger: .object(["action": .string("book")]), context: made.context)
        guard case .object(let p) = payload, case .string(let body)? = p["body"],
              case .object(let sent) = try JSONValue.parse(Data(body.utf8)), case .object(let data)? = sent["data"] else {
            return XCTFail("\(payload)")
        }
        XCTAssertEqual(data["customer.name"], .string("نورة العتيبي"))
        XCTAssertEqual(data["customer.address"], .string("King Fahd Rd, Riyadh"), "the first address that has one")

        // An English name wins over the Arabic one, as lib/customer-records.js nameOf.
        var both = customer
        both["nameEn"] = .string("Noura Alotaibi")
        let again = ConnectorRules.context(action: Self.book, order: order, customer: both) { _ in nil }
        let p2 = try await engine.pluginPayload(m, trigger: .object(["action": .string("book")]), context: again.context)
        guard case .object(let q) = p2, case .string(let b2)? = q["body"] else { return XCTFail() }
        XCTAssertTrue(b2.contains("Noura Alotaibi"))
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

    /// The shipped samples are signed with Khayt's key, and the engine's keys
    /// verify them. One field changed and they do not.
    func testTheShippedSamplesVerifyAgainstKhaytsRealKeys() async throws {
        let engine = try KhaytEngine()
        let keys = await ConnectorRules.signingKeys(engine)
        XCTAssertFalse(keys.isEmpty, "lib SIGNING_KEYS")
        for name in ["slack-notifier", "discord-notifier", "sheets-log"] {
            let m = try Self.sample(name)
            let canonical = try await engine.pluginCanonicalJSON(m)
            XCTAssertEqual(Connectors.reviewedBy(manifest: m, canonical: canonical, keys: keys), "khayt-2026-11", name)

            guard case .object(var o) = m else { return XCTFail() }
            o["publisher"] = .string("Not Khayt")
            let changed = try await engine.pluginCanonicalJSON(.object(o))
            XCTAssertNil(Connectors.reviewedBy(manifest: .object(o), canonical: changed, keys: keys), name)
            // Nor does the old signature over the changed bytes pass with a
            // different domain swapped in.
            guard case .object(var d) = m else { return XCTFail() }
            d["domains"] = .array([.string("evil.example.org")])
            let swapped = try await engine.pluginCanonicalJSON(.object(d))
            XCTAssertNil(Connectors.reviewedBy(manifest: .object(d), canonical: swapped, keys: keys), name)
        }
    }

    /// A book can say `reviewed: true` (or `devMode`); the phone does not
    /// listen. The shared check refuses the key outright, and even a status
    /// worked out without that check is not reviewed from a flag.
    func testAStoredReviewedFlagIsIgnored() async throws {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(var e) = rows[0] else { return XCTFail() }
        let ok: JSONValue = .object(["ok": .bool(true), "errors": .array([]), "paused": .bool(false)])
        XCTAssertEqual(ConnectorRules.connector(entry: e, check: ok)?.status, .notReviewed, "no signature, no review")
        e["reviewed"] = .bool(true)
        e["devMode"] = .bool(true)
        let c = try XCTUnwrap(ConnectorRules.connector(entry: e, check: ok))
        XCTAssertFalse(c.reviewed)
        XCTAssertEqual(c.status, .notReviewed)
        let check = try await engine.pluginCheckEntry(.object(e))
        XCTAssertEqual(ConnectorRules.connector(entry: e, check: check, reviewed: true)?.status, .invalid)
        // And the sample shop's own path: an entry that is not exactly its own is not one.
        XCTAssertFalse(SampleShop.isSampleConnector(e))
    }

    /// Not reviewed: the buttons are off and a tap sends nothing.
    @MainActor
    func testANotReviewedConnectorSendsNothing() async throws {
        let c = Connector(id: "com.example.ship", name: "Ship", publisher: "Example", version: "1.0.0",
                          manifest: .object([:]), granted: .object([:]), entry: .object([:]),
                          status: .notReviewed, reviewed: false,
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

    /// The shared rule maps a reply into the connector's fields only when the
    /// stored entry grants `fields.write` (and is not paused); the phone
    /// hands it the entry and shows what comes back.
    func testTheEngineMapsAReplyOnlyWithFieldsWrite() async throws {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0],
              let m = e["manifest"] else { return XCTFail() }
        let reply: JSONValue = .object(["data": .object(["waybill": .string("EX-1")])])
        let granted = try await engine.pluginApplyResponse(m, actionId: "book", reply: reply, entry: .object(e))
        XCTAssertEqual(granted, .object(["awb": .string("EX-1")]))

        var narrow = e
        if case .object(var g)? = e["granted"] { g["scopes"] = .array([]); narrow["granted"] = .object(g) }
        let refused = try await engine.pluginApplyResponse(m, actionId: "book", reply: reply, entry: .object(narrow))
        XCTAssertEqual(refused, .object([:]))
    }

    // MARK: Helpers

    static func sample(_ name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "plugins/samples/\(name).json")
        return try JSONValue.parse(Data(contentsOf: url))
    }

    /// A stored entry for `manifest`, in the shape the Mac writes.
    static func entry(_ manifest: JSONValue, granted: JSONValue) -> [String: JSONValue] {
        guard case .object(let m) = manifest else { return [:] }
        return ["id": m["id"] ?? .null, "version": m["version"] ?? .null, "enabled": .bool(true),
                "manifest": manifest, "granted": granted, "config": .object([:])]
    }

    static func connector(id: String = "com.example.ship", granted: JSONValue?) -> Connector {
        Connector(id: id, name: "Ship", publisher: "Example", version: "1.0.0", manifest: .object([:]),
                  granted: granted, entry: .object([:]), status: .active, reviewed: true,
                  secrets: [], fields: [], actions: [], domains: [])
    }
}
