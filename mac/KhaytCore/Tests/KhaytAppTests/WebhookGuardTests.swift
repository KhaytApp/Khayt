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

    @Test("a scheme that is not http(s) never reaches the network")
    func onlyHttp() async throws {
        let engine = try KhaytEngine()
        for bad in ["file:///etc/passwd", "ftp://example.com/x", "gopher://example.com/"] {
            guard let url = URL(string: bad) else { continue }
            var threw = false
            do {
                _ = try await WebhookClient.deliver(.object([:]), to: url, secret: "",
                                                    event: "order.status",
                                                    deliveryId: "dlv_1", engine: engine)
            } catch { threw = true }
            #expect(threw, Comment(rawValue: "\(bad) was not refused"))
        }
    }

    @Test("a blocked host is refused before anything is sent")
    func blockedNeverSends() async throws {
        let engine = try KhaytEngine()
        for bad in ["http://127.0.0.1:8080/hook",
                    "http://[::1]:8080/hook",
                    "http://169.254.169.254/latest/meta-data/",
                    "http://10.0.0.5/hook"] {
            guard let url = URL(string: bad) else {
                Issue.record(Comment(rawValue: "could not parse \(bad)")); continue
            }
            var said = ""
            do {
                _ = try await WebhookClient.deliver(.object([:]), to: url, secret: "",
                                                    event: "order.status",
                                                    deliveryId: "dlv_1", engine: engine)
                Issue.record(Comment(rawValue: "\(bad) was delivered to"))
            } catch { said = String(describing: error) }
            // The CASE, not the sentence. `String(describing:)` on the enum
            // gives `blocked("127.0.0.1")`, not the `errorDescription`.
            #expect(said.hasPrefix("blocked("),
                    Comment(rawValue: "\(bad) refused with: \(said)"))
        }
    }

    // MARK: - The body and the signature

    @Test("the delivery body is the shared shape, with the id as the idempotency key")
    func bodyIsShared() async throws {
        let engine = try KhaytEngine()
        let order = JSONValue.object([
            "id": .string("ORD-01042"), "project": .string("Coffee dallah stand"),
            "status": .string("completed"), "price": .number(450),
            "dueDate": .string("2026-09-20"),
        ])
        let body = try await engine.webhookBody(
            event: "status", order: order, shopName: "Tuwaiq Additive",
            clientName: "Maha", currency: "SAR",
            at: "2026-09-13T10:00:00.000Z", deliveryId: "dlv_abc123")
        guard case .object(let o) = body else { Issue.record("no body"); return }
        #expect(o["id"] == JSONValue.string("dlv_abc123"),
                "the delivery id is not the idempotency key")
        #expect(o["event"] == JSONValue.string("order.status"))
        #expect(o["version"] == JSONValue.number(1))
        guard case .object(let payload)? = o["payload"],
              case .object(let ord)? = payload["order"] else {
            Issue.record("no order in the payload"); return
        }
        #expect(ord["id"] == JSONValue.string("ORD-01042"))
        #expect(ord["currency"] == JSONValue.string("SAR"))
    }

    @Test("which subscriptions want an event is the shared rule's answer")
    func subscriptionsMatch() async throws {
        let engine = try KhaytEngine()
        let webhooks = JSONValue.object(["subscriptions": .array([
            .object(["id": .string("A"), "url": .string("https://a.example.com/h"),
                     "events": .array([.string("order.status")]), "enabled": .bool(true)]),
            .object(["id": .string("B"), "url": .string("https://b.example.com/h"),
                     "events": .array([.string("order.paid")]), "enabled": .bool(true)]),
            .object(["id": .string("C"), "url": .string("https://c.example.com/h"),
                     "events": .array([.string("order.status")]), "enabled": .bool(false)]),
        ])])
        let want = try await engine.webhookSubscriptions(webhooks, event: "order.status")
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
