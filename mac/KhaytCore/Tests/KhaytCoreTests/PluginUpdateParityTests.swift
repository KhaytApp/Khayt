import Foundation
import CryptoKit
import Testing
@testable import KhaytCore

/// Connector updates on the Mac run lib/plugin-update.js
/// (test/plugin-update.test.js has every case). This proves the Mac reaches
/// it, that CryptoKit verifies an index over the lib's context-prefixed
/// bytes, and that an index that cannot be trusted changes nothing.
struct PluginUpdateParityTests {

    func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }

    static let now = Date(timeIntervalSince1970: 1_794_474_000)   // 2026-11-12 09:00 UTC
    static func lamha() throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "plugins/samples/lamha-shipping.json")
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }
    static func at(_ v: String) throws -> JSONValue {
        guard case .object(var m) = try lamha() else { throw CancellationError() }
        m["version"] = .string(v)
        return .object(m)
    }
    static func index(expiresInDays: Double, revoke: Bool = false) -> JSONValue {
        var row: [String: JSONValue] = [
            "kind": .string("connector"), "id": .string("app.khayt.samples.lamha"), "version": .string("1.1.1"),
            "url": .string("https://khaytapp.com/connectors/app.khayt.samples.lamha/1.1.1.json"),
            "sha256": .string(String(repeating: "a", count: 64)), "requires": .object(["schema": .number(1)]),
        ]
        if revoke { row["revoked"] = .array([.object(["version": .string("1.0.0"), "reason": .string("bad")])]) }
        return .object([
            "khaytIndex": .number(1), "serial": .number(7),
            "issuedAt": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400))),
            "expires": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(expiresInDays * 86_400))),
            "entries": .array([.object(row)]),
        ])
    }

    @Test("CryptoKit verifies an index signed over the lib's bytes, and only with the key it names")
    func signature() async throws {
        let engine = try KhaytEngine()
        let key = Curve25519.Signing.PrivateKey()
        let keys: [JSONValue] = [.object(["id": .string("test-key"),
                                          "key": .string(key.publicKey.rawRepresentation.base64EncodedString())])]
        let unsigned = Self.index(expiresInDays: 44)
        let message = try await engine.pluginIndexMessage(unsigned)
        #expect(message.hasPrefix("khayt-index-v1\n"))
        let sig = try key.signature(for: Data(message.utf8)).base64EncodedString()
        guard case .object(var ix) = unsigned else { return }
        ix["signature"] = .object(["keyId": .string("test-key"), "sig": .string(sig)])
        let signed = JSONValue.object(ix)
        #expect(try await engine.pluginIndexMessage(signed) == message, "the signature is not part of what it signs")
        #expect(Connectors.indexSignedBy(index: signed, message: message, keys: keys) == "test-key")
        // A manifest-style signature (no context) does not pass.
        let bare = try await engine.pluginCanonicalJSON(signed)
        ix["signature"] = .object(["keyId": .string("test-key"),
                                   "sig": .string(try key.signature(for: Data(bare.utf8)).base64EncodedString())])
        #expect(Connectors.indexSignedBy(index: .object(ix), message: message, keys: keys) == nil)
        // Naming another key id fails even with a good signature.
        ix["signature"] = .object(["keyId": .string("khayt-2026-11"), "sig": .string(sig)])
        #expect(Connectors.indexSignedBy(index: .object(ix), message: message, keys: keys) == nil)
    }

    @Test("an expired or unsigned index changes nothing; a good one updates with the same grant")
    func failSafeAndUpdate() async throws {
        let engine = try KhaytEngine()
        let old = try Self.at("1.0.0")
        let entry = try await engine.pluginConsentedEntry(prev: .null, manifest: old)
        let settings: JSONValue = .object(["plugins": .array([entry])])
        let ctx: JSONValue = .object(["signedBy": .string("khayt-2026-11"), "nowMs": .number(Self.now.timeIntervalSince1970 * 1000),
                                      "platform": .string("mac"), "appVersion": .string("4.0.0-beta.34"), "schema": .number(1)])
        let fetched: JSONValue = .object(["app.khayt.samples.lamha": try Self.at("1.1.1")])
        for bad in [(Self.index(expiresInDays: -1, revoke: true), ctx), (Self.index(expiresInDays: 44, revoke: true),
                     JSONValue.object(obj(ctx).merging(["signedBy": .null]) { $1 }))] {
            let r = try await engine.pluginApplyIndex(settings: settings, index: bad.0, ctx: bad.1, fetched: fetched)
            #expect(obj(r)["ok"] == .bool(false))
            #expect(obj(r)["settings"] == settings, "not a byte moved")
            #expect(try await engine.pluginUpdateFetches(settings: settings, index: bad.0, ctx: bad.1) == .array([]))
        }
        let good = try await engine.pluginApplyIndex(settings: settings, index: Self.index(expiresInDays: 44), ctx: ctx, fetched: fetched)
        let after = obj(obj(good)["settings"])
        guard case .array(let plugins)? = after["plugins"], let e = plugins.first else { Issue.record("no plugins"); return }
        #expect(obj(e)["version"] == .string("1.1.1"))
        #expect(obj(e)["granted"] == obj(entry)["granted"])
        let check = try await engine.pluginCheckEntry(e)
        #expect(obj(check)["ok"] == .bool(true))
        let run = try await engine.pluginRunnable(entry: e, settings: .object(after))
        #expect(obj(run)["which"] == .string("current"))
        let back = try await engine.pluginRevertUpdate(settings: .object(after), id: "app.khayt.samples.lamha")
        #expect(obj(back)["ok"] == .bool(true))
    }
}
