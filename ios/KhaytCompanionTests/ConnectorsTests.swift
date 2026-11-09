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
    /// Both are Khayt's real signed samples, verified the way any book's
    /// connector is (`KhaytAPIClient.connectors`): no bypass.
    func testTheSampleShopHasOneActiveAndOnePausedConnector() async throws {
        let engine = try KhaytEngine()
        let keys = await ConnectorRules.signingKeys(engine)
        guard case .array(let rows) = SampleShop.sampleConnectors else { return XCTFail("no sample connectors") }
        XCTAssertEqual(rows.count, 2)
        var status: [String: Connector.Status] = [:]
        var signed: [String: Bool] = [:]
        for case .object(let e) in rows {
            let m = try XCTUnwrap(e["manifest"])
            let check = try await engine.pluginCheckEntry(.object(e))
            let canonical = try await engine.pluginCanonicalJSON(m)
            let real = Connectors.reviewedBy(manifest: m, canonical: canonical, keys: keys) != nil
            let c = try XCTUnwrap(ConnectorRules.connector(entry: e, check: check, reviewed: real))
            status[c.id] = c.status
            signed[c.id] = real
        }
        XCTAssertEqual(status[SampleShop.lamhaId], .active)
        XCTAssertEqual(status["app.khayt.samples.slack"], .paused)
        XCTAssertEqual(signed[SampleShop.lamhaId], true)
        XCTAssertEqual(signed["app.khayt.samples.slack"], true)
        // And they are the shipped samples: Lamha byte for byte, Slack as JSON.
        guard case .object(let lamhaEntry) = rows[0], case .object(let slackEntry) = rows[1] else { return XCTFail() }
        let file = try String(contentsOf: Self.sampleURL("lamha-shipping"), encoding: .utf8)
        XCTAssertEqual(SampleShop.lamhaManifestJSON, file)
        XCTAssertEqual(lamhaEntry["manifest"], try Self.sample("lamha-shipping"))
        XCTAssertEqual(slackEntry["manifest"], try Self.sample("slack-notifier"))
        // Granted exactly what lib's grantFor gives, with fields.write only.
        let grant = try await engine.pluginGrant(try Self.sample("lamha-shipping"))
        XCTAssertEqual(lamhaEntry["granted"], grant)
        guard case .object(let g)? = lamhaEntry["granted"] else { return XCTFail() }
        XCTAssertEqual(g["scopes"], .array([.string("fields.write")]))
    }

    /// The sample's Lamha button builds its request from the sample records
    /// and the entry's settings, as the Mac would.
    func testTheSampleLamhaButtonBuildsWithTheSettings() async throws {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0] else { return XCTFail() }
        let check = try await engine.pluginCheckEntry(.object(e))
        let c = try XCTUnwrap(ConnectorRules.connector(entry: e, check: check, reviewed: true))
        XCTAssertEqual(c.actions.map(\.id), ["record"])
        XCTAssertEqual(c.settings.map(\.key), ["senderName", "senderPhone", "senderCity", "senderAddress", "carrierId"])
        XCTAssertEqual(ConnectorRules.missingSettings(c), [])
        let store = SampleShop.book()
        func row(_ k: String, _ id: String) -> [String: JSONValue]? {
            guard case .array(let a)? = store[k] else { return nil }
            for case .object(let o) in a where o["id"] == .string(id) { return o }
            return nil
        }
        let order = try XCTUnwrap(row("printLog", "S-1041"))
        let customer = try XCTUnwrap(row("clients", "C-1"))
        XCTAssertEqual(ConnectorRules.fieldValue(customer, pluginId: c.id, key: "city"), .string("Riyadh"))
        XCTAssertEqual(ConnectorRules.fieldValue(row("printLog", "S-1046"), pluginId: c.id, key: "lamhaOrderId"),
                       .string("48213"))
        let action = c.actions[0]
        let made = ConnectorRules.context(action: action, order: order, customer: customer, config: c.config) { _ in "t" }
        let payload = try await engine.pluginPayload(c.manifest, trigger: .object(["action": .string("record")]),
                                                     context: made.context)
        guard case .object(let p) = payload, case .string(let body)? = p["body"],
              case .object(let sent) = try JSONValue.parse(Data(body.utf8)),
              case .object(let shipper)? = sent["shipper"], case .object(let to)? = sent["customer"] else {
            return XCTFail("\(payload)")
        }
        XCTAssertEqual(shipper["name"], .string("Khayt sample studio"))
        XCTAssertEqual(shipper["City"], .string("Riyadh"))
        XCTAssertEqual(sent["carrier_id"], .string("7"))
        XCTAssertEqual(sent["create_shippment"], .bool(false))
        XCTAssertEqual(to["City"], .string("Riyadh"))
    }

    /// How App Review (no Mac) sees a connector: the sample shop's tap runs
    /// the whole shared check with stand-in keys, sends nothing, and fills the
    /// job's Lamha order from the sample reply through the shared mapping.
    func testTheSampleShopWalksThroughASendWithoutSending() async throws {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0] else { return XCTFail() }
        let check = try await engine.pluginCheckEntry(.object(e))
        let c = try XCTUnwrap(ConnectorRules.connector(entry: e, check: check, reviewed: true))
        let action = c.actions[0]
        let store = SampleShop.book()
        guard case .array(let jobs)? = store["printLog"], case .object(let order)? = jobs.first(where: {
            if case .object(let o) = $0 { return o["id"] == .string("S-1041") } else { return false }
        }) else { return XCTFail("no S-1041") }
        let made = ConnectorRules.context(action: action, order: order, customer: nil, config: c.config) { _ in nil }
        let payload = try await engine.pluginPayload(c.manifest, trigger: .object(["action": .string("record")]),
                                                     context: made.context)
        let standIns = Dictionary(uniqueKeysWithValues: ConnectorRules.secretNames(for: action, manifest: c.manifest)
            .map { ($0, "sample") })
        let prepared = try ConnectorRules.prepare(payload: payload, manifest: c.manifest, action: action,
                                                  secrets: standIns, delivery: Connectors.newDeliveryId(), now: Date())
        guard case .post(let post) = prepared else { return XCTFail("\(prepared)") }
        XCTAssertEqual(post.url.host(), "app.lamha.sa")

        let reply = try XCTUnwrap(SampleShop.simulatedReply(connectorId: c.id, actionId: action.id))
        let mapped = try await engine.pluginApplyResponse(c.manifest, actionId: action.id, reply: reply, entry: c.entry)
        XCTAssertEqual(mapped, .object(["lamhaOrderId": .string("48214")]))
        XCTAssertEqual(KhaytAPIClient.replyLines(mapped, connector: c).count, 1)
        XCTAssertNil(SampleShop.simulatedReply(connectorId: "app.khayt.samples.slack", actionId: "record"))
    }

    /// Release builds hold no sample connector until launch day, when this
    /// flips with khaytapp.com/privacy (#147) live. Update this test then.
    func testTheSampleConnectorsWaitForLaunchDay() {
        XCTAssertFalse(ConnectorLaunch.launched,
                       "flip only in the launch build, once khaytapp.com/privacy describes connectors")
    }

    // MARK: The request, through the shared code

    /// The local courier manifest with a signing key on "book", so every
    /// header the shared code adds can be seen.
    private func signedCourier() throws -> JSONValue {
        guard case .object(var m) = Self.courier, case .array(var actions)? = m["actions"],
              case .object(var book) = actions[0], case .array(var secrets)? = m["secrets"] else { throw XCTSkip("no courier") }
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

    /// The shared check refuses another host, a user name and any port but
    /// 443; the phone has no check of its own on top.
    func testAnUndeclaredHostAUserOrAPortIsRefused() throws {
        let m = Self.courier
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
        // :8443 is refused by the shared KhaytCore.Connectors itself, the Mac's
        // own path, not by anything the phone adds; :443 spelled out is fine.
        XCTAssertThrowsError(try Connectors.link(from: open("https://courier.example.com:8443/t"), manifest: m)) {
            guard case .undeclaredHost? = $0 as? Connectors.Refusal else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try Connectors.post(from: post("https://courier.example.com:8443/x"), manifest: m,
                                                 event: "book", secrets: [:], delivery: "d", now: Date()))
        XCTAssertNoThrow(try Connectors.link(from: open("https://courier.example.com:443/t"), manifest: m))
    }

    // MARK: The customer as the book keeps it

    /// The editors save `nameEn`/`nameAr` and an `addresses[]` book; the
    /// phone hands the customer record over as it is, and the shared rule
    /// reads those.
    func testACustomerWithAnArabicNameOnlyAndAnAddressBookIsSent() async throws {
        let engine = try KhaytEngine()
        let m = Self.courier
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
        var e = Self.entry(Self.courier, granted: .object([:]))
        let ok: JSONValue = .object(["ok": .bool(true), "errors": .array([]), "paused": .bool(false)])
        XCTAssertEqual(ConnectorRules.connector(entry: e, check: ok)?.status, .notReviewed, "no signature, no review")
        e["reviewed"] = .bool(true)
        e["devMode"] = .bool(true)
        let c = try XCTUnwrap(ConnectorRules.connector(entry: e, check: ok))
        XCTAssertFalse(c.reviewed)
        XCTAssertEqual(c.status, .notReviewed)
        let check = try await engine.pluginCheckEntry(.object(e))
        XCTAssertEqual(ConnectorRules.connector(entry: e, check: check, reviewed: true)?.status, .invalid)
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

    /// The entry's settings go in as `ctx.config` (an empty object when it
    /// has none), and the shared rule refuses a required one left unset.
    func testTheEntrysConfigGoesIntoThePayload() async throws {
        let open = Connector.Action(id: "o", label: "O", placement: "order", kind: "open", url: "")
        guard case .object(let none) = ConnectorRules.context(action: open, order: nil, customer: nil) { _ in nil }.context
        else { return XCTFail() }
        XCTAssertEqual(none["config"], .object([:]))

        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0] else { return XCTFail() }
        let c = try XCTUnwrap(ConnectorRules.connector(entry: e, check: nil))
        let record = c.actions[0]
        let order: [String: JSONValue] = ["id": .string("J-1"), "invoiceNumber": .string("INV-1"), "project": .string("Lid")]
        let made = ConnectorRules.context(action: record, order: order, customer: nil, config: c.config) { _ in nil }
        guard case .object(let ctx) = made.context else { return XCTFail() }
        XCTAssertEqual(ctx["config"], e["config"])
        let built = try await engine.pluginPayload(c.manifest, trigger: .object(["action": .string("record")]),
                                                   context: made.context)
        guard case .object(let b) = built else { return XCTFail() }
        XCTAssertEqual(b["ok"], .bool(true), "\(built)")

        // Without the Mac's settings: refused, by the setting's key, and the
        // phone names it by its label.
        var unset = c.config
        unset["senderName"] = .string("")
        let bare = ConnectorRules.context(action: record, order: order, customer: nil, config: unset) { _ in nil }
        let refused = try await engine.pluginPayload(c.manifest, trigger: .object(["action": .string("record")]),
                                                     context: bare.context)
        guard case .object(let r) = refused else { return XCTFail() }
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertEqual(r["error"], .string("setting senderName is not set"))
        XCTAssertEqual(ConnectorRules.unsetSetting("setting senderName is not set"), "senderName")
        XCTAssertNil(ConnectorRules.unsetSetting("not a link"))
        var emptied = e
        emptied["config"] = .object(["senderName": .string("")])
        let partial = try XCTUnwrap(ConnectorRules.connector(entry: emptied, check: nil))
        XCTAssertEqual(ConnectorRules.missingSettings(partial),
                       ["senderName", "senderPhone", "senderCity", "senderAddress", "carrierId"]
                        .compactMap { k in partial.settings.first { $0.key == k }?.label })
        XCTAssertEqual(ConnectorRules.fieldName("config.senderCity", in: partial),
                       partial.settings.first { $0.key == "senderCity" }?.label)
    }

    /// The shared rule maps a reply into the connector's fields only when the
    /// stored entry grants `fields.write` (and is not paused); the phone
    /// hands it the entry and shows what comes back.
    func testTheEngineMapsAReplyOnlyWithFieldsWrite() async throws {
        let engine = try KhaytEngine()
        guard case .array(let rows) = SampleShop.sampleConnectors, case .object(let e) = rows[0],
              let m = e["manifest"] else { return XCTFail() }
        let reply: JSONValue = .object(["success": .bool(true), "order_id": .number(48213)])
        let granted = try await engine.pluginApplyResponse(m, actionId: "record", reply: reply, entry: .object(e))
        XCTAssertEqual(granted, .object(["lamhaOrderId": .string("48213")]))

        var narrow = e
        if case .object(var g)? = e["granted"] { g["scopes"] = .array([]); narrow["granted"] = .object(g) }
        let refused = try await engine.pluginApplyResponse(m, actionId: "record", reply: reply, entry: .object(narrow))
        XCTAssertEqual(refused, .object([:]))
    }

    // MARK: Helpers

    static func sampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "plugins/samples/\(name).json")
    }

    static func sample(_ name: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: sampleURL(name)))
    }

    /// An unsigned courier manifest for the tests that need what no signed
    /// sample has: an "open" button and a customer button.
    static let courier: JSONValue = (try? JSONValue.parse(Data(#"{"khayt":{"manifest":1},"id":"com.example.courier","name":{"en":"Courier booking","ar":"حجز المندوب"},"publisher":"Example","version":"1.0.0","domains":["courier.example.com"],"secrets":[{"name":"apiKey","label":{"en":"API key","ar":"مفتاح API"},"kind":"apiKey"}],"fields":[{"key":"awb","label":{"en":"Waybill","ar":"بوليصة الشحن"},"type":"text","attach":"order"},{"key":"account","label":{"en":"Courier account","ar":"حساب المندوب"},"type":"text","attach":"customer"}],"actions":[{"id":"book","label":{"en":"Book a pickup","ar":"حجز استلام"},"placement":"order","kind":"post","url":"https://courier.example.com/v1/pickups","send":["order.number","order.title","customer.name","customer.phone","customer.address"],"auth":{"header":"Authorization","scheme":"Bearer","secret":"apiKey"},"response":{"fields":{"awb":"data.waybill"}}},{"id":"track","label":{"en":"Track on the courier's site","ar":"التتبع في موقع المندوب"},"placement":"order","kind":"open","url":"https://courier.example.com/track?ref={field.awb}"},{"id":"account","label":{"en":"Open courier account","ar":"فتح حساب المندوب"},"placement":"customer","kind":"open","url":"https://courier.example.com/accounts?email={customer.email}"}],"scopes":["fields.write"]}"#.utf8))) ?? .null

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
