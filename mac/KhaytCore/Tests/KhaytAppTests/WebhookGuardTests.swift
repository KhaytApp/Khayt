import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Where an outbound webhook may go.
///
/// ── THIS IS THE SECURITY-RELEVANT ONE ─────────────────────────────────────
///
/// The URL is typed by the shop, so this is a request the app makes to an
/// address a person chose — the shape of every SSRF hole ever written. The
/// consequence of getting it wrong is that a page on a shop's LAN, or a cloud
/// metadata endpoint, is reachable by putting its address in a settings field.
///
/// The rule is `lib/host-ranges.js` and is SHARED, which is the whole point:
/// almost every line of it is a hole somebody already found once. What follows
/// checks that the shared rule really is what the Mac asks, and that the
/// spellings which have slipped past before still do not.
@MainActor
struct WebhookGuardTests {

    // MARK: - The name layer

    @Test("every private and loopback spelling is refused")
    func theSpellingsThatHide() async throws {
        // Each of these is a way of writing an address that must never be
        // reached, and the exotic ones are in this list because they have gone
        // through before — `127.0.0.1` was blocked while `[::1]` was not, and
        // the tests passed the one shape that worked.
        let engine = try KhaytEngine()
        let mustBlock = [
            "localhost", "127.0.0.1", "127.1.1.1",
            "[::1]", "::1",
            "::ffff:127.0.0.1",        // IPv4-mapped, dotted
            "::ffff:7f00:1",           // the same address, as WHATWG URL spells it
            "2130706433",              // 127.0.0.1 as one number
            "0x7f000001",              // and as hex
            "10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.1",
            "169.254.169.254",         // cloud metadata
            "fe80::1", "fd00::1", "fc00::1",
            "0.0.0.0",
        ]
        for host in mustBlock {
            #expect(try await engine.isBlockedHost(host),
                    Comment(rawValue: "\(host) would be allowed"))
        }
    }

    @Test("an ordinary public host is allowed, or the feature is useless")
    func publicHostsPass() async throws {
        let engine = try KhaytEngine()
        for host in ["example.com", "hooks.slack.com", "8.8.8.8",
                     "api.khaytapp.com", "2606:4700:4700::1111"] {
            #expect(!(try await engine.isBlockedHost(host)),
                    Comment(rawValue: "\(host) is blocked, so no webhook can be sent anywhere"))
        }
    }

    @Test("the numeric-IPv4 canonicaliser is actually reached")
    func canonicaliserIsWired() async throws {
        // `host-ranges` asks `printer-host` for it THROUGH THE GLOBAL, at call
        // time. A load-time capture is null whenever printer-host loads later,
        // and the failure is silent: `2130706433` stops being canonicalised and
        // is treated as an ordinary hostname.
        let engine = try KhaytEngine()
        #expect(try await engine.isBlockedHost("2130706433"),
                "the numeric spelling of 127.0.0.1 is not being canonicalised")
    }

    // MARK: - The address layer

    @Test("a public NAME that resolves to a private address is refused")
    func resolutionIsCheckedToo() async throws {
        // The layer the name check cannot do. `localtest.me` and its siblings
        // are public names whose A record is 127.0.0.1 — exactly the shape of
        // the attack, and one nobody has to control a DNS server to use.
        //
        // Resolution needs the network, so this asserts the MECHANISM rather
        // than a live lookup: every address a host resolves to is put through
        // the same rule, and an answer in a blocked range refuses the delivery.
        let engine = try KhaytEngine()
        let answers = WebhookClient.resolve("localhost")
        #expect(!answers.isEmpty, "nothing resolved at all — the resolver is not working")
        var blockedOne = false
        for address in answers where try await engine.isBlockedHost(address) {
            blockedOne = true
        }
        #expect(blockedOne, Comment(rawValue: "resolved \(answers) and blocked none of them"))
    }

    @Test("a link-local answer keeps its prefix after the zone is trimmed")
    func zonesAreTrimmed() async throws {
        // `getnameinfo` returns `fe80::1%en0`, and the rule matches on the
        // `fe80:` prefix — which still matches. What must not happen is the
        // zone being left on something that then matches nothing.
        let engine = try KhaytEngine()
        #expect(try await engine.isBlockedHost("fe80::1"),
                "a link-local address is not blocked")
    }

    @Test("a scheme that is not https never reaches the network")
    func onlyHttp() async throws {
        let engine = try KhaytEngine()
        // Plain http is on this list on purpose: the other app refuses it too,
        // and a webhook over http carries a shop's order data and its HMAC in
        // the clear.
        for bad in ["file:///etc/passwd", "ftp://example.com/x", "gopher://example.com/",
                    "http://example.com/hook"] {
            guard let url = URL(string: bad) else { continue }
            var threw = false
            do {
                _ = try await WebhookClient.deliver(.object([:]), to: url, secret: "",
                                                    event: "order.status", engine: engine)
            } catch { threw = true }
            #expect(threw, Comment(rawValue: "\(bad) was not refused"))
        }
    }

    @Test("a blocked host is refused before anything is sent")
    func blockedNeverSends() async throws {
        let engine = try KhaytEngine()
        // https, every one. Over http they would be refused for the SCHEME —
        // the assertion below would still pass, on `blocked("http")`, and the
        // guard this test exists for would never have run.
        for bad in ["https://127.0.0.1:8080/hook",
                    "https://[::1]:8080/hook",
                    "https://169.254.169.254/latest/meta-data/",
                    "https://10.0.0.5/hook"] {
            guard let url = URL(string: bad) else {
                Issue.record(Comment(rawValue: "could not parse \(bad)")); continue
            }
            var said = ""
            do {
                _ = try await WebhookClient.deliver(.object([:]), to: url, secret: "",
                                                    event: "order.status", engine: engine)
                Issue.record(Comment(rawValue: "\(bad) was delivered to"))
            } catch { said = String(describing: error) }
            // The CASE, not the sentence. `String(describing:)` on the enum
            // gives `blocked("127.0.0.1")`, not the `errorDescription`.
            #expect(said.hasPrefix("blocked("),
                    Comment(rawValue: "\(bad) refused with: \(said)"))
        }
    }

    // MARK: - The body and the signature

    /// A completed job, and a shop with BOTH webhook systems switched on.
    static func book() -> (order: JSONValue, settings: [String: JSONValue]) {
        let order = JSONValue.object([
            "id": .string("ORD-01042"), "project": .string("Coffee dallah stand"),
            "client": .string("Maha"), "status": .string("completed"),
            "price": .number(450), "dueDate": .string("2026-09-20"),
        ])
        let settings: [String: JSONValue] = [
            "webhooks": .object([
                "enabled": .bool(true),
                "subscriptions": .array([
                    .object(["id": .string("whs_a"), "url": .string("https://a.example.com/h"),
                             "events": .array([.string("status_changed")]),
                             "secret": .string("s3cret"), "enabled": .bool(true)]),
                    .object(["id": .string("whs_b"), "url": .string("https://b.example.com/h"),
                             "events": .array([.string("payment_received")]),
                             "enabled": .bool(true)]),
                ]),
            ]),
            "eventWebhooks": .object([
                "enabled": .bool(true), "url": .string("https://c.example.com/orders"),
                "secret": .string("other"),
            ]),
        ]
        return (order, settings)
    }

    @Test("a completed move addresses both webhook systems, and only the listeners")
    func bothSystems() async throws {
        let engine = try KhaytEngine()
        let (order, settings) = Self.book()
        let owed = try await engine.webhookDeliveries(
            order: order,
            effects: [
                .init(kind: "webhook", event: "status_changed", newStatus: "completed"),
                .init(kind: "order_webhook", event: "status", newStatus: nil),
                .init(kind: "webhook", event: "order_delivered", newStatus: nil),
            ],
            settings: settings, shopName: "Tuwaiq Additive", clientName: "Maha",
            currency: "SAR", at: "2026-09-13T10:00:00.000Z", nowMs: 1_789_000_000_000)

        // `whs_b` listens for a payment and must not be told about a status;
        // `order_delivered` has no listener at all. So: one bus delivery and
        // one order webhook.
        #expect(owed.map(\.url) == ["https://a.example.com/h", "https://c.example.com/orders"],
                Comment(rawValue: "addressed \(owed.map(\.url))"))
        #expect(owed[0].secret == "s3cret", "the subscription's own secret is not used")
        #expect(owed[1].secret == "other")
        // The two systems have two event vocabularies, and neither is renamed.
        #expect(owed[0].event == "status_changed")
        #expect(owed[1].event == "order.status")
        // The id carries the subscription, so two consumers of one event do not
        // dedupe each other's delivery away.
        #expect(owed[0].deliveryId.hasSuffix("_whs_a"),
                Comment(rawValue: "delivery id was \(owed[0].deliveryId)"))
    }

    @Test("what goes on the wire is the envelope the other app has always posted")
    func theWireBody() async throws {
        let engine = try KhaytEngine()
        let (order, settings) = Self.book()
        let owed = try await engine.webhookDeliveries(
            order: order,
            effects: [.init(kind: "webhook", event: "status_changed", newStatus: "completed")],
            settings: settings, shopName: "Tuwaiq Additive", clientName: "Maha",
            currency: "SAR", at: "2026-09-13T10:00:00.000Z", nowMs: 1_789_000_000_000)
        let one = try #require(owed.first)

        // ── THE SHAPE IS `main.js` hub:fire-webhook's, NOT A NEW ONE ──────
        //
        // `{ event, payload, timestamp }` with the delivery body NESTED in
        // `payload` — a consumer's parser is written against this, and the
        // signature is over exactly these bytes.
        guard case .object(let wire) = one.body else { Issue.record("no body"); return }
        #expect(wire["event"] == JSONValue.string("status_changed"))
        #expect(wire["timestamp"] == JSONValue.number(1_789_000_000_000))
        guard case .object(let body)? = wire["payload"] else {
            Issue.record("the delivery body is not nested in `payload`"); return
        }
        #expect(body["id"] == JSONValue.string(one.deliveryId),
                "the id in the body is not the one this delivery is called")
        #expect(body["version"] == JSONValue.number(1))
        guard case .object(let payload)? = body["payload"] else {
            Issue.record("no payload"); return
        }
        #expect(payload["orderId"] == JSONValue.string("ORD-01042"))
        #expect(payload["newStatus"] == JSONValue.string("completed"))
        #expect(payload["client"] == JSONValue.string("Maha"))
    }

    @Test("a shop with nothing switched on is not told anything")
    func nothingConfigured() async throws {
        let engine = try KhaytEngine()
        let (order, _) = Self.book()
        for settings: [String: JSONValue] in [
            [:],
            // Subscriptions, but the system itself is off.
            ["webhooks": .object(["enabled": .bool(false),
                                  "subscriptions": .array([
                                    .object(["id": .string("x"),
                                             "url": .string("https://a.example.com/h"),
                                             "events": .array([.string("status_changed")]),
                                             "enabled": .bool(true)])])])],
            // A URL that is not https — refused by the rule, not by the client.
            ["eventWebhooks": .object(["enabled": .bool(true),
                                       "url": .string("http://c.example.com/orders")])],
            // And the per-event switch.
            ["eventWebhooks": .object(["enabled": .bool(true),
                                       "url": .string("https://c.example.com/orders"),
                                       "events": .object(["status": .bool(false)])])],
        ] {
            let owed = try await engine.webhookDeliveries(
                order: order,
                effects: [.init(kind: "webhook", event: "status_changed", newStatus: "completed"),
                          .init(kind: "order_webhook", event: "status", newStatus: nil)],
                settings: settings, shopName: "Tuwaiq Additive", clientName: "Maha",
                currency: "SAR", at: "2026-09-13T10:00:00.000Z", nowMs: 1)
            #expect(owed.isEmpty, Comment(rawValue: "addressed \(owed.map(\.url))"))
        }
    }

    @Test("which subscriptions want an event is the shared rule's answer")
    func subscriptionsMatch() async throws {
        let engine = try KhaytEngine()
        let webhooks = JSONValue.object(["subscriptions": .array([
            .object(["id": .string("A"), "url": .string("https://a.example.com/h"),
                     "events": .array([.string("status_changed")]), "enabled": .bool(true)]),
            .object(["id": .string("B"), "url": .string("https://b.example.com/h"),
                     "events": .array([.string("payment_received")]), "enabled": .bool(true)]),
            .object(["id": .string("C"), "url": .string("https://c.example.com/h"),
                     "events": .array([.string("status_changed")]), "enabled": .bool(false)]),
        ])])
        let want = try await engine.webhookSubscriptions(webhooks, event: "status_changed")
        #expect(want.map(\.id) == ["A"],
                Comment(rawValue: "matched \(want.map(\.id)) — B wants another event, C is off"))
    }

    @Test("the two apps agree about retrying, and about 410")
    func retryPolicyIsShared() async throws {
        let engine = try KhaytEngine()
        // A consumer answering 410 Gone is saying stop for good.
        let gone = try await engine.webhookNext(status: 410, attempt: 1)
        #expect(gone.gone)
        #expect(!gone.retry, "a 410 was retried")
        // Success is not retried.
        #expect(!(try await engine.webhookNext(status: 200, attempt: 1).retry))
        #expect(!(try await engine.webhookNext(status: 204, attempt: 1).retry))
        // A fault is, and the wait grows.
        let first = try await engine.webhookNext(status: 500, attempt: 1)
        let third = try await engine.webhookNext(status: 500, attempt: 3)
        #expect(first.retry && third.retry)
        #expect(third.afterMs > first.afterMs, "the backoff does not back off")
    }
}

