import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A connector's refresh (v1.1) and an event's reply, on the Mac, against a
/// made-up courier and a stand-in for the network: no request leaves this
/// machine and the token is a made-up one.
@MainActor
struct ConnectorRefreshTests {

    static let manifest: JSONValue = {
        let json = #"""
        {
          "khayt": {"manifest": 1}, "id": "com.example.courier", "name": {"en": "Courier"},
          "publisher": "Example Ltd", "version": "1.1.0", "domains": ["api.example.com"],
          "secrets": [{"name": "apiKey", "label": {"en": "API key"}, "kind": "apiKey"}],
          "fields": [
            {"key": "courierId", "label": {"en": "Courier order"}, "type": "text", "attach": "order"},
            {"key": "courierStatus", "label": {"en": "Courier status"}, "type": "text", "attach": "order"}
          ],
          "events": [
            {"event": "order_shipped", "url": "https://api.example.com/v1/shipped", "send": ["order.number"],
             "auth": {"header": "Authorization", "scheme": "Bearer", "secret": "apiKey"},
             "response": {"fields": {"courierId": "id"}}}
          ],
          "refresh": {
            "every": 30, "when": "courierId", "method": "GET",
            "url": "https://api.example.com/v1/orders/{field.courierId}",
            "auth": {"header": "Authorization", "scheme": "Bearer", "secret": "apiKey"},
            "response": {"fields": {"courierStatus": "data.status"}}
          },
          "scopes": ["fields.write"]
        }
        """#
        return try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }()

    static func courier() async throws -> (engine: KhaytEngine, entry: JSONValue, words: Words) {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        let valid = try await engine.pluginValidate(manifest)
        #expect(Shop.object(valid)["ok"] == .bool(true), Comment(rawValue: "\(valid)"))
        let entry = try await engine.pluginConsentedEntry(prev: .null, manifest: manifest)
        return (engine, entry, shop.words)
    }

    static let job: JSONValue = .object([
        "id": .string("J-9"), "invoiceNumber": .string("1009"), "status": .string("in_progress"), "rev": .number(5),
        "plugins": .object(["com.example.courier": .object(["courierId": .string("CO 77/1")])]),
    ])

    final class Sent: @unchecked Sendable { var posts: [Connectors.Post] = [] }

    @Test("a refresh is a GET of its URL alone, named refresh, and the reply fills the job's own field")
    func refreshGet() async throws {
        let (engine, entry, _) = try await Self.courier()
        let sent = Sent()
        let outcome = await Shop.connectorSend(
            entry: entry, trigger: .refresh, order: Self.job, customer: nil,
            secrets: ["apiKey": "test-token-not-real"], engine: engine,
            post: { p in sent.posts.append(p); return (200, Data(#"{"data":{"status":"out for delivery","id":"no"}}"#.utf8)) },
            now: Date(), delivery: "dlv_r")
        #expect(outcome == .sent(.object(["courierStatus": .string("out for delivery")])))
        let post = try #require(sent.posts.first)
        #expect(post.method == "GET")
        #expect(post.body.isEmpty)
        #expect(post.url.absoluteString == "https://api.example.com/v1/orders/CO%2077%2F1")
        #expect(post.headers.contains(Connectors.Header("X-Khayt-Event", "refresh")))
        #expect(post.headers.contains(Connectors.Header("X-Khayt-Delivery", "dlv_r")))
        #expect(post.headers.contains(Connectors.Header("Authorization", "Bearer test-token-not-real")))
        #expect(!post.headers.contains { $0.name == "Content-Type" }, "a GET carries no body type")
    }

    @Test("an event's reply fills the job's own field when the manifest gives it a response")
    func eventReply() async throws {
        let (engine, entry, _) = try await Self.courier()
        let outcome = await Shop.connectorSend(
            entry: entry, trigger: .event("order_shipped"), order: Self.job, customer: nil,
            secrets: ["apiKey": "t"], engine: engine,
            post: { _ in (200, Data(#"{"id":"CO-1","courierStatus":"sneaky"}"#.utf8)) },
            now: Date(), delivery: "dlv_e")
        #expect(outcome == .sent(.object(["courierId": .string("CO-1")])))
    }

    @Test("a refresh without its key is refused before anything is sent")
    func refusedWithoutKey() async throws {
        let (engine, entry, words) = try await Self.courier()
        let sent = Sent()
        let outcome = await Shop.connectorSend(entry: entry, trigger: .refresh, order: Self.job, customer: nil,
                                               secrets: [:], engine: engine,
                                               post: { p in sent.posts.append(p); return (200, nil) },
                                               now: Date(), delivery: "dlv_k")
        guard case .refused(let why) = outcome else { Issue.record("sent without a key: \(outcome)"); return }
        #expect(Shop.refusalText(entry: entry, why: why, words: words).contains("API key"))
        #expect(sent.posts.isEmpty)
    }

    @Test("the engine picks due connectors and open jobs as the lib does")
    func dueAndJobs() async throws {
        let (engine, entry, _) = try await Self.courier()
        let refresh = Shop.object(Shop.object(entry)["manifest"])["refresh"] ?? .null
        let t0 = 1_800_000_000_000.0
        #expect(try await engine.pluginRefreshDue(refresh, lastRunMs: 0, nowMs: t0))
        #expect(try await !engine.pluginRefreshDue(refresh, lastRunMs: t0, nowMs: t0 + 29 * 60_000))
        #expect(try await engine.pluginRefreshDue(refresh, lastRunMs: t0, nowMs: t0 + 30 * 60_000))
        var cancelled = Shop.object(Self.job); cancelled["id"] = .string("J-0"); cancelled["status"] = .string("cancelled")
        let jobs = try await engine.pluginRefreshJobs(.array([.object(cancelled), Self.job]), entry: entry, checkedAt: [:])
        #expect(jobs.map { Shop.plainString(Shop.object($0)["id"]) } == ["J-9"])
    }

    @Test("the consent sheet says how often, where, and which jobs")
    func consentLine() async throws {
        let (engine, _, words) = try await Self.courier()
        let consent = try await engine.pluginRefreshConsent(Self.manifest, lang: "en")
        let line = try #require(Shop.refreshLine(consent, words: words))
        #expect(line.contains("30"))
        #expect(line.contains("api.example.com"))
        #expect(line.contains("Courier order"))
        #expect(!line.contains("{"), Comment(rawValue: line))
        #expect(Shop.refreshLine(.null, words: words) == nil)
    }

    @Test("a GET's request line, with no body length")
    func getHead() {
        let url = URL(string: "https://api.example.com/v1/orders/A%2F1?x=1")!
        let head = String(decoding: WebhookClient.requestHead(url, host: "api.example.com", headers: [("X-Khayt-Event", "refresh")],
                                                              length: 0, method: "GET"), as: UTF8.self)
        #expect(head.hasPrefix("GET /v1/orders/A%2F1?x=1 HTTP/1.1\r\n"))
        #expect(!head.contains("Content-Length"))
        let post = String(decoding: WebhookClient.requestHead(url, host: "api.example.com", headers: [], length: 3), as: UTF8.self)
        #expect(post.hasPrefix("POST ") && post.contains("Content-Length: 3"))
    }

    @Test("refresh runs only with connectors on and only on the Mac holding the book")
    func gates() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop+ConnectorRefresh.swift"), encoding: .utf8)
        let pass = try #require(source.range(of: "func refreshConnectors(").map { String(source[$0.lowerBound...].prefix(600)) })
        #expect(pass.contains("ConnectorsSwitch.isOn()"))
        #expect(pass.contains("StoreLock.weOwnIt(build)"))
    }
}
