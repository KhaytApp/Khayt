import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A connector's button pressed on the Mac, against Khayt's signed Lamha
/// sample and a stand-in for the network: no request leaves this machine and
/// the token is a made-up one.
@MainActor
struct ConnectorActionTests {

    static let config: JSONValue = .object([
        "senderName": .string("Studio"), "senderPhone": .string("0500000000"), "senderCity": .string("Riyadh"),
        "senderAddress": .string("King Fahd Rd"), "carrierId": .string("7"),
    ])

    static func lamha(config: JSONValue = config) async throws -> (engine: KhaytEngine, entry: JSONValue, words: Words) {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: try ConnectorInstallTests.sample("lamha-shipping"))
        guard case .object(var e) = try await engine.pluginConsentedEntry(prev: .null, manifest: manifest) else {
            throw CocoaError(.coderReadCorrupt)
        }
        e["config"] = config
        return (engine, .object(e), shop.words)
    }

    static let order: JSONValue = .object([
        "id": .string("J-1"), "invoiceNumber": .string("1001"), "date": .string("2026-11-09"), "total": .number(115),
        "currency": .string("SAR"), "title": .string("Bracket"), "qty": .number(1), "clientId": .string("C-1"), "rev": .number(3),
    ])
    static let customer: JSONValue = .object([
        "id": .string("C-1"), "name": .string("Nora"), "phone": .string("0551234567"),
        "plugins": .object(["app.khayt.samples.lamha": .object(["city": .string("Jeddah")])]),
    ])

    final class Sent: @unchecked Sendable { var posts: [Connectors.Post] = [] }

    @Test("a job shows the connector's button; a customer does not get a job's")
    func buttons() async throws {
        let (_, entry, _) = try await Self.lamha()
        let onJob = Shop.buttons(in: [entry], placement: "order", lang: "ar")
        #expect(onJob.map(\.label) == ["إرسال إلى لمحة"])
        #expect(onJob.first?.opensPage == false)
        #expect(Shop.buttons(in: [entry], placement: "customer", lang: "en").isEmpty)
    }

    @Test("a press sends Lamha's request with its token, and the reply fills the job's own field")
    func press() async throws {
        let (engine, entry, _) = try await Self.lamha()
        let sent = Sent()
        let outcome = await Shop.connectorSend(
            entry: entry, actionId: "record", order: Self.order, customer: Self.customer, settings: nil,
            secrets: ["apiToken": "test-token-not-real"], engine: engine,
            post: { post in
                sent.posts.append(post)
                return (200, Data(#"{"success":true,"order_id":"LM-4242","status":"created"}"#.utf8))
            }, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(outcome == .sent(.object(["lamhaOrderId": .string("LM-4242")])))
        let post = try #require(sent.posts.first)
        #expect(post.url.absoluteString == "https://app.lamha.sa/api/v2/create-order")
        #expect(post.headers.contains(Connectors.Header("X-LAMHA-TOKEN", "test-token-not-real")))
        #expect(post.headers.contains { $0.name == "X-Khayt-Delivery" && $0.value.hasPrefix("dlv_") })
        let body = try JSONDecoder().decode(JSONValue.self, from: post.body)
        guard case .object(let b) = body, case .object(let to)? = b["customer"] else { Issue.record("body"); return }
        #expect(to["City"] == .string("Jeddah"), "the customer's own connector field did not reach the request")
        #expect(b["carrier_id"] == .string("7"))
    }

    @Test("a setting or key left empty sends nothing, and is named by its label")
    func refused() async throws {
        var cfg = Self.config
        if case .object(var o) = cfg { o["senderPhone"] = .string(""); cfg = .object(o) }
        let (engine, entry, words) = try await Self.lamha(config: cfg)
        let sent = Sent()
        let post: Shop.ConnectorPost = { p in sent.posts.append(p); return (200, nil) }

        let noSetting = await Shop.connectorSend(entry: entry, actionId: "record", order: Self.order, customer: Self.customer, settings: nil,
                                                 secrets: ["apiToken": "t"], engine: engine, post: post, now: Date())
        guard case .refused(let why) = noSetting else { Issue.record("sent without a setting: \(noSetting)"); return }
        let text = Shop.refusalText(entry: entry, why: why, words: words)
        #expect(text.contains("Sender phone") || text.contains("جوال المرسل"), Comment(rawValue: text))
        #expect(!text.contains("senderPhone"), Comment(rawValue: text))

        let (engine2, full, _) = try await Self.lamha()
        let noKey = await Shop.connectorSend(entry: full, actionId: "record", order: Self.order, customer: Self.customer, settings: nil,
                                             secrets: [:], engine: engine2, post: post, now: Date())
        guard case .refused(let keyWhy) = noKey else { Issue.record("sent without its token: \(noKey)"); return }
        let keyText = Shop.refusalText(entry: full, why: keyWhy, words: words)
        #expect(keyText.contains("Lamha API token") || keyText.contains("رمز واجهة لمحة"), Comment(rawValue: keyText))
        #expect(sent.posts.isEmpty, "a refused press reached the network")
    }

    @Test("a refused answer, or one that is not JSON, fills nothing")
    func failures() async throws {
        let (engine, entry, _) = try await Self.lamha()
        let bad = await Shop.connectorSend(entry: entry, actionId: "record", order: Self.order, customer: Self.customer, settings: nil,
                                           secrets: ["apiToken": "t"], engine: engine,
                                           post: { _ in (401, Data(#"{"order_id":"X"}"#.utf8)) }, now: Date())
        #expect(bad == .failed("HTTP 401", status: 401))
        let html = await Shop.connectorSend(entry: entry, actionId: "record", order: Self.order, customer: Self.customer, settings: nil,
                                            secrets: ["apiToken": "t"], engine: engine,
                                            post: { _ in (200, Data("<html>ok</html>".utf8)) }, now: Date())
        #expect(html == .sent(.object([:])))
    }

    @Test("a reply written to a job lands in the connector's own field and raises the job's rev")
    func reply() async throws {
        let (engine, entry, _) = try await Self.lamha()
        let before: [String: JSONValue] = ["printLog": .array([Self.order])]
        var after = before
        try await Shop.withConnectorValues(&after, collection: "printLog", id: "J-1", entry: entry, attach: "order",
                                           values: .object(["lamhaOrderId": .string("LM-4242"), "city": .string("no")]),
                                           engine: engine)
        StoreWriter.stampChanged(before: before, after: &after)
        guard case .array(let rows)? = after["printLog"], case .object(let job) = rows[0] else { Issue.record("job"); return }
        #expect(job["plugins"] == .object(["app.khayt.samples.lamha": .object(["lamhaOrderId": .string("LM-4242")])]))
        // The rev going up is what makes a phone's older copy lose (LanServer.foldFromPhone).
        #expect(job["rev"] == .number(4))
    }

    @Test("a field row shows a value, editable only while its connector is on")
    func fields() async throws {
        let (_, entry, _) = try await Self.lamha()
        let plugins = Shop.object(Self.customer)["plugins"]
        let on = Shop.fieldRows([entry], live: ["app.khayt.samples.lamha"], attach: "customer", plugins: plugins, lang: "en")
        #expect(on.map(\.value) == ["Jeddah"])
        #expect(on.first?.editable == true)
        let off = Shop.fieldRows([entry], live: [], attach: "customer", plugins: plugins, lang: "en")
        #expect(off.first?.editable == false)
        #expect(Shop.fieldRows([entry], live: [], attach: "order", plugins: nil, lang: "en").isEmpty,
                "an empty field of a connector that is off is noise")
    }

    @Test("an HTTP answer's body is read by length, by chunks, or to the close")
    func replyBody() {
        let byLength = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}extra".utf8)
        #expect(HTTPReply.body(byLength) == Data("{}".utf8))
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n".utf8)
        #expect(HTTPReply.body(chunked) == Data(#"{"a":1}"#.utf8))
        let toClose = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"b\":2}".utf8)
        #expect(HTTPReply.body(toClose) == Data(#"{"b":2}"#.utf8))
        #expect(HTTPReply.body(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}".utf8)) == nil, "a cut-off answer read as whole")
        #expect(HTTPReply.body(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n{}".utf8)) == nil)
    }
}