/// That the guard is what the client actually uses.
@MainActor
struct WebhookWiringTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    /// The same file with its COMMENTS REMOVED.
    ///
    /// ── AN ASSERTION THAT MATCHES ITS OWN PROSE PROVES NOTHING ────────────
    ///
    /// "The client carries no copy of the blocked ranges" was checked by
    /// searching for `169.254` — and found it, in the paragraph at the top of
    /// the file explaining that the ranges are shared and not copied. Likewise
    /// `URLSession.shared` appears in the comment saying why it is not used.
    ///
    /// Both assertions failed against correct code. A source-reading test has to
    /// read the CODE, or it is testing the documentation.
    static func code(_ file: String) throws -> String {
        let text = try source(file)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return "" }
                // A trailing comment on a line of code, with `://` in a URL
                // left alone.
                guard let at = line.range(of: "//") else { return String(line) }
                if line[..<at.lowerBound].hasSuffix(":") { return String(line) }
                return String(line[..<at.lowerBound])
            }
            .joined(separator: "\n")
    }

    @Test("both layers of the guard are in the delivery path")
    func bothLayers() throws {
        let client = try Self.code("WebhookClient.swift")
        #expect(client.contains("engine.isBlockedHost(host)"), "the name is never checked")
        #expect(client.contains("for address in resolve(host)"),
                "the resolved addresses are never checked — a public name pointing inward passes")
        // And no Swift copy of the ranges.
        #expect(!client.contains("169.254") && !client.contains("192.168"),
                "the client carries its own copy of the blocked ranges")
    }

    @Test("the deliveries a move owes are actually sent")
    func theyAreSent() throws {
        // ── THE BUG THIS CATCHES IS A CORRECT MODULE WITH NO CALLER ───────
        //
        // Everything above can pass with `applyMove` handing back a list that
        // nothing posts. Delete the `fire(owed)` line and this is the only test
        // in the suite that notices.
        let shop = try WebhookWiringTests.code("Shop.swift")
        #expect(shop.contains("await fire(owed)"),
                "a move addresses its webhooks and never sends them")
        #expect(shop.contains("WebhookClient.deliver("),
                "nothing in the app posts a webhook")
        // AFTER the write. A consumer told about a job that was not saved is
        // worse than a consumer told nothing.
        guard let wrote = shop.range(of: "registerMoveUndo("),
              let sent = shop.range(of: "await fire(owed)") else {
            Issue.record("the move no longer writes or no longer sends"); return
        }
        #expect(wrote.lowerBound < sent.lowerBound,
                "the webhook goes out before the move is known to have been written")
    }

    @Test("the signature is the spelling a consumer of the other app verifies")
    func signatureSpelling() throws {
        // `hub:fire-webhook` writes the hex alone, and it is the transport every
        // delivery from the other app goes through. The prefixed spelling is
        // the one nobody receives — see WebhookClient for the whole story.
        let client = try WebhookWiringTests.code("WebhookClient.swift")
        #expect(!client.contains("\"sha256=\""),
                "the signature carries a prefix the other app does not send")
        #expect(client.contains("X-Khayt-Signature"))
    }

    @Test("redirects are not followed")
    func noRedirects() throws {
        // A consumer answering 302 to a metadata endpoint would walk straight
        // past both layers.
        let client = try Self.code("WebhookClient.swift")
        #expect(client.contains("willPerformHTTPRedirection"),
                "the session follows redirects, which defeats the guard")
        #expect(client.contains("completionHandler(nil)"), "the redirect is followed anyway")
        #expect(!client.contains("URLSession.shared"),
                "URLSession.shared follows redirects")
    }
}
