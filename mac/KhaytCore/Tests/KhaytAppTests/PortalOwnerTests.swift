import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// A canned cloud: answers by method + path, and records every request. No
/// test here reaches a real server.
final class CloudStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { let method: String; let path: String; let auth: String; let body: Data? }
    nonisolated(unsafe) static var answers: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var seen: [Seen] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudStub.self]
        return URLSession(configuration: config)
    }
    static func reset(_ answers: [String: (Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        Self.answers = answers; Self.seen = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path(percentEncoded: true) ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            body = data
        }
        Self.lock.lock()
        Self.seen.append(Seen(method: method, path: path,
                              auth: request.value(forHTTPHeaderField: "authorization") ?? "", body: body))
        let (status, text) = Self.answers[method + " " + path] ?? (404, #"{"error":"not stubbed"}"#)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The shop's side of the customer portal: the requests the Mac sends, the
/// answers it reads, and the rules it asks `lib/portal-owner.js` for.
@MainActor
@Suite(.serialized)
struct PortalOwnerTests {

    static let base = "https://cloud.test"
    static let request = PortalRefresh(kind: "order", pubToken: "tok/1",
                                       payload: .object(["ref": .string("J1")]), customerEmail: "c@x.test")

    static func body(_ s: CloudStub.Seen) -> [String: JSONValue] {
        guard let d = s.body, let v = try? JSONDecoder().decode([String: JSONValue].self, from: d) else { return [:] }
        return v
    }

    @Test("publishing PUTs the job's request to the owner route, with the bearer, and says when the email was not linked")
    func publish() async throws {
        let engine = try KhaytEngine()
        CloudStub.reset(["PUT /v1/shops/S1/published/tok%2F1":
                            (200, #"{"ok":true,"customerEmailLinked":false,"note":"cap"}"#)])
        let note = try await PortalClient.publish(Self.request, baseUrl: Self.base, shopId: "S1", token: "bear",
                                                  engine: engine, session: CloudStub.session())
        #expect(note == "cap")
        let seen = try #require(CloudStub.seen.first)
        #expect(seen.method == "PUT")
        #expect(seen.path == "/v1/shops/S1/published/tok%2F1", "the token is one encoded segment")
        #expect(seen.auth == "Bearer bear")
        let b = Self.body(seen)
        #expect(b["kind"] == .string("order"))
        #expect(b["customerEmail"] == .string("c@x.test"))

        CloudStub.reset(["PUT /v1/shops/S1/published/tok%2F1": (200, #"{"ok":true,"customerEmailLinked":true}"#)])
        let linked = try await PortalClient.publish(Self.request, baseUrl: Self.base, shopId: "S1", token: "bear",
                                                    engine: engine, session: CloudStub.session())
        #expect(linked == nil)
    }

    @Test("a refusal is named: viewer, another shop's link, the rate limit")
    func refusals() async throws {
        let engine = try KhaytEngine()
        for (status, code) in [(403, "viewer"), (409, "other_shop"), (429, "rate"), (404, "not_this_shop")] {
            CloudStub.reset(["PUT /v1/shops/S1/published/tok%2F1": (status, #"{"error":"no"}"#)])
            do {
                _ = try await PortalClient.publish(Self.request, baseUrl: Self.base, shopId: "S1", token: "b",
                                                   engine: engine, session: CloudStub.session())
                Issue.record("HTTP \(status) was taken as a publish")
            } catch PortalClient.Failure.owner(let said) {
                #expect(said.code == code, Comment(rawValue: "HTTP \(status)"))
            }
        }
    }

    @Test("unpublish, the list, the thread and a reply each go to their own owner route")
    func ownerRoutes() async throws {
        let engine = try KhaytEngine()
        CloudStub.reset([
            "DELETE /v1/shops/S1/published/t1": (200, #"{"ok":true}"#),
            "GET /v1/shops/S1/published": (200, #"{"items":[{"token":"t1","action":{"type":"approve"},"payment":{"status":"paid"}}]}"#),
            "GET /v1/shops/S1/published/t1/messages": (200, #"{"messages":[{"from":"shop","text":"b","at":2},{"from":"customer","text":"a","at":1}]}"#),
            "POST /v1/shops/S1/published/t1/message": (200, #"{"ok":true}"#),
        ])
        let s = CloudStub.session()
        try await PortalClient.unpublish(pubToken: "t1", baseUrl: Self.base, shopId: "S1", token: "b", engine: engine, session: s)
        let items = try await PortalClient.listPublished(baseUrl: Self.base, shopId: "S1", token: "b", engine: engine, session: s)
        let thread = try await PortalClient.messages(pubToken: "t1", baseUrl: Self.base, shopId: "S1", token: "b", engine: engine, session: s)
        try await PortalClient.reply(pubToken: "t1", text: "hello", baseUrl: Self.base, shopId: "S1", token: "b", engine: engine, session: s)

        #expect(CloudStub.seen.map(\.method) == ["DELETE", "GET", "GET", "POST"])
        #expect(thread.map(\.text) == ["a", "b"], "oldest first")
        #expect(Self.body(CloudStub.seen[3])["text"] == .string("hello"))
        // Never the customer's public route — PORTAL_READ_GATE closes it.
        #expect(!CloudStub.seen.contains { $0.path.hasPrefix("/v1/p/") })

        let said = try await engine.portalResponse(items: items, pubToken: "t1",
                                                   order: .object(["status": .string("quote")]))
        #expect(said.response == "approved" && said.paid && said.advance)
        let moved = try await engine.portalResponse(items: items, pubToken: "t1",
                                                    order: .object(["status": .string("pending")]))
        #expect(!moved.advance, "a job already past the quote is not moved again")
    }

    @Test("an address that is not https is refused before anything is sent")
    func httpsOnly() async throws {
        let engine = try KhaytEngine()
        CloudStub.reset([:])
        await #expect(throws: PortalClient.Failure.self) {
            try await PortalClient.unpublish(pubToken: "t", baseUrl: "http://cloud.test", shopId: "S1",
                                             token: "b", engine: engine, session: CloudStub.session())
        }
        #expect(CloudStub.seen.isEmpty, "the bearer went to a plain-http address")
    }

    @Test("the rules the Mac asks: the link, a deposit, the trial")
    func rules() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.portalUrl(baseUrl: "https://c.test//", pubToken: "a b") == "https://c.test/p/a%20b")
        let bad = try await engine.portalDepositForm(deposit: "-5", payUrl: "")
        #expect(!bad.ok && bad.error == "deposit")
        let js = try await engine.portalDepositForm(deposit: "", payUrl: "javascript:alert(1)")
        #expect(!js.ok && js.error == "pay_url")
        let good = try await engine.portalDepositForm(deposit: "250", payUrl: "https://pay.test/q")
        #expect(good.ok && good.cloudDeposit == 250 && good.cloudPayUrl == "https://pay.test/q")
        let gate = try await engine.portalTrialGate(cloud: [:], now: Date())
        #expect(gate.allowed, "during beta, and for a shop that never published, the portal is open")
    }

    @Test("the sample book reaches a published job and a quote with a deposit")
    func sampleReaches() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.isPortalPublished("ORD-01000"))
        #expect(!shop.isPortalPublished("ORD-01005"))
        guard case .number(let deposit)? = shop.portalRecord("ORD-01005")?["cloudDeposit"] else {
            Issue.record("the sample quote has no deposit"); return
        }
        #expect(deposit == 150)
        // No cloud in the sample — on purpose: a "connected" sample would sync.
        #expect(!shop.portalReachable)
        #expect(await shop.portalLink(for: "ORD-01000") == nil, "no link without a cloud address")
    }

    @Test("the quote's link sheet and the conversation, photographed")
    func pictures() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first { $0.id == "ORD-01005" })
        let snap = SnapshotTests()
        try snap.render(QuoteLinkSheet(shop: shop, job: job) { _, _ in }.background(Role.bg),
                        "portal-quote-sheet", size: CGSize(width: 460, height: 340))
        let thread = [
            KhaytEngine.PortalMessage(from: "customer", text: "Can it be ready by Thursday?", at: 1),
            KhaytEngine.PortalMessage(from: "shop", text: "Yes — it will be printed tomorrow.", at: 2),
            KhaytEngine.PortalMessage(from: "customer", text: "Great, thank you!", at: 3),
        ]
        try snap.render(PortalMessagesSheet(shop: shop, job: job, preview: thread).background(Role.bg),
                        "portal-messages", size: CGSize(width: 460, height: 420))
        try snap.renderDark(PortalMessagesSheet(shop: shop, job: job, preview: thread),
                            "portal-messages-dark", size: CGSize(width: 460, height: 420))
    }
}
