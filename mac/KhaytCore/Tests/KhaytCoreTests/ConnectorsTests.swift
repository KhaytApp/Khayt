import CryptoKit
import Foundation
import Testing
@testable import KhaytCore

/// The shared Swift half of a connector request: reviewed is a signature that
/// verifies, and the headers that go out are exactly what the manifest and
/// the shop's secrets say — to exactly a host the manifest declared.
struct ConnectorsTests {

    static func manifest(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var m: [String: JSONValue] = ["id": .string("com.example.ship"), "domains": .array([.string("api.example.com")])]
        for (k, v) in extra { m[k] = v }
        return .object(m)
    }

    static func post(_ fields: [String: JSONValue]) -> JSONValue {
        var p: [String: JSONValue] = ["ok": .bool(true), "method": .string("POST"),
                                      "url": .string("https://api.example.com/v1/x"), "body": .string(#"{"a":1}"#),
                                      "auth": .null, "signWith": .null]
        for (k, v) in fields { p[k] = v }
        return .object(p)
    }

    @Test("reviewed: a signature over the canonical bytes, by any listed key")
    func reviewed() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let canonical = #"{"id":"com.example.ship"}"#
        let sig = try signer.signature(for: Data(canonical.utf8)).base64EncodedString()
        let keys: [JSONValue] = [
            .object(["id": .string("old"), "key": .string(other.publicKey.rawRepresentation.base64EncodedString())]),
            .object(["id": .string("new"), "key": .string(signer.publicKey.rawRepresentation.base64EncodedString())]),
        ]
        let m = Self.manifest(["signature": .string(sig)])
        #expect(Connectors.reviewedBy(manifest: m, canonical: canonical, keys: keys) == "new")
        #expect(Connectors.reviewedBy(manifest: m, canonical: canonical + " ", keys: keys) == nil)
        #expect(Connectors.reviewedBy(manifest: m, canonical: canonical, keys: [keys[0]]) == nil)
        #expect(Connectors.reviewedBy(manifest: Self.manifest(), canonical: canonical, keys: keys) == nil)
        #expect(Connectors.reviewedBy(manifest: Self.manifest(["signature": .string("bm90IGEgc2ln")]),
                                      canonical: canonical, keys: keys) == nil)
    }

    @Test("the auth header is the secret, with the scheme only when one is named")
    func authHeader() throws {
        let bearer = Self.post(["auth": .object(["header": .string("Authorization"), "scheme": .string("Bearer"),
                                                 "secret": .string("apiKey")])])
        let p = try Connectors.post(from: bearer, manifest: Self.manifest(), event: "ship",
                                    secrets: ["apiKey": "k1"], delivery: "d1", now: Date(timeIntervalSince1970: 0))
        #expect(p.headers.contains(.init("Authorization", "Bearer k1")))
        let bare = Self.post(["auth": .object(["header": .string("X-Api-Key"), "scheme": .string(""),
                                               "secret": .string("apiKey")])])
        let q = try Connectors.post(from: bare, manifest: Self.manifest(), event: "ship",
                                    secrets: ["apiKey": "k1"], delivery: "d1", now: Date())
        #expect(q.headers.contains(.init("X-Api-Key", "k1")))
        #expect(throws: Connectors.Refusal.missingSecret("apiKey")) {
            try Connectors.post(from: bare, manifest: Self.manifest(), event: "ship", secrets: [:], delivery: "d1", now: Date())
        }
    }

    /// The same bytes `lib/plugin-payload.js authHeaderValue` gives
    /// (test/plugin-v11-lib.test.js): a key with no colon gets one.
    @Test("encode basic: base64 of key + \":\", or of user:password as it is")
    func basicAuth() throws {
        let basic = Self.post(["auth": .object(["header": .string("Authorization"), "scheme": .string("Basic"),
                                                "secret": .string("apiKey"), "encode": .string("basic")])])
        let p = try Connectors.post(from: basic, manifest: Self.manifest(), event: "link",
                                    secrets: ["apiKey": "sk_test_abc"], delivery: "d1", now: Date())
        #expect(p.headers.contains(.init("Authorization", "Basic c2tfdGVzdF9hYmM6")))
        let q = try Connectors.post(from: basic, manifest: Self.manifest(), event: "link",
                                    secrets: ["apiKey": "user:pässword"], delivery: "d1", now: Date())
        #expect(q.headers.contains(.init("Authorization", "Basic " + Data("user:pässword".utf8).base64EncodedString())))
    }

    @Test("signWith gives the same three headers a Khayt webhook carries")
    func signature() throws {
        let p = try Connectors.post(from: Self.post(["signWith": .string("key")]), manifest: Self.manifest(),
                                    event: "order_created", secrets: ["key": "s3cret"], delivery: "d1",
                                    now: Date(timeIntervalSince1970: 1_700_000_000))
        let k = SymmetricKey(data: Data("s3cret".utf8))
        let hex = { (d: Data) in HMAC<SHA256>.authenticationCode(for: d, using: k).map { String(format: "%02x", $0) }.joined() }
        #expect(p.headers.contains(.init("X-Khayt-Signature", hex(Data(#"{"a":1}"#.utf8)))))
        #expect(p.headers.contains(.init("X-Khayt-Timestamp", "1700000000")))
        #expect(p.headers.contains(.init("X-Khayt-Signature-V2", hex(Data(#"1700000000.{"a":1}"#.utf8)))))
        #expect(p.body == Data(#"{"a":1}"#.utf8))
        #expect(p.headers.contains(.init("X-Khayt-Delivery", "d1")))
    }

    @Test("only exactly a declared https host, with no user in the URL")
    func host() throws {
        for bad in ["https://evil.example.org/x", "https://sub.api.example.com/x", "http://api.example.com/x",
                    "https://u:p@api.example.com/x", "https://api.example.com:8443/x"] {
            #expect(throws: (any Error).self, Comment(rawValue: bad)) {
                try Connectors.post(from: Self.post(["url": .string(bad)]), manifest: Self.manifest(),
                                    event: "e", secrets: [:], delivery: "d1", now: Date())
            }
        }
        let open: JSONValue = .object(["ok": .bool(true), "method": .string("OPEN"),
                                       "url": .string("https://api.example.com/t/1")])
        #expect(try Connectors.link(from: open, manifest: Self.manifest()).absoluteString == "https://api.example.com/t/1")
        let explicit443: JSONValue = .object(["ok": .bool(true), "method": .string("OPEN"),
                                              "url": .string("https://api.example.com:443/t/1")])
        #expect((try? Connectors.link(from: explicit443, manifest: Self.manifest())) != nil)
        #expect(throws: Connectors.Refusal.notBuilt("host not declared")) {
            try Connectors.link(from: .object(["ok": .bool(false), "error": .string("host not declared")]),
                                manifest: Self.manifest())
        }
    }

    @Test("end to end with the engine: a signed sample, its payload, its headers")
    func endToEnd() async throws {
        let engine = try KhaytEngine()
        let sheets = try PluginManifestEngineTests.sample("sheets-log")
        let reviewed = Connectors.reviewedBy(manifest: sheets, canonical: try await engine.pluginCanonicalJSON(sheets),
                                             keys: try await engine.pluginSigningKeys())
        #expect(reviewed == "khayt-2026-11")
        let order: JSONValue = .object(["invoiceNumber": .string("INV-1"), "price": .number(5), "currency": .string("SAR")])
        let payload = try await engine.pluginPayload(sheets, trigger: .object(["event": .string("payment_received")]),
                                                     context: .object(["order": order,
                                                                       "secrets": .object(["deploymentId": .string("AKfy-1")])]))
        let p = try Connectors.post(from: payload, manifest: sheets, event: "payment_received",
                                    secrets: ["signingKey": "k"], delivery: "d1", now: Date(timeIntervalSince1970: 0))
        #expect(p.url.absoluteString == "https://script.google.com/macros/s/AKfy-1/exec")
        #expect(p.headers.contains { $0.name == "X-Khayt-Signature" })
    }

    @Test("a delivery id is random, prefixed, and says nothing about the job")
    func deliveryId() {
        let a = Connectors.newDeliveryId(), b = Connectors.newDeliveryId()
        #expect(a != b)
        #expect(a.hasPrefix("dlv_") && a.count == 40 && a == a.lowercased())
    }
}
