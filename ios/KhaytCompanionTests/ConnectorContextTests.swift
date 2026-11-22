import XCTest
import KhaytCore
@testable import KhaytCompanion

/// What the phone hands the shared payload code besides the records: the
/// book's settings (behind `order.amountDue`) and a clock (behind
/// `{now…}`). Without either, the shared code refuses rather than sending a
/// pre-tax amount or a 1970 expiry, so a phone that forgot them could never
/// send such a connector.
final class ConnectorContextTests: XCTestCase {

    private let now: Int64 = 1_794_312_000_000 // 2026-11-10 12:00 UTC
    private let exclusive: [String: JSONValue] = [
        "currency": .string("SAR"),
        "tax": .object(["mode": .string("exclusive"),
                        "rates": .array([.object(["id": .string("vat"), "label": .string("VAT"), "percent": .number(15)])])]),
    ]
    private let order: [String: JSONValue] = [
        "id": .string("o1"), "price": .number(100), "status": .string("pending"), "currency": .string("SAR"),
    ]
    private let action = Connector.Action(id: "link", label: "Payment link", placement: "order", kind: "post",
                                          url: "https://api.example.com/v1/invoices")

    /// The lib's own payment-link fixture (test/plugin-v11-lib.test.js).
    private func manifest() throws -> JSONValue {
        try JSONValue.parse(Data(#"""
        {"khayt":{"manifest":1},"id":"com.example.paylink","name":{"en":"Pay link"},"publisher":"Example Ltd",
         "version":"1.0.0","domains":["api.example.com"],
         "secrets":[{"name":"apiKey","label":{"en":"Secret key"},"kind":"apiKey"}],
         "fields":[{"key":"linkUrl","label":{"en":"Payment link"},"type":"text","attach":"order"}],
         "actions":[{"id":"link","label":{"en":"Payment link"},"placement":"order","kind":"post",
           "url":"https://api.example.com/v1/invoices",
           "body":{"format":"json-template","template":{"amount":"{order.amountDueMinor}","currency":"{order.currency}",
             "expires_at":"{now.plusDays.7.epochMs}","created":"{now.epochMs}"}},
           "auth":{"header":"Authorization","secret":"apiKey","encode":"basic"},
           "response":{"fields":{"linkUrl":"url"}}}],
         "scopes":["fields.write"]}
        """#.utf8))
    }

    private func prepared(_ engine: KhaytEngine, settings: [String: JSONValue]?, nowMs: Int64?) async throws -> ConnectorRules.Prepared {
        let m = try manifest()
        let made = ConnectorRules.context(action: action, order: order, customer: nil, config: [:],
                                          settings: settings, nowMs: nowMs) { _ in nil }
        let payload = try await engine.pluginPayload(m, trigger: .object(["action": .string("link")]), context: made.context)
        return try ConnectorRules.prepare(payload: payload, manifest: m, action: action, secrets: ["apiKey": "sk_test"],
                                          delivery: Connectors.newDeliveryId(), now: Date())
    }

    func testWithSettingsAndAClockTheAmountDueAndExpiryAreRight() async throws {
        let engine = try KhaytEngine()
        guard case .post(let post) = try await prepared(engine, settings: exclusive, nowMs: now) else {
            return XCTFail("not a POST")
        }
        guard case .object(let body) = try JSONValue.parse(post.body) else { return XCTFail("body") }
        // 100 + 15% exclusive VAT, in halalas.
        XCTAssertEqual(body["amount"], .number(11500))
        XCTAssertEqual(body["created"], .number(Double(now)))
        XCTAssertEqual(body["expires_at"], .number(Double(now + 7 * 86_400_000)))
        // HTTP Basic comes from the shared Connectors.post.
        let auth = post.headers.first { $0.name == "Authorization" }?.value
        XCTAssertEqual(auth, "Basic " + Data("sk_test:".utf8).base64EncodedString())
    }

    func testWithoutTheShopSettingsTheAmountDueIsRefused() async throws {
        let engine = try KhaytEngine()
        do {
            _ = try await prepared(engine, settings: nil, nowMs: now)
            XCTFail("sent without settings")
        } catch Connectors.Refusal.notBuilt(let why) {
            XCTAssertTrue(why.contains("settings"), why)
        }
    }

    func testWithoutAClockTheExpiryIsRefused() async throws {
        let engine = try KhaytEngine()
        do {
            _ = try await prepared(engine, settings: exclusive, nowMs: nil)
            XCTFail("sent without a clock")
        } catch Connectors.Refusal.notBuilt(let why) {
            XCTAssertTrue(why.contains("clock"), why)
        }
    }

    func testTheClockIsWholeEpochMilliseconds() {
        XCTAssertEqual(ConnectorRules.nowMs(Date(timeIntervalSince1970: 1_794_312_000.9876)), 1_794_312_000_987)
    }

    /// Both places the phone builds a payload pass the two keys (a source
    /// check: the tap itself needs a book and the network).
    func testBothPayloadSitesPassSettingsAndTheClock() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("KhaytCompanion/Services/Connectors.swift"), encoding: .utf8)
        let calls = src.components(separatedBy: "ConnectorRules.context(").dropFirst()
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            let head = String(call.prefix(300))
            XCTAssertTrue(head.contains("settings: connectorSettings()"), head)
            XCTAssertTrue(head.contains("nowMs: ConnectorRules.nowMs()"), head)
        }
    }
}
